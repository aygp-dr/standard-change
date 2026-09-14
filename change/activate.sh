#!/bin/sh
# activate.sh <pr> -- ACTIVATION: drive one change through the pipeline locally.
#
# Was `deploy-run` at the repo root, which was the wrong name and the wrong
# shape. It reads as the thing a person runs to ship, and a person running it
# was hand-driving a pipeline the labels are supposed to drive -- a SECOND
# implementation of the control flow, free to drift from
# .github/workflows/*.yml. That is the same defect class as sim/ diverging from
# queue.sh and switch.sh reporting the config instead of the router.
#
# It lives under change/ now, next to the other verbs, and is called BY the
# activation step -- not typed by a human. The human-facing command is
# ./deploy-run, which adds a label and gets out of the way.
#
# KNOWN DIVERGENCE, not fixed here: .github/workflows/deploy-staging.yml still
# lists its own steps rather than calling this script, so the two can disagree.
# Trigger to revisit: the first time a guard exists in one and not the other.
#
# Reservation, activation, staging, promotion, production, cutover, settlement:
# the flow in spec.org, executed against the bastille jails with the actual
# gates. No simulation of the gates -- sim/ models the SCHEDULING, this runs the
# estate.
set -eu
PR="${1:?usage: deploy-run <pr>}"
R=aygp-dr/standard-change
FRONT_PROD=http://127.0.0.1:9200
# THE FRONT IS WHAT environments.tsv SAYS IT IS, not a constant here.
#
# This was hardcoded to :9201 and :9201 is not the staging front -- it is one
# app replica. Every route except core's 404s behind it, so the authorizing
# e2e run refused a healthy estate with eight "upstream unreachable" lines
# and #62's window was spent proving that the address was wrong. The
# declaration says staging is base_port 9200, and e2e passes 27 checks there.
#
# A second copy of a fact that is already declared somewhere is not a
# convenience; it is a fact that can disagree with itself, and this one did.
# Read the declaration. Fail loudly if it is not there, because a front we
# cannot name is not one we should deploy to.
_stg_port=$(awk -F'\t' '$1=="staging"{print $4}' environments.tsv)
[ -n "${_stg_port:-}" ] || { echo "no 'staging' row in environments.tsv" >&2; exit 2; }
FRONT_STG="http://127.0.0.1:${_stg_port}"
# Every relative path below (./change/, ./gates/, ./targets/) is written from
# the REPO ROOT, and this used to cd into change/ instead -- so guard 3's call
# to ./change/schedule.sh failed with "not found" and the failure was reported
# as "no open staging window covers now" for a window that was open. A script
# that could not run its check said the check had failed: unreachable reported
# as falsified, docs/label-ownership.org rule 2, one level up.
cd "$(dirname "$0")/.."

# AND THIS SCRIPT IS STALE. It drives targets/bastille/ and calls 9200 the
# production front with staging on 9201 -- the port scheme from before the
# 2026-09-13 correction, under which 9200 IS staging and production is blue
# 9210 / green 9220 behind the front on 9230. Every cycle actually run today
# went through targets/node/. Fixing the cd above without saying this would
# turn a script that refused into one that deploys staging over production.
#
# So it refuses unless its own target tree is really there. Delete this block
# when activate.sh is ported to the node path and the ports are corrected.
if [ ! -x ./targets/bastille/deploy.sh ]; then
  echo "refused: change/activate.sh drives targets/bastille/, which is not present here." >&2
  echo "         It also still assumes 9200=production-front and 9201=staging," >&2
  echo "         which the 2026-09-13 port correction reversed: 9200 is STAGING." >&2
  echo "         Running it on this host would deploy staging onto a production port." >&2
  echo "         Use the node path: change/queue.sh, targets/node/deploy.sh," >&2
  echo "         change/guard4.sh, targets/node/switch.sh, change/settle.sh." >&2
  exit 6
