-- DORA-capable change record. PostgreSQL 14+ (needs btree_gist for EXCLUDE).
--
-- This is the FINAL shape, not a first rollout. It is graded on whether it can
-- NAME each state in spec.org §Boundary conditions, using the terms in
-- spec.org §Nomenclature and no synonyms for them.
--
-- It starts from docs/interfaces.org §7 and changes three things:
--   1. adds DEPLOYMENT and CUTOVER. §7 has ENVIRONMENT and RUN but no entity
--      for an ATTEMPT, so a deployment that failed cannot be written down at
--      all -- which is exactly what happened to #42 at 19:43Z on 2026-09-13.
--   2. adds AUTHORIZATION as a row, so "a guard refused and the driver went
--      anyway" (scenario D16) is a fact the store can hold rather than a
--      thing only prose knows.
--   3. splits WINDOW.result from CHANGE.closure_code. §Nomenclature lists one
--      closure-code enum covering both; `expired` is a property of a
--      reservation and can never be a property of a change.
--
-- The rule throughout, from the defect taxonomy: nearly every defect in this
-- repo was two facts sharing one field. Where this schema looks redundant, the
-- redundancy is the point.

CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ---------------------------------------------------------------------------
-- Enums. Every one is closed, and every one is three-valued where a boolean
-- would force the collapse the taxonomy keeps finding (class 1: unreachable
-- is not falsified).
-- ---------------------------------------------------------------------------

CREATE TYPE classification  AS ENUM ('standard', 'normal', 'emergency');
CREATE TYPE lifecycle       AS ENUM ('requested', 'approved', 'scheduled',
                                     'in_flight', 'complete', 'failed',
                                     'backed_out', 'abandoned');
-- Closure of a CHANGE. Note what is absent: 'expired' and 'cancelled'. Neither
-- can be true of a change -- they are true of a reservation.
CREATE TYPE change_closure   AS ENUM ('complete', 'backed_out', 'abandoned',
                                      'superseded');
-- Closure of a WINDOW. spec.org §Boundary conditions: expired is NOT failed.
-- 'forfeited' is split from 'cancelled' because a guard refusing at activation
-- and a person changing their mind are different events with different owners.
CREATE TYPE window_result    AS ENUM ('passed', 'failed', 'cancelled',
                                      'forfeited', 'expired');
-- Outcome of a DEPLOYMENT ATTEMPT. 'succeeded' means the build was observed
-- serving on the target. 'failed' means the attempt ran and did not place the
-- build. 'withdrawn' means a success was asserted and then retracted, which is
-- the shape #42 took and is not the same as never having tried.
CREATE TYPE deploy_outcome   AS ENUM ('succeeded', 'failed', 'withdrawn',
                                      'indeterminate');
CREATE TYPE verdict          AS ENUM ('pass', 'fail', 'indeterminate');
CREATE TYPE health            AS ENUM ('healthy', 'unhealthy', 'unreachable');
-- Whether the thing that took the action was a person. §7 records `instrument`
-- and `observed_by`; this keeps that and makes the human/not axis explicit,
-- because "was a human the instrument" is asked of authorizations too.
CREATE TYPE actor_kind       AS ENUM ('person', 'agent', 'automation');
CREATE TYPE tier             AS ENUM ('dev', 'team', 'protected');

-- ---------------------------------------------------------------------------
-- CHANGE -- the record. (§7 CHANGE, extended.)
-- ---------------------------------------------------------------------------

