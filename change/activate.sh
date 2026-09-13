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
FRONT_STG=http://127.0.0.1:9201
cd "$(dirname "$0")"

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

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
BAD=$(gh api "repos/$R/commits/$(gh pr view "$PR" --repo "$R" --json headRefOid -q .headRefOid)/check-runs" \
        --jq '[.check_runs[]|select(.name|test("^(gate-selftest|lint|test|e2e)$"))|select(.conclusion!="success")]|length')
SELF=$(gh api "repos/$R/commits/$(gh pr view "$PR" --repo "$R" --json headRefOid -q .headRefOid)/check-runs" \
        --jq '[.check_runs[]|select(.name=="gate-selftest")|select(.conclusion=="success")]|length')
[ "$BAD" -eq 0 ] || die "$BAD gate(s) not green on $SHA"
[ "$SELF" -ge 1 ] || die "gate-selftest did not pass; gate results are void"
ok "all four gates green, self-test passed"

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
ROUTER_URL="$FRONT_STG" ./gates/e2e.sh | tail -1 | sed 's/^/   /' || die "staging e2e failed"
HEALTH_MODE=manifest HEALTH_SAMPLES=4 ./gates/health.sh "$FRONT_STG" "$SHA" | sed 's/^/   /'
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
ROUTER_URL="http://$IDLE_IP" ./gates/e2e.sh | tail -1 | sed 's/^/   /' || die "idle colour failed e2e"
ok "$IDLE verified with no traffic on it"

step "atomic cutover"
./targets/bastille/front/switch.sh "$IDLE" | sed 's/^/   /'
ok "production -> $IDLE"

step "guard 5 — convergence through the front"
HEALTH_MODE=manifest HEALTH_SAMPLES=5 ./gates/health.sh "$FRONT_PROD" "$SHA" | sed 's/^/   /' \
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
