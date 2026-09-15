-- Token accounting. PostgreSQL 14+. Companion to 016-dora/schema.sql, which
-- it references: DORA says what the pipeline did, this says what driving it
-- cost, and the join between them is the only place "cost per unit" exists.
--
-- This is the FINAL shape, not a first rollout. It is graded on whether it can
-- refuse to hold the two numbers this repo has already got wrong once each:
--
--   1. A CALL COUNTED TWICE. docs/time-spent.org shipped 2,245,451,282 tokens
--      for the release night. The true figure is 1,182,809,707. The gap is not
--      an estimate that drifted -- it is the same API call summed once per
--      streaming snapshot of it, 1.98 rows per call. Here the primary key is
--      (ledger_id, api_message_id), so the second snapshot is an ON CONFLICT
--      and lands as an UPDATE to the running total, never a second row. The
--      defect is unrepresentable rather than merely discouraged.
--
--   2. A CALL WITH NO OWNER. Six subagents ran on 2026-09-13 and not one of
--      their calls is in the coordinator's transcript. `ledger_id` is NOT NULL
--      and `agent_id` is nullable-but-checked, so delegated spend is either
--      attributed or visibly absent. A total that silently omits the agents is
--      the shape of defect class 1: unreachable is not falsified.
--
-- Prices are NOT stored on the usage row. A rate is an input that changes
-- retroactively for nobody; a token count is an observation. Keeping them in
-- one table is how a re-priced invoice quietly rewrites history.

-- ---------------------------------------------------------------------------
-- LEDGER -- one transcript. A session, a subagent run, a CI job.
-- ---------------------------------------------------------------------------
CREATE TYPE ledger_kind AS ENUM ('interactive', 'subagent', 'automation');

CREATE TABLE ledger (
  ledger_id     text PRIMARY KEY,            -- transcript uuid
  kind          ledger_kind NOT NULL,
  parent_id     text REFERENCES ledger(ledger_id),
  actor_kind    actor_kind NOT NULL,         -- from 016-dora
  started_at    timestamptz NOT NULL,
  ended_at      timestamptz,
  -- A subagent ledger without a parent is an orphan: its spend belongs to
  -- SOMETHING and we do not know what. Refuse it at write time.
  CONSTRAINT subagent_has_parent
    CHECK (kind <> 'subagent' OR parent_id IS NOT NULL)
);

-- ---------------------------------------------------------------------------
-- TOKEN_USAGE -- one API CALL. Not one transcript row.
-- ---------------------------------------------------------------------------
CREATE TABLE token_usage (
  ledger_id        text NOT NULL REFERENCES ledger(ledger_id),
  api_message_id   text NOT NULL,            -- msg_xxx: the unit of truth
  model            text NOT NULL,
  observed_at      timestamptz NOT NULL,     -- LAST snapshot, not the first
  input_tokens        bigint NOT NULL CHECK (input_tokens        >= 0),
  cache_write_tokens  bigint NOT NULL CHECK (cache_write_tokens  >= 0),
  cache_read_tokens   bigint NOT NULL CHECK (cache_read_tokens   >= 0),
  output_tokens       bigint NOT NULL CHECK (output_tokens       >= 0),
  thinking_tokens     bigint NOT NULL CHECK (thinking_tokens     >= 0),
  -- Thinking is carved out of output, not added to it. Stored separately and
  -- constrained, because "output + thinking" as a total is the same
  -- double-count one level down.
  CONSTRAINT thinking_within_output CHECK (thinking_tokens <= output_tokens),
  -- THE COUNTING RULE, as a key.
  PRIMARY KEY (ledger_id, api_message_id)
);

-- Ingest is idempotent by construction. Replaying a whole transcript twice
-- changes nothing; a partial snapshot is superseded by a later, larger one.
-- GREATEST, not the new value: snapshots may arrive out of order.
--
--   INSERT INTO token_usage (...) VALUES (...)
--   ON CONFLICT (ledger_id, api_message_id) DO UPDATE SET
--     output_tokens = GREATEST(token_usage.output_tokens, EXCLUDED.output_tokens),
--     ... ,
--     observed_at   = GREATEST(token_usage.observed_at,   EXCLUDED.observed_at);