fi

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# INDENTING A GATE MUST NOT SWALLOW ITS VERDICT.
#
# Every gate here was written as `./gates/x.sh | sed 's/^/   /'`, and a
# pipeline's exit status is its LAST command's -- sed's, which always succeeds.
# So `set -e` saw nothing, and even the `|| die` written at guard 5 could never
# fire, because the `||` bound to the pipeline and not to the gate.
#
# On 2026-09-13 this let activate.sh print
#     UNHEALTHY mock: 5/5 samples not serving 2567015 (saw: 055fd20)
# and then `converged; deployment -> success`, deploy nothing, write three
# deployment records, label the PR production:healthy and close the window
# `passed` -- for a build that was serving on no port in the estate.
#
# indent() runs the gate, keeps its output, prints it indented, and returns THE
# GATE'S code. The formatting happens after the verdict is in hand.
indent() { # indent <command...>
  _out=$("$@" 2>&1); _rc=$?
  printf '%s\n' "$_out" | sed 's/^/   /'
  return $_rc
}

# C6 -- the platform-attested deployment record.
#
# Until now nothing here told GitHub anything, which is why an approved PR
# reads "This branch has not been deployed" while the estate is serving its
# build. The record is not decoration: it is the only place the platform can
# answer "what is running in production" without trusting a human's summary.
#
# Two rules it has to obey, or it is worse than no record at all:
#   - OPEN BEFORE, RESOLVE AFTER. The deployment is created in_progress before
#     the deploy and only moves to success once gates/health.sh has actually
#     observed convergence. A record written from intent attests to nothing.
#   - THE REF IS THE PR'S HEAD. Keyed to the branch, so the panel on the PR is
#     about THIS change. auto_merge=false and required_contexts=[] because
#     guards 0 and 2 already ran above -- letting the API re-decide would put a
#     second, weaker gate in the path.
# SUPERSEDED 2026-09-13. These opened a GitHub Deployment in_progress before
# deploying and resolved it after -- GitHub's own model, and it produced records
# that described the WORKFLOW RUN rather than the environment. Every one
# deploy-staging opened resolved to failure, because that workflow dies at
# queue.sh before it deploys (#25), leaving PRs reading "1 failed deployment"
# while the estate served the build perfectly.
#
# change/settle.sh now writes the record once, at settlement, from an
# observation -- and keyed to the SHA, because the branch is gone by then.
# The disconnect that costs is documented there.
#
# Left in place because activate.sh is not on any working path today
# (docs/changing-the-pipeline.org measured ZERO invocations of it), and ripping
# it out is a bigger change than noting it.
DEPLOY_ID=''
deploy_open() {  # deploy_open <environment> <description>
  PROD=$([ "$1" = production ] && echo true || echo false)
  DEPLOY_ID=$(jq -nc --arg ref "$HEAD" --arg env "$1" --arg d "$2" --arg sha "$SHA" \
        --argjson pr "$PR" --argjson prod "$PROD" \
        '{ref:$ref,environment:$env,description:$d,auto_merge:false,
          required_contexts:[],production_environment:$prod,
          payload:{pr:$pr,sha:$sha}}' \
      | gh api "repos/$R/deployments" -X POST --input - 2>/dev/null \
      | jq -r '.id // empty')
  if [ -n "$DEPLOY_ID" ]; then
    deploy_state in_progress ''
    ok "deployment $DEPLOY_ID opened on $1 (in_progress)"
  else
    echo "   warn no deployment record on $1 (API refused) — C6 unattested"
  fi
}
deploy_state() {  # deploy_state <state> [environment_url]
  [ -n "$DEPLOY_ID" ] || return 0
  gh api "repos/$R/deployments/$DEPLOY_ID/statuses" -X POST \
    -f state="$1" -f description="observed by gates/health.sh" \
    ${2:+-f environment_url="$2"} >/dev/null 2>&1 || true
  # A resolved record is no longer this run's to fail. Without this, dying
  # after staging succeeded would rewrite staging's success as a failure --
  # the record would then describe the run, not the environment.
  case "$1" in success|failure|error) DEPLOY_ID='' ;; esac
}
# Any exit before convergence leaves a truthful record, not a dangling one.
# Replaced once a window is open, so the window closes too.
trap 'deploy_state failure' EXIT
ok()   { printf '   ok   %s\n' "$*"; }
die()  { printf '   FAIL %s\n' "$*"; exit 1; }

