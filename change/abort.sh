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
PR="${1:?usage: abort.sh <pr> \"<reason>\" [--backed-out]}"
REASON="${2:?a reason is required -- a closure with no cause is not a record}"
CODE=failed
ROLLBACK=''
shift 2
while [ $# -gt 0 ]; do
  case "$1" in
    --backed-out) CODE=backed-out; shift ;;
    --to)         ROLLBACK="${2:?--to needs a sha}"; shift 2 ;;
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

echo "aborting #$PR @ $SHORT  closure=$CODE"
echo "  labels before: $LABELS"

# 1. THE RECORD FIRST, because everything below destroys the working state that
#    evidences it. Same order as settle.sh, for the same reason.
BODY="## Change closed: **$CODE**

**Build:** \`$SHORT\`
**Reason:** $REASON
**Labels at closure:** $LABELS"
[ -n "$ROLLBACK" ] && BODY="$BODY
**Rolled back to:** \`$(echo "$ROLLBACK" | cut -c1-7)\`"
BODY="$BODY

This change did **not** reach \`change:complete\`. The deployment annotations
below are cleared by this comment's own action, so they are recorded here
first — a label is working state, not the record.

\`app:*\` and \`itil:*\` are **not** cleared: they describe what the change *was*,
and that is still true of a change that failed."
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
#
# deploy:production WAS MISSING FROM THIS LIST. Found on #92, a change aborted
# `failed` that kept advertising a production deploy afterwards -- and
# deploy-production.yml fires on that label, so an abandoned change stayed
# armed to re-enter production on the next label event. deploy:staging was
# cleared and its sibling was not, which is the whole defect: the list is
# written by hand and nothing checks it against the labels this pipeline can
# set. change:complete is here for the same reason -- a change that failed did
# not complete, and abort must not leave the success label standing.
for l in staging:e2e staging:e2e-failed staging:smoke staging:smoke-failed \
         staging:uat staging:in-progress production:e2e production:e2e-failed \
         production:smoke production:smoke-failed production:healthy \
         release release:start deploy:staging deploy:production \
         change:complete change:scheduled; do
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
echo "  the change is CLOSED $CODE. It is not merged and not deployed."
echo "  To try again: fix, push, and book a new window. The old evidence is gone"
echo "  on purpose -- it was about a build that did not ship."
