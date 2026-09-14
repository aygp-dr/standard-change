#!/bin/sh
# abort.sh <pr> "<reason>" [--backed-out] -- close a change that did NOT succeed.
#
# THE VERB THAT DID NOT EXIST. Every cleanup in this pipeline ran only on the
# success path: settle.sh clears the labels, redlines the window and releases
# the berth, and it is reachable only by a change that reached production
# healthy. A change that failed, or ran out of window, or was withdrawn, had
# nowhere to go -- so it kept the berth, kept its observation labels, and left a
# window open forever. docs/adr/0001: "we have only ever walked the positive
# case" (issue #37).
#
# ITIL CLOSURE CODES. A change record closes with a code, and "failed" and
# "backed out" are different facts:
#
#   failed       the change did not complete. Production never took it, or took
#                it and it was never made live. Nothing to undo.
#   backed out   production DID serve this change and was returned to the prior
#                state. There is an estate action behind this word, and
#                --backed-out asserts it HAPPENED, so this script refuses the
#                flag unless a rollback target is named.
#
# WHAT IT DOES NOT DO. It does not merge, it does not deploy, and it does not
# roll production back by itself -- switch.sh does that, loudly, and a person
# runs it. This records what happened and puts the estate back into a state the
# next change can use. Recording a rollback is not performing one.
set -eu
cd "$(dirname "$0")/.."
PR="${1:?usage: abort.sh <pr> \"<reason>\" [--backed-out] [--dry-run]}"
REASON="${2:?a reason is required -- a closure with no cause is not a record}"
CODE=failed
ROLLBACK=''
DRY=''
shift 2
while [ $# -gt 0 ]; do
  case "$1" in
    --backed-out) CODE=backed-out; shift ;;
    --to)         ROLLBACK="${2:?--to needs a sha}"; shift 2 ;;
    # --dry-run, for the same reason reap.sh has one: the only way to learn
    # what the failure path does is to walk it, and walking it for real costs a
    # change record and a set of labels that cannot be put back. It does every
    # READ -- including the estate probe and the refusal above, which is the
    # part worth previewing -- and no write.
    --dry-run)    DRY=1; shift ;;
    *)            echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
R="${GH_REPO:-${GITHUB_REPOSITORY:-aygp-dr/standard-change}}"

if [ "$CODE" = backed-out ] && [ -z "$ROLLBACK" ]; then
  echo "refused: --backed-out says production served this change and was returned" >&2
  echo "  to a prior state. Name it:  --to <sha>. A closure code that asserts an" >&2
  echo "  estate action nobody can point at is the forged-evidence defect." >&2
  exit 3
fi

HEAD=$(gh pr view "$PR" --repo "$R" --json headRefOid -q .headRefOid)
SHORT=$(echo "$HEAD" | cut -c1-7)
LABELS=$(gh pr view "$PR" --repo "$R" --json labels -q '[.labels[].name]|join(", ")')
STATE=$(gh pr view "$PR" --repo "$R" --json state -q .state)

echo "aborting #$PR @ $SHORT  closure=$CODE"
echo "  labels before: $LABELS"