HEAD=$(gh pr view "$PR" --repo "$R" --json headRefName -q '.headRefName')
SHA=$(gh pr view "$PR" --repo "$R" --json headRefOid -q '.headRefOid' | cut -c1-7)
LABELS=$(gh pr view "$PR" --repo "$R" --json labels -q '[.labels[].name]|join(" ")')
GROUPS=$(echo "$LABELS" | tr ' ' '\n' | sed -n 's/^app://p' | tr '\n' ' ')
EMERG=$(echo "$LABELS" | grep -c 'itil:emergency' || true)
step "change under test"
echo "   PR #$PR  sha=$SHA"
echo "   labels: $LABELS"
echo "   groups: ${GROUPS:-none}"
[ -n "$GROUPS" ] || die "no app:* labels — nothing to deploy"

step "guard 2 — gates green on THIS head sha"
# ONE RULE, AND IT HAD TWO IMPLEMENTATIONS THAT DISAGREED.
#
# This read only the Checks API while gates/preflight.sh also counts the
# `local/` commit statuses that gates/report.sh posts when CI cannot run. On
# 2026-09-13, with GitHub not scheduling jobs (issue #34), preflight said
# PROCEED on #42 and this refused the same head in the same minute -- two
# answers to one question, from the same guard, thirty seconds apart.
#
# The local/ reading is the correct one and it lives in preflight, comments and
# all: DID NOT RUN IS NOT RED, and a local status is admissible because the
# gates actually ran and each status was gated on its command's exit code.
# Duplicated here rather than refactored, and the duplication is the bug -- see
# the issue. NO BYPASS is preserved: this still refuses unless something green
# exists, it just accepts the other admissible kind of green.
HEADSHA=$(gh pr view "$PR" --repo "$R" --json headRefOid -q .headRefOid)
LOCALS=$(gh api "repos/$R/commits/$HEADSHA/status" \
  --jq '[.statuses[]|select(.context|startswith("local/"))]' 2>/dev/null || echo '[]')
LOK=$(printf '%s' "$LOCALS"  | jq '[.[]|select(.state=="success")]|length' 2>/dev/null || echo 0)
LBAD=$(printf '%s' "$LOCALS" | jq '[.[]|select(.state!="success")]|length' 2>/dev/null || echo 0)
LSELF=$(printf '%s' "$LOCALS" | jq '[.[]|select(.context=="local/gate-selftest" and .state=="success")]|length' 2>/dev/null || echo 0)
# ONE VERDICT PER GATE, AND IT IS THE LATEST ONE. The check-runs endpoint
# returns EVERY run ever recorded against this SHA, not the current set. A
# re-run leaves the old attempt in the list, so without this collapse a gate
# that failed at 23:22 and passed at 01:58 is counted as both -- and the
# failing half wins, because the query asks "how many are not success".
#
# That is spec.org defect class 2, superseded is not current: the same shape
# as guard 2 counting a superseded check run as a verdict (scenario D15).
# preflight.sh was fixed for this; THIS COPY WAS NOT, and the two oracles
# then disagreed about one subject -- preflight said #61 was green on
# bfe2a21 and activate refused it as "4 gate(s) not green", naming four runs
# that had already been replaced. A guard that reads a stale attempt is not
# stricter than one that does not; it is wrong in the direction that looks
# safe, which is why it survived.
_runs() { gh api "repos/$R/commits/$HEADSHA/check-runs" \
            --jq '[.check_runs|group_by(.name)|map(max_by(.started_at))|.[]]'; }
_CUR=$(_runs)
BAD=$(printf '%s' "$_CUR" \
        | jq '[.[]|select(.name|test("^(gate-selftest|lint|test|e2e)$"))|select(.conclusion!="success")]|length')
SELF=$(printf '%s' "$_CUR" \
        | jq '[.[]|select(.name=="gate-selftest")|select(.conclusion=="success")]|length')