CREATE TABLE change (
  change_id        text PRIMARY KEY,
  forge_ref        text NOT NULL,              -- e.g. 'aygp-dr/standard-change#54'

  -- Classification and lifecycle are separate columns about different
  -- subjects. §7 is right and this keeps it. EXACTLY ONE classification:
  -- NOT NULL plus a single column is what makes "undefined class" unwritable.
  classification   classification NOT NULL,
  classified_by    text NOT NULL,
  classified_by_kind actor_kind NOT NULL,
  classified_at    timestamptz NOT NULL,

  lifecycle        lifecycle NOT NULL,

  opened_at        timestamptz NOT NULL,
  closed_at        timestamptz,
  closure_code     change_closure,
  narrative        text,                       -- written BEFORE labels are cleared

  -- Trunk facts. §7 deliberately has no deployed_by here and that is right --
  -- a BUILD is deployed, not a change. But MERGING is an act on the change,
  -- and without it "deployed, not merged" is inexpressible. #40 needs these.
  landed_at        timestamptz,
  landed_sha       text,

  -- An emergency's unpaid record. itil:emergency skips the paperwork by
  -- design; the debt has to be a column or it is never collected.
  backfill_owed    boolean NOT NULL DEFAULT false,
  backfilled_at    timestamptz,
  backfilled_by    text,

  CONSTRAINT closed_together
    CHECK ((closed_at IS NULL) = (closure_code IS NULL)),
  CONSTRAINT landed_together
    CHECK ((landed_at IS NULL) = (landed_sha IS NULL)),
  -- Only an emergency can owe a backfill, and a paid debt names its payer.
  CONSTRAINT backfill_only_for_emergency
    CHECK (NOT backfill_owed OR classification = 'emergency'),
  CONSTRAINT backfill_paid_names_payer
    CHECK ((backfilled_at IS NULL) = (backfilled_by IS NULL)),
  CONSTRAINT backfill_paid_was_owed
    CHECK (backfilled_at IS NULL OR backfill_owed)
);

-- Blast radius, as rows rather than a count. A count cannot answer "which
-- apps", and a change that touches four apps and one that touches a different
-- four are not interchangeable. COUNT(*) over this is the DORA blast radius;
-- ZERO ROWS is a legitimate and meaningful state (a control-plane change
-- deploys nothing) and is distinct from "nobody labelled it", which is why
-- radius_declared_at exists on CHANGE_RADIUS_DECLARATION below.
CREATE TABLE change_app (
  change_id  text NOT NULL REFERENCES change(change_id),
  app        text NOT NULL,                    -- 'core' | 'plp' | 'pdp' | ...
  PRIMARY KEY (change_id, app)
);

-- "Nobody has declared a radius yet" and "the radius is empty" are different
-- facts and the taxonomy's class 1 says they must refuse differently. One row
-- per change once the labeller has run; its absence means UNDETERMINED.
CREATE TABLE change_radius_declaration (
  change_id    text PRIMARY KEY REFERENCES change(change_id),
  declared_at  timestamptz NOT NULL,
  declared_by  text NOT NULL,
  declared_by_kind actor_kind NOT NULL
);

-- ---------------------------------------------------------------------------
-- ENVIRONMENT -- declared; RUN -- observed. (§7, kept.)
-- Two entities on purpose: the first is a DECISION and is reviewed, the second
-- is a MEASUREMENT and is probed. Merging them lets a typo look like an outage.
-- Declared first because the reservation and the deployment both point at it.
-- ---------------------------------------------------------------------------

CREATE TABLE environment (
  name         text PRIMARY KEY,
  tier         tier NOT NULL,
  address      text NOT NULL,
  activated    boolean NOT NULL,
  promotes     boolean NOT NULL,
  -- The front serves whichever replica it points at; it is never deployed to.
  -- Without this the estate cannot say that a cutover is a different act from
  -- a deployment, and both rollbacks on 2026-09-13/14 were cutovers only.
  is_front     boolean NOT NULL DEFAULT false,
  CONSTRAINT team_cannot_promote CHECK (tier <> 'team' OR NOT promotes)
);

-- A cache with a timestamp, never an authority. Three-valued health.
CREATE TABLE run (
  environment  text NOT NULL REFERENCES environment(name),
  sha          text,                           -- NULL when unreachable
  started_at   timestamptz,
  observed_at  timestamptz NOT NULL,
  state        health NOT NULL,
  PRIMARY KEY (environment, observed_at),
  CONSTRAINT unreachable_has_no_build
    CHECK ((state = 'unreachable') = (sha IS NULL))
);

-- ---------------------------------------------------------------------------
-- WINDOW -- the reservation. (§7 WINDOW, kept almost whole.)
-- ---------------------------------------------------------------------------