# ---------------------------------------------------------------------------
# 0. WHAT IS THE ESTATE ACTUALLY SERVING?
# ---------------------------------------------------------------------------
# This script used to end with the line
#
#   the change is CLOSED failed. It is not merged and not deployed.
#
# printed unconditionally, on every path, having measured neither. Issue #37
# asked for an abort verb that would "state what the estate is now serving",
# and what got written states it without looking -- observation is not intent
# (spec.org, The defect taxonomy #3), in the script added to fix the issue
# about the failure path never having been walked. The taxonomy is recursive
# and this is another instance of it.
#
# It matters most in exactly the state this script exists to close out. D13:
# the change was DEPLOYED AND NOT MERGED -- the front serving a build main did
# not contain -- and settle.sh reported the opposite while every downstream
# step destroyed the evidence. An abort that asserts "not deployed" over a
# production replica currently serving this SHA is the same sentence from the
# other side.
#
# THREE ANSWERS, AND THE THIRD DOES NOT BECOME THE SECOND. change/serving.sh
# exits 4 when the front cannot be reached, which is not "nothing is deployed".
# An unobservable estate does NOT block the closure -- no runner can reach this
# estate at all, and a change that cannot be closed out because the front is
# down is a berth held forever for no reason. It blocks nothing and asserts
# nothing: the record says the estate was not observed, and names the command.
FRONT="${PRODUCTION_FRONT_URL:-${FRONT_URL:-http://127.0.0.1:9230}}"
if SERVING=$(./change/serving.sh "$FRONT" 2>/dev/null); then
  SERVING_SHORT=$(printf '%s' "$SERVING" | cut -c1-7)
  if [ "$SERVING_SHORT" = "$SHORT" ]; then
    ESTATE="serving THIS change ($SERVING_SHORT)"
  else
    ESTATE="serving $SERVING_SHORT, which is not this change"
  fi
else
  SERVING=''
  SERVING_SHORT=''
  ESTATE="NOT OBSERVED -- $FRONT did not answer. Check with: ./change/serving.sh $FRONT"
fi
echo "  production:    $ESTATE"
echo "  pull request:  $STATE"

# THE ONE THING THAT REFUSES, and only on a positive contrary observation.
#
# `failed` means the change did not complete: production never took it, or took
# it and it was never made live, and there is NOTHING TO UNDO. If a production
# replica is serving this build right now, that sentence is false, and writing
# it into the change record is the forged-evidence defect this repo keeps
# finding. `backed-out` is no better -- it says production WAS returned to a
# prior state, and it plainly has not been.
#
# So there is no closure code that fits, and that is not a gap in the argument:
# it is spec.org's boundary condition with no name, "deployed, not merged, and
# the window is gone", arriving at the one script whose job is to name what
# happened. The estate has to move before the record can.
#
# Refusing only on a POSITIVE observation is the whole of the rule. Unreachable
# above did not refuse, because "I could not look" is not evidence of anything.
if [ -n "$SERVING_SHORT" ] && [ "$SERVING_SHORT" = "$SHORT" ]; then
  echo >&2
  echo "refused: production ($FRONT) is serving $SERVING_SHORT -- this change's own build." >&2
  echo "  \`$CODE\` would record that production did not take this change, or took it" >&2
  echo "  and was returned. Neither is true while a replica is serving it: closing" >&2
  echo "  now would put a false sentence in the change record and clear the labels" >&2
  echo "  that are the only remaining evidence of what is out there." >&2
  echo >&2
  echo "  This is the state spec.org names as having no name -- deployed, not" >&2
  echo "  settled. Move the estate first, then close:" >&2
  echo >&2
  echo "    ./targets/node/switch.sh <other colour>      # return production" >&2
  echo "    ./change/serving.sh $FRONT   # confirm it moved" >&2
  echo "    ./change/abort.sh $PR \"<reason>\" --backed-out --to <sha it returned to>" >&2
  echo >&2
  echo "  Nothing has been written. The berth, the window and the labels are" >&2
  echo "  exactly as they were." >&2
  exit 1
fi

# MERGED IS NOT FAILED EITHER, and for the same reason: trunk contains this
# change, so "the change did not complete" is false about the half that did.
# Left as a warning rather than a refusal -- a merged change whose DEPLOYMENT
# failed is a real and ordinary thing, and the record should say so in the
# reason rather than be blocked.
if [ "$STATE" = MERGED ]; then
  echo "  note: #$PR is MERGED. Closing \`$CODE\` records that the DEPLOYMENT did not"
  echo "        complete; trunk still contains this change. Say which in the reason."
fi

# 1. THE RECORD FIRST, because everything below destroys the working state that
#    evidences it. Same order as settle.sh, for the same reason.
BODY="## Change closed: **$CODE**