if [ "$LBAD" -eq 0 ] && [ "$LOK" -ge 3 ] && [ "$LSELF" -ge 1 ]; then
  ok "gates green on $SHA — $LOK local/ contexts, gate-selftest among them"
  ok "measured on a host, not by CI, and the contexts say so"
elif [ "$BAD" -eq 0 ] && [ "$SELF" -ge 1 ]; then
  ok "all four gates green, self-test passed"
else
  [ "$SELF" -ge 1 ] || die "gate-selftest did not pass and no local/ self-test either; gate results are void"
  die "$BAD gate(s) not green on $SHA, and no complete local/ report either"
fi

step "guard 0 — up to date with main"
STATE=$(gh pr view "$PR" --repo "$R" --json mergeStateStatus -q .mergeStateStatus)
case "$STATE" in
  BEHIND|DIRTY) [ "$EMERG" -gt 0 ] && ok "behind main, but itil:emergency" \
                                   || die "branch is $STATE relative to main — rebase first" ;;
  *) ok "mergeStateStatus=$STATE" ;;
esac

# guard 3 -- the change schedule.
#
# deploy-run is ACTIVATION. It must not book its own window: booking and
# deploying in one command is "reserving is not deploying" collapsed back into
# one act, and the whole reservation/activation split exists because the guards
# checked at booking are stale when the window opens. So this REQUIRES a window
# that already exists and covers right now, and refuses otherwise.
#
# Until now deploy-run called change/schedule.sh not at all: it deployed
# outside the schedule entirely, with no window and no freeze check, while
# .github/workflows/deploy-staging.yml booked one properly. Two owners of the
# same act, one of them ignoring the calendar.
# ORDER MATTERS: this runs BEFORE guard 1, not after.
#
# It was after, and that was a berth leak. Guard 1 claims the path to
# production by adding deploy:staging; refusing at guard 3 then exited with the
# berth still claimed, so a change deployed outside its window would wedge
# every other change in the repo until someone noticed the stale label. The
# window check needs no berth to run, so it runs first and nothing to release.
step "guard 3 — an open window covering now"
if ! EVENT=$(./change/schedule.sh current "$PR" staging); then
  cat >&2 <<MSG
   FAIL no open staging window covers now for #$PR.
        Reserving is not deploying, and deploying is not reserving either:
        this will not book itself a window, because the guards checked at
        booking are stale by the time a window opens -- which is the whole
        reason the two are separate acts.
        The berth was NOT claimed; nothing is blocked behind this.
        Recovery:  ./change/schedule.sh block $PR "$GROUPS" 30
        Schedule:  ./change/schedule.sh list --open
MSG
  exit 7
fi
./change/schedule.sh check "$EVENT" | sed 's/^/   /' || die "the window is inside a freeze"
ok "window $EVENT"
# The window closes with what happened, on every exit path. A window left open
# by a crashed run looks like a deployment still in progress and blocks the
# next booking on this environment forever.
trap 'deploy_state failure; ./change/schedule.sh close "$EVENT" "${RESULT:-failed}" >/dev/null 2>&1 || true' EXIT

step "guard 1 — claim the berth"
HOLDER=$(gh pr list --repo "$R" --state open --label deploy:staging --json number -q "[.[].number]|map(select(.!=$PR))|first // empty")
[ -z "$HOLDER" ] || die "staging held by #$HOLDER"
gh pr edit "$PR" --repo "$R" --add-label deploy:staging >/dev/null
ok "berth claimed"

step "deploy to staging"
deploy_open staging "standard change #$PR -> staging"
./targets/bastille/deploy.sh staging "$SHA" | sed 's/^/   /'
sleep 2
ok "sc-staging <- $SHA"

step "the authorizing run — e2e against staging"
ROUTER_URL="$FRONT_STG" indent ./gates/e2e.sh || die "staging e2e failed"
HEALTH_MODE=manifest HEALTH_SAMPLES=4 indent ./gates/health.sh "$FRONT_STG" "$SHA" \
  || die "staging is not serving $SHA -- the deploy did not take"