CREATE TABLE change_window (
  window_id    text PRIMARY KEY,
  change_id    text NOT NULL REFERENCES change(change_id),
  environment  text NOT NULL REFERENCES environment(name),
  during       tstzrange NOT NULL,
  groups       text[] NOT NULL,
  sha          text NOT NULL,                  -- the build the booking was FOR
  booked_at    timestamptz NOT NULL,
  booked_by    text NOT NULL,
  booked_by_kind actor_kind NOT NULL,          -- §7: scheduling is owned by a person
  result       window_result,
  result_at    timestamptz,
  result_note  text,                           -- the forfeit/cancel reason, in words

  CONSTRAINT resolved_together
    CHECK ((result IS NULL) = (result_at IS NULL)),
  -- The only true uniqueness constraint in the model, and the one the whole
  -- thing rests on. Enforced in the STORE because the caller is two agents
  -- racing. §7 says this and it is correct.
  CONSTRAINT one_unresolved_reservation_per_environment
    EXCLUDE USING gist (environment WITH =, during WITH &&)
    WHERE (result IS NULL)
);

-- A change may hold AT MOST ONE unresolved window. §7 names this as a separate
-- mistake from overlap and says it happened twice in one day; here it is a
-- constraint rather than a note.
CREATE UNIQUE INDEX one_unresolved_window_per_change
  ON change_window (change_id) WHERE result IS NULL;

-- ---------------------------------------------------------------------------
-- DEPLOYMENT -- an ATTEMPT to place a build on an environment.
-- NOT in §7, and its absence is the single biggest gap there: with only
-- ENVIRONMENT and RUN you can record what is serving, but you cannot record
-- that something was tried and did not take.
-- ---------------------------------------------------------------------------