**Build:** \`$SHORT\`
**Reason:** $REASON
**Labels at closure:** $LABELS
**Pull request state:** $STATE
**Production at closure:** $ESTATE"
[ -n "$ROLLBACK" ] && BODY="$BODY
**Rolled back to:** \`$(echo "$ROLLBACK" | cut -c1-7)\`"
BODY="$BODY

This change did **not** reach \`change:complete\`. The deployment annotations
below are cleared by this comment's own action, so they are recorded here
first — a label is working state, not the record.

\`app:*\` and \`itil:*\` are **not** cleared: they describe what the change *was*,
and that is still true of a change that failed."
if [ -n "$DRY" ]; then
  echo
  echo "  --dry-run: nothing below is performed. The record that WOULD be posted:"
  printf '%s\n' "$BODY" | sed 's/^/  | /'
  echo
  echo "  would then: withdraw the deployment records for $SHORT,"
  echo "              close the open staging window \`$CODE\`,"
  echo "              clear the deployment annotations and set change:$CODE,"
  echo "              and leave app:* and itil:* alone."
  exit 0
fi
gh pr comment "$PR" --repo "$R" --body "$BODY" >/dev/null
echo "  ok   closure record posted"

# 2. Withdraw the deployment records. A deployment that did not end up serving
#    must not read as success in the forge's own deployment history, which is
#    what a reader consults when the PR is long closed.
for id in $(gh api "repos/$R/deployments" --jq \
      "[.[]|select(.sha==\"$HEAD\")|.id]|.[]" 2>/dev/null || true); do
  gh api "repos/$R/deployments/$id/statuses" -X POST -f state=failure \
    -f description="change closed $CODE: $REASON" >/dev/null 2>&1 \
    && echo "  ok   deployment $id -> failure"
done

# 3. Redline the window. An open window is a booked berth; leaving one open is
#    how the schedule silently fills with changes nobody is running.
EV=$(./change/schedule.sh current "$PR" staging 2>/dev/null || true)
if [ -n "$EV" ]; then
  ./change/schedule.sh close "$EV" "$CODE" >/dev/null 2>&1 \
    && echo "  ok   window $EV closed: $CODE"
fi

# 4. Clear the working state. Observations are about a build that is not going
#    to production, and release:start claims a release is IN FLIGHT.
for l in staging:e2e staging:e2e-failed staging:smoke staging:smoke-failed \
         staging:uat staging:in-progress production:e2e production:e2e-failed \
         production:smoke production:smoke-failed production:healthy \
         release release:start deploy:staging change:scheduled; do
  gh pr edit "$PR" --repo "$R" --remove-label "$l" >/dev/null 2>&1 || true
done
# LITERAL LABEL NAMES. Interpolating the closure code into the label works at
# runtime and is invisible to gates/label-audit.py, which reads the SOURCE: it
# saw a write of the bare prefix and correctly called it undeclared. A label an
# auditor cannot see is a label with no owner, which is the condition
# docs/label-ownership.org exists to prevent. So the branch is written out.
#
# This comment deliberately does NOT spell the prefix out. The first version
# did, while explaining the problem, and the audit flagged the COMMENT -- the
# same shape as a shellcheck note that begins with the tool's own name and is
# parsed as a directive. A static auditor cannot tell prose from code.
case "$CODE" in
  backed-out) gh pr edit "$PR" --repo "$R" --add-label change:backed-out >/dev/null 2>&1 || true ;;
  *)          gh pr edit "$PR" --repo "$R" --add-label change:failed     >/dev/null 2>&1 || true ;;
esac

echo "  ok   berth released; deployment annotations cleared"
echo "  labels after:  $(gh pr view "$PR" --repo "$R" --json labels -q '[.labels[].name]|join(", ")')"
echo
# WHAT WAS OBSERVED, NOT WHAT IS ASSUMED. The previous version of this line
# read "It is not merged and not deployed" on every path, having measured
# neither -- see the block at the top of this file.
echo "  the change is CLOSED $CODE."
echo "    pull request  $STATE"
echo "    production    $ESTATE"
echo "  To try again: fix, push, and book a new window. The old evidence is gone"
echo "  on purpose -- it was about a build that did not ship."