-- ---------------------------------------------------------------------------
-- ATTRIBUTION -- which change a ledger was driving.
--
-- Deliberately many-to-many and deliberately NOT total. A session drives
-- several changes and spends time on none of them; forcing every call onto a
-- change would invent precision. `share` is a declared split that must sum to
-- <= 1, never = 1: the remainder is overhead with no unit, and naming it is
-- the point. A pipeline whose overhead is defined as zero cannot report that
-- most of the night went into its own instruments.
-- ---------------------------------------------------------------------------
CREATE TABLE ledger_change (
  ledger_id   text NOT NULL REFERENCES ledger(ledger_id),
  change_id   bigint NOT NULL REFERENCES change(change_id),   -- from 016-dora
  share       numeric(5,4) NOT NULL CHECK (share > 0 AND share <= 1),
  basis       text NOT NULL,          -- how the share was decided, in words
  PRIMARY KEY (ledger_id, change_id)
);

CREATE OR REPLACE FUNCTION ledger_share_total() RETURNS trigger AS $$
BEGIN
  IF (SELECT sum(share) FROM ledger_change WHERE ledger_id = NEW.ledger_id) > 1 THEN
    RAISE EXCEPTION 'ledger % attributed beyond 100%%', NEW.ledger_id;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER ledger_share_total_trg
  AFTER INSERT OR UPDATE ON ledger_change
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION ledger_share_total();

-- ---------------------------------------------------------------------------
-- RATE_CARD -- prices, versioned, apart from the observations.
-- ---------------------------------------------------------------------------
CREATE TABLE rate_card (
  model          text NOT NULL,
  effective_from timestamptz NOT NULL,
  usd_per_mtok_input       numeric(10,4) NOT NULL,
  usd_per_mtok_cache_write numeric(10,4) NOT NULL,
  usd_per_mtok_cache_read  numeric(10,4) NOT NULL,
  usd_per_mtok_output      numeric(10,4) NOT NULL,
  source         text NOT NULL,     -- invoice, published page, or 'assumed'
  PRIMARY KEY (model, effective_from)
);

-- ---------------------------------------------------------------------------
-- Views. Each one names what it cannot see.
-- ---------------------------------------------------------------------------

-- T1: cost per unit. LEFT JOIN on purpose -- a change with no attributed
-- ledger shows NULL, which reads as "not measured". Reporting it as 0 would
-- make the cheapest change in the estate the one nobody accounted for.
CREATE VIEW change_token_cost AS
SELECT c.change_id,
       sum(tu.input_tokens       * lc.share) AS input_tokens,
       sum(tu.cache_write_tokens * lc.share) AS cache_write_tokens,
       sum(tu.cache_read_tokens  * lc.share) AS cache_read_tokens,
       sum(tu.output_tokens      * lc.share) AS output_tokens,
       count(tu.*)                           AS api_calls
FROM change c
LEFT JOIN ledger_change lc ON lc.change_id = c.change_id
LEFT JOIN token_usage   tu ON tu.ledger_id = lc.ledger_id
GROUP BY c.change_id;

-- T5: the spend that belongs to no change. This is the number the guardrail
-- exists to surface, and the one a per-change view can never show.
CREATE VIEW unattributed_spend AS
SELECT l.ledger_id, l.kind,
       coalesce((SELECT sum(share) FROM ledger_change WHERE ledger_id = l.ledger_id), 0)
         AS attributed_share,
       sum(tu.input_tokens + tu.cache_write_tokens
           + tu.cache_read_tokens + tu.output_tokens) AS total_tokens
FROM ledger l JOIN token_usage tu USING (ledger_id)
GROUP BY l.ledger_id, l.kind;

-- Rework: what a failed deployment cost. Joins 016-dora's DEPLOYMENT, which
-- exists precisely so a failed attempt is a row. Without that table this view
-- is unwritable, which is the argument for it.
CREATE VIEW failed_deploy_cost AS
SELECT d.deployment_id, d.change_id, d.outcome, ctc.output_tokens, ctc.api_calls
FROM deployment d JOIN change_token_cost ctc USING (change_id)
WHERE d.outcome IN ('failed', 'withdrawn');