CREATE TABLE deployment (
  deployment_id  bigserial PRIMARY KEY,
  change_id      text REFERENCES change(change_id),  -- NULL: an estate action
                                                     -- with no change behind it
  environment    text NOT NULL REFERENCES environment(name),
  sha            text NOT NULL,
  window_id      text REFERENCES change_window(window_id),

  started_at     timestamptz NOT NULL,
  finished_at    timestamptz,
  outcome        deploy_outcome,

  -- Who ran it, and what it was. An automation that a person triggered is
  -- still an automation; `triggered_by` is the person, `actor` is the runner.
  actor          text NOT NULL,
  actor_kind     actor_kind NOT NULL,
  triggered_by   text,

  -- Set when a success was asserted and later retracted (#42, 19:44:34Z).
  -- Retraction is a NEW fact with its own time and reason, never an UPDATE
  -- that erases the claim: an audit needs to see that it was made.
  withdrawn_at   timestamptz,
  withdrawn_reason text,

  CONSTRAINT finished_together
    CHECK ((finished_at IS NULL) = (outcome IS NULL)),
  CONSTRAINT withdrawn_is_an_outcome
    CHECK ((withdrawn_at IS NULL) = (outcome IS DISTINCT FROM 'withdrawn')),
  CONSTRAINT withdrawn_says_why
    CHECK (withdrawn_at IS NULL OR withdrawn_reason IS NOT NULL)
);

-- A front receives CUTOVERs, never DEPLOYMENTs. Collapsing the two is what
-- makes a rollback indistinguishable from a redeploy. This cannot be a CHECK
-- (it reads another table), so it is a trigger -- but it is a constraint in
-- intent and belongs next to the others.
CREATE FUNCTION reject_deploy_to_front() RETURNS trigger AS $$
BEGIN
  IF (SELECT is_front FROM environment WHERE name = NEW.environment) THEN
    RAISE EXCEPTION 'the front is cut over to, never deployed to: %',
      NEW.environment;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER deployment_never_targets_front
  BEFORE INSERT OR UPDATE ON deployment
  FOR EACH ROW EXECUTE FUNCTION reject_deploy_to_front();

-- ---------------------------------------------------------------------------
-- CUTOVER -- pointing the front at a replica. The act that makes a build
-- production-serving, and the act that rolls one back.
-- ---------------------------------------------------------------------------

CREATE TABLE cutover (
  cutover_id     bigserial PRIMARY KEY,
  front          text NOT NULL REFERENCES environment(name),
  to_environment text NOT NULL REFERENCES environment(name),  -- blue | green
  to_sha         text NOT NULL,
  from_environment text REFERENCES environment(name),         -- NULL on first
  from_sha       text,
  at             timestamptz NOT NULL,

  change_id      text REFERENCES change(change_id),
  actor          text NOT NULL,
  actor_kind     actor_kind NOT NULL,

  -- A rollback is a cutover that names what it returned TO and what it undid.
  -- §Boundary conditions: 'backed out ... must name what it returned to'.
  rolls_back     bigint REFERENCES cutover(cutover_id),
  rollback_reason text,

  -- The idle colour still holds the bad build after a front-switch rollback.
  -- Recording this is the difference between "production is safe" and
  -- "production is safe and one command from unsafe".
  bad_build_still_resident boolean,

  CONSTRAINT rollback_says_why
    CHECK ((rolls_back IS NULL) = (rollback_reason IS NULL)),
  CONSTRAINT rollback_names_residency
    CHECK (rolls_back IS NULL OR bad_build_still_resident IS NOT NULL)
);

-- ---------------------------------------------------------------------------
-- OBSERVATION -- the evidence. (§7 OBSERVATION, kept, plus retraction.)
-- ---------------------------------------------------------------------------

CREATE TABLE observation (
  observation_id  bigserial PRIMARY KEY,
  change_id       text REFERENCES change(change_id),
  instrument      text NOT NULL,               -- 'e2e' | 'smoke' | 'uat' | ...
  instrument_kind actor_kind NOT NULL,         -- for UAT the instrument IS a person
  verdict         verdict NOT NULL,            -- three-valued, never boolean
  sha             text NOT NULL,               -- a verdict names its build
  environment     text REFERENCES environment(name),
  target          text,
  observed_at     timestamptz NOT NULL,
  observed_by     text NOT NULL,               -- the actor, distinct from instrument

  -- Append-only. A withdrawal is a NEW ROW pointing at the one it retracts.
  retracts        bigint REFERENCES observation(observation_id),

  CONSTRAINT a_retraction_matches_its_subject
    CHECK (retracts IS NULL OR verdict <> 'pass')
);

-- What a guard queries. NOT (change_id, instrument) -- that is the
-- stale-evidence bug (taxonomy class 4).
CREATE INDEX observation_guard_lookup
  ON observation (change_id, instrument, sha, observed_at DESC);

-- ---------------------------------------------------------------------------
-- CHANGE_AUTHORIZATION -- who or what said yes, and whether anyone listened.
-- NOT in §7. Without it, scenario D16 -- guard 4 printed NOT authorized and
-- the driver deployed anyway -- is not a fact the store can hold, and the
-- deployment looks identical to an authorized one.
-- ---------------------------------------------------------------------------

CREATE TABLE change_authorization (
  authorization_id bigserial PRIMARY KEY,
  deployment_id  bigint REFERENCES deployment(deployment_id),
  cutover_id     bigint REFERENCES cutover(cutover_id),

  guard          text NOT NULL,                -- 'guard4', 'preflight', ...
  guard_verdict  verdict NOT NULL,             -- what the guard actually said
  evaluated_at   timestamptz NOT NULL,
  sha            text NOT NULL,                -- re-derived at reliance, not booking

  -- The authorizing actor, and whether a human was the instrument. A standing
  -- delegation exercised by a proxy is NOT a person: `actor_kind='agent'`
  -- with `on_behalf_of` set is how the review proxy is told apart from JW.
  actor          text NOT NULL,
  actor_kind     actor_kind NOT NULL,
  on_behalf_of   text,

  -- The D16 column. FALSE means the step proceeded past a refusal.
  honored        boolean NOT NULL,

  CONSTRAINT authorizes_exactly_one_act
    CHECK ((deployment_id IS NULL) <> (cutover_id IS NULL)),
  CONSTRAINT a_pass_is_always_honored
    CHECK (guard_verdict <> 'pass' OR honored)
);

-- ---------------------------------------------------------------------------
-- ESTATE -- the world. (§7 ESTATE, kept whole.) Deliberately NOT attached to
-- a change: a flag on a change is a flag whose carrier is exempt from it.
-- ---------------------------------------------------------------------------

CREATE TABLE estate_flag (
  flag          text NOT NULL,                 -- 'freeze' | 'emergency'
  declared_by   text NOT NULL,
  declared_by_kind actor_kind NOT NULL,
  declared_at   timestamptz NOT NULL,
  cleared_by    text,
  cleared_by_kind actor_kind,
  cleared_at    timestamptz,
  reason        text NOT NULL,
  PRIMARY KEY (flag, declared_at),
  CONSTRAINT cleared_together
    CHECK ((cleared_at IS NULL) = (cleared_by IS NULL))
);

-- ---------------------------------------------------------------------------
-- The boundary conditions, as queries. A schema is graded on whether it can
-- NAME each state in spec.org §Boundary conditions; these are the proof.
-- ---------------------------------------------------------------------------

-- deployed, not merged  (#40 on 2026-09-14T00:41Z)
CREATE VIEW bc_deployed_not_merged AS
SELECT c.change_id, co.to_sha, co.at
FROM cutover co
JOIN change c USING (change_id)
WHERE c.landed_at IS NULL
  AND NOT EXISTS (SELECT 1 FROM cutover r WHERE r.rolls_back = co.cutover_id);

-- deployed, not merged, AND the window is gone -- spec.org §"The one that has
-- no name yet". Named here: STRANDED.
CREATE VIEW bc_stranded AS
SELECT b.*, w.window_id, w.result
FROM bc_deployed_not_merged b
JOIN change_window w USING (change_id)
WHERE w.result IN ('expired', 'forfeited', 'cancelled');

-- merged, not deployed -- ordinary, and fine.
CREATE VIEW bc_merged_not_deployed AS
SELECT c.change_id, c.landed_sha
FROM change c
WHERE c.landed_at IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM cutover co WHERE co.to_sha = c.landed_sha);

-- expired: a lapsed reservation. NOT a failure, and it keeps its own code.
CREATE VIEW bc_expired_windows AS
SELECT * FROM change_window WHERE result = 'expired';

-- refused: a guard said no. A SUCCESSFUL outcome.
CREATE VIEW bc_refused AS
SELECT * FROM change_authorization WHERE guard_verdict = 'fail' AND honored;

-- the one the estate could not previously write down: a refusal walked past.
CREATE VIEW bc_refusal_ignored AS
SELECT * FROM change_authorization WHERE guard_verdict <> 'pass' AND NOT honored;

-- backed out, naming what it returned to.
CREATE VIEW bc_backed_out AS
SELECT undo.at AS restored_at, bad.to_sha AS withdrawn_build,
       undo.to_sha AS restored_build,
       undo.at - bad.at AS time_to_restore,
       undo.bad_build_still_resident
FROM cutover undo JOIN cutover bad ON undo.rolls_back = bad.cutover_id;

-- stale evidence: observations about a build that is no longer the head.
CREATE VIEW bc_stale_evidence AS
SELECT o.* FROM observation o JOIN change c USING (change_id)
WHERE c.landed_sha IS NOT NULL AND o.sha <> c.landed_sha;

-- ---------------------------------------------------------------------------
-- The four metrics, as queries. Each one is a JOIN, not a judgement call
-- made at report time -- which is the whole point of the shape above.
-- ---------------------------------------------------------------------------

CREATE VIEW dora_deployment_frequency AS
SELECT date_trunc('day', at) AS day, count(*) AS production_cutovers
FROM cutover WHERE rolls_back IS NULL GROUP BY 1;

CREATE VIEW dora_lead_time AS
SELECT c.change_id, co.at - c.opened_at AS lead_time
FROM cutover co JOIN change c USING (change_id) WHERE co.rolls_back IS NULL;
-- NB: c.opened_at must be the FIRST AUTHOR date of the change's work, not the
-- forge's created_at and not a committer date. See notes.org §Lead time.

CREATE VIEW dora_change_failure_rate AS
WITH attempts AS (
  SELECT d.deployment_id,
         (d.outcome IN ('failed', 'withdrawn')
          OR EXISTS (SELECT 1 FROM cutover r
                     JOIN cutover b ON r.rolls_back = b.cutover_id
                     WHERE b.to_sha = d.sha)) AS failed
  FROM deployment d
  JOIN environment e ON e.name = d.environment
  WHERE e.tier = 'protected' AND e.promotes
)
SELECT count(*) FILTER (WHERE failed) AS failures,
       count(*)                        AS attempts,
       round(100.0 * count(*) FILTER (WHERE failed) / count(*), 1) AS pct
FROM attempts;

CREATE VIEW dora_time_to_restore AS
SELECT * FROM bc_backed_out;