deploy_state success "$FRONT_STG"
gh pr edit "$PR" --repo "$R" --add-label staging:passed >/dev/null
ok "staging:passed@$SHA"

# guard 4c -- the human hold.
#
# A standard change that passes its gates goes to production without a person
# moving it (ADR 0001). hold:staging is how a person opts OUT of that for one
# change, to verify in staging by hand. Atypical by construction: if it is
# being used often, the gates are not trusted and that is the thing to fix.
#
# Checked HERE, not at staging:passed. The subject is a label a person can add
# at any moment, including while the staging e2e was running -- so it is read
# at the instant it is relied on. That is the same law as guard 4b, applied to
# a human instead of to trunk.
#
# Two things it deliberately does NOT do:
#   - the workflow never removes it. A hold a machine can lift is not a hold.
#   - it never expires INTO a promotion. The berth is a singleton, so a hold
#     wedges every other change; but the safe direction on expiry is to forfeit
#     -- release the berth, withdraw the pass, make the change re-request. A
#     hold that timed out into shipping would be the most dangerous label here.
step "guard 4c — human hold"
HELD=$(gh pr view "$PR" --repo "$R" --json labels -q '[.labels[].name]|index("hold:staging") // empty')
if [ -n "$HELD" ]; then
  deploy_state inactive
  RESULT=held
  trap - EXIT
  ./change/schedule.sh close "$EVENT" held | sed 's/^/   /'
  gh pr comment "$PR" --repo "$R" --body \
    "Held at staging by \`hold:staging\`. Staging is serving \`$SHA\` and the pass stands; production was not touched.

Remove the label to promote. The guards re-run when you do — the hold is time, and time is what guard 4b watches, so a hold long enough to be useful is long enough for \`main\` to move under you. Holding is not free: the berth stays claimed while nothing deploys." >/dev/null
  printf '\n\033[1m== held at staging (%s); production untouched\033[0m\n' "$SHA"
  echo "   remove hold:staging and re-run to promote; guards re-check on release"
  exit 0
fi
ok "no hold; a standard change that passed its gates promotes itself"

step "deploy to the IDLE colour"
CUR=$(./targets/bastille/front/switch.sh status | grep -o 'production = [a-z]*' | awk '{print $3}')
IDLE=$([ "$CUR" = blue ] && echo green || echo blue)
echo "   live=$CUR  idle=$IDLE"
deploy_open production "standard change #$PR -> production ($IDLE)"
./targets/bastille/deploy.sh production "$SHA" | sed 's/^/   /'
sleep 2
ok "both production replicas <- $SHA"

step "verify the idle colour BEFORE any traffic"
IDLE_IP=$([ "$IDLE" = blue ] && echo 10.0.0.61 || echo 10.0.0.62)
ROUTER_URL="http://$IDLE_IP" indent ./gates/e2e.sh || die "idle colour failed e2e"
ok "$IDLE verified with no traffic on it"

step "atomic cutover"
./targets/bastille/front/switch.sh "$IDLE" | sed 's/^/   /'
ok "production -> $IDLE"

step "guard 5 — convergence through the front"
HEALTH_MODE=manifest HEALTH_SAMPLES=5 indent ./gates/health.sh "$FRONT_PROD" "$SHA" \
  || die "production did not converge on $SHA"
# Only now. production:healthy and the success status are the same assertion
# told to two audiences, and both are downstream of the health check above.
deploy_state success "$FRONT_PROD"
RESULT=passed
trap - EXIT
./change/schedule.sh close "$EVENT" passed | sed 's/^/   /'
gh pr edit "$PR" --repo "$R" --add-label production:healthy >/dev/null
ok "converged; deployment $DEPLOY_ID -> success"

step "settle — release the berth"
gh pr edit "$PR" --repo "$R" \
  --remove-label deploy:staging --remove-label staging:passed >/dev/null
ok "berth freed; labels now: $(gh pr view "$PR" --repo "$R" --json labels -q '[.labels[].name]|join(", ")')"
printf '\n\033[1m== deployed %s to production (%s), rollback target = %s\033[0m\n' "$SHA" "$IDLE" "$CUR"
