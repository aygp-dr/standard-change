#!/bin/sh
# settle.sh <pr> -- the terminal transition. change:complete, then clear.
#
# THE TERMINAL STATE IS change:complete, NOT production:healthy AND NOT
# staging:uat, and the difference is not pedantry:
#
#   staging:uat          an observation about a BUILD -- a person accepted
#                        7cd3281, which says nothing about 8370c74
#   production:healthy   an observation about a BUILD -- the estate converged
#                        on this one
#   change:complete      about the CHANGE RECORD. Nothing remains to observe.
#
# Observations expire when the head moves; labeller.yml withdraws them on
# synchronize for exactly that reason. A change record does not expire, because
# it is a statement about something that happened rather than about something
# that is currently true.
#
# THE TWO NAMESPACES. staging:* and production:* are build/deploy ANNOTATIONS --
# facts about a build in an environment. change:* is the RECORD. Annotations are
# cleared at completion; the record is not, because it is the thing being kept.
#
# An earlier version of this comment claimed the PIR must be written first
# because clearing labels destroys the evidence. That is FALSE, and checking it
# was cheap: the PR timeline retains every label add and remove with actor and
# timestamp (25 events on #9). Clearing destroys nothing. The PIR is still
# written first, but for a weaker and truer reason -- a timeline of 25 label
# events is an audit trail, not an account, and someone reading this change in a
# year needs the account.
set -eu
cd "$(dirname "$0")/.."
pr="${1:?usage: settle.sh <pr>}"
R="${GH_REPO:-${GITHUB_REPOSITORY:-aygp-dr/standard-change}}"
FRONT="${FRONT_URL:-http://127.0.0.1:9230}"
rc=0
ok()   { printf '  ok    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; rc=1; }

labels=$(gh pr view "$pr" --repo "$R" --json labels -q '[.labels[].name]|join(" ")')
head=$(gh pr view "$pr" --repo "$R" --json headRefOid -q .headRefOid)
short=$(echo "$head" | cut -c1-7)
state=$(gh pr view "$pr" --repo "$R" --json state -q .state)
echo "settling #$pr @ $short"

# 1. It must actually be in production, observed now -- not "was healthy once".
served=$(curl -sI --max-time 5 "$FRONT/" | tr -d '\r' | awk 'tolower($1)=="x-build-sha:"{print $2}')
colour=$(curl -sI --max-time 5 "$FRONT/" | tr -d '\r' | awk 'tolower($1)=="x-colour:"{print $2}')
if [ "$served" = "$short" ]; then ok "production is serving $short ($colour), asked just now"
else bad "production serves '${served:-nothing}', not $short -- this change is not live"; fi

# 2. Require only the observations this script CANNOT take for itself.
#
#    production:healthy is deliberately NOT in this list. Step 1 above asks
#    production what it is serving, right now, from a host that can see it --
#    that IS guard 5, re-derived, and it is strictly better evidence than a
#    label. Requiring the label as well let merge-on-healthy.yml, which cannot
#    reach production at all, veto a settlement by withdrawing a measurement it
#    could not take. That happened three times on #9.
#
#    The rule this follows: prefer the observation you can make now over the
#    record of one somebody else made. Require the label only where the
#    measurement is NOT repeatable -- staging:uat above all, because a person
#    used the site and no script can re-run that.
# THE RECORD, NOT THE LABEL, for the instruments. On 2026-09-14 a sweep by a
# second operator -- reading a different estate than the one these
# observations were taken on -- withdrew every label from #92 after it had
# reached production healthy and guard 4 had authorized it; settle then refused
# for "evidence gone" while the evidence comments were still on the PR, each
# naming the build and the URL. guard 4 reads those records; settle read the
# labels. Same subject, two sources, and the weaker one vetoed. e2e and smoke
# are now checked the way guard 4 checks them: the latest record must be a
# pass on THIS head. The label stays required for staging:uat alone, because a
# person's withdrawal of an acceptance must stand and no record can overrule it.
for inst in e2e smoke; do
  o="staging:$inst"
  if ev=$(./change/evidence.sh latest "$pr" staging "$inst" 2>/dev/null); then
    verdict=${ev%% *}; rest=${ev#* }; evsha=${rest%% *}
    if [ "$verdict" = pass ] && [ "$evsha" = "$short" ]; then
      case " $labels " in
        *" $o "*) ok "$o" ;;
        *)        ok "$o (label withdrawn; the record on $short stands)" ;;
      esac
    elif [ "$evsha" != "$short" ]; then
      bad "$o observed $evsha, head is $short -- that measurement is about a different build"
    else
      bad "$o -- last observation is a FAILURE on $evsha"
    fi
  else
    bad "$o -- no observation recorded; nothing measured this build"
  fi
done
case " $labels " in
  *" staging:uat "*) ok "staging:uat" ;;
  *)                 bad "staging:uat missing -- a person's acceptance is not on the change (or was withdrawn); re-accept on staging" ;;
esac

[ "$rc" = 0 ] || { echo; echo "  NOT settled"; exit 1; }

# 2b. Was this change deployed inside a window? Recorded, not enforced, and the
#     distinction is deliberate: guard 3 enforces at ACTIVATION, which is the
#     moment where refusing is still cheap. By settlement the estate is already
#     serving the change, so refusing here would leave production ahead of
#     trunk -- a worse state than the one being objected to.
#
#     So this reports. CLAUDE.md: "Record deviations in the commit message and
#     the review ledger issue while the spec is at 0.x." A deviation that only
#     the person who committed it knows about is not recorded.
DEVIATION=''
if win=$(./change/schedule.sh current "$pr" staging 2>/dev/null); then
  ok "deployed inside window $win"
else
  last=$(./change/schedule.sh list 2>/dev/null | grep -c "#$pr " || echo 0)
  DEVIATION="**Deployed outside any change window.** \`schedule.sh current\` finds no open window covering this settlement, and none was open at cutover. $last window(s) were booked for this change and all are closed. Guard 3 exists in \`change/activate.sh\` and was never reached, because the deployment was hand-driven step by step rather than run through activation — the guard was present and bypassed by not being invoked. No production window was ever booked at all: \`CHANGE_ENV\` defaults to staging."
  printf '  DEVIATION  deployed outside any window -- recorded in the PIR\n'
fi

# 3. Merge. Production is already serving this, so trunk trailing it is the
#    divergence merge-on-healthy exists to prevent -- re-checked here because
#    main can move between that workflow and this one.
ms=$(gh pr view "$pr" --repo "$R" --json mergeStateStatus -q .mergeStateStatus)
case "$ms" in
  BEHIND|DIRTY)
    bad "main moved during the deploy ($ms). Production is AHEAD of main."
    gh pr edit "$pr" --repo "$R" --add-label blocked:diverged >/dev/null
    exit 9 ;;
esac
# The validation state machine ends here. Every guard has passed, production is
# observed serving this build, and the evidence is present -- so the change is
# COMPLETE, and that is a fact about the change rather than about the forge.
# Set before the merge, because the merge is what follows completion, not what
# constitutes it. Cleanup clears it once the forge records the merge.
gh pr edit "$pr" --repo "$R" --add-label change:complete >/dev/null 2>&1 || true
ok "change:complete -- validation done, merging"

# A FAILED MERGE MUST STOP SETTLEMENT. This was `gh pr merge ... && ok`, so a
# refusal printed nothing and execution continued: the PIR was posted, the
# window redlined `passed`, the validation labels cleared, and the summary said
# "settled: #N merged -- the forge is the record now" for a pull request that
# was still OPEN and CONFLICTING.
#
# Observed on #40 at 00:44Z. gh said "not mergeable: the merge commit cannot be
# cleanly created" -- its row in core's PANELS collided with #44's, which had
# landed ten minutes earlier -- and production had ALREADY been cut over to a
# build whose change is not on main. The state with no name, reached by a
# script that reported the opposite.
#
# Same shape as the `gate | sed` defect fixed earlier today: a step failed, its
# status was not checked, and the summary asserted success. Settlement is the
# one place that must not do this, because everything after it destroys the
# working state that would show what happened.
if [ "$state" = "MERGED" ]; then
  ok "already merged"
else
  if gh pr merge "$pr" --repo "$R" --squash --delete-branch >/dev/null 2>&1; then
    ok "merged, branch deleted"
  else
    echo >&2
    echo "REFUSED: the merge failed. Settlement STOPS here." >&2
    gh pr view "$pr" --repo "$R" --json mergeable,mergeStateStatus \
      -q '"  mergeable=\(.mergeable) state=\(.mergeStateStatus)"' >&2 2>/dev/null || true
    echo "  Nothing below this line has run: no PIR, no window redline, no label" >&2
    echo "  clearing. The change is deployed and NOT merged -- production is" >&2
    echo "  serving something main does not contain, and the next change will" >&2
    echo "  branch from a main without it and revert it on promotion." >&2
    echo "  Recover: resolve the conflict, or roll the front back to a colour" >&2
    echo "  whose build IS on main, then re-settle." >&2
    exit 8
  fi
fi

# 4. THE RECORD. Written before anything is cleared. This comment is what
#    survives the labels, so it must carry what the labels carried.
prev=$(curl -sI --max-time 5 "http://127.0.0.1:$([ "$colour" = blue ] && echo 9220 || echo 9210)/" \
        | tr -d '\r' | awk 'tolower($1)=="x-build-sha:"{print $2}')
gh pr comment "$pr" --repo "$R" --body "## Post-implementation review

**\`change:complete\`** — the terminal state. Everything below is recorded here because the labels are about to be cleared, and a label is working state, not the record.

| | |
|---|---|
| build | \`$short\` |
| production | \`$FRONT\` → **$colour** |
| rollback target | \`${prev:-none}\` on the idle colour |
| evidence at completion | \`$labels\` |

**Verdict strength: \`sampled\`, not \`attested\`.** Guard 5 probed N times and saw one build. It did not enumerate instances and their versions — nothing here can, because no platform runs this estate. Rounding \`sampled\` up to \`attested\` is the claim this project exists to refuse.

Worth recording, because it was found by walking this change: guard 5 in manifest mode passed on \`deadbee\`, a SHA that does not exist in this repository — the deployer wrote the manifest the guard read back. This change was verified in header mode against \`targets/node\`, which refuses a SHA that does not resolve. The manifest-mode defect is unfixed.

${DEVIATION:+## Deviation

$DEVIATION

}Rollback: \`./targets/node/switch.sh $([ "$colour" = blue ] && echo green || echo blue)\`" >/dev/null
ok "PIR posted -- the evidence now survives the labels"

# THE DEPLOYMENT RECORD, written here rather than at deploy time.
#
# Recording early looked right and was not. The deployer opens a record
# in_progress and resolves it later, which is GitHub's own model -- but every
# record deploy-staging opened today resolved to FAILURE, because the workflow
# dies at queue.sh before deploying (#25). The PR then said "1 failed
# deployment" while the estate was serving that build perfectly. The record
# described the WORKFLOW RUN, not the environment.
#
# By settlement, production has been observed serving this build. There is
# nothing left to intend, so the record is written from a fact.
#
# Keyed to the SHA, never the branch: settle.sh deletes the branch on merge, and
# GitHub refuses a deployment for a ref that no longer resolves. A record tied
# to a branch name cannot outlive the branch.
#
# THE DISCONNECT, stated rather than discovered. Recording only completed
# deployments means:
#   - the history shows no failures, because a failed deploy never reaches
#     settlement. "No failed deployments" will read as "nothing ever failed".
#   - "is a deploy in flight right now?" cannot be answered from the records.
#     That question belongs to the berth and to `lock`, not here.
#   - environment protection rules that gate on record CREATION (deployment
#     branch policies) fire after the fact, so they cannot refuse anything.
# All three are real losses, taken knowingly against a record that lied.
_full=$(git rev-parse "$head" 2>/dev/null || echo "$head")
for _env in staging production; do
  _url=$([ "$_env" = production ] && echo "$FRONT" || echo "${STAGING_URL:-http://192.168.86.29:9200}")
  _prod=$([ "$_env" = production ] && echo true || echo false)
  _id=$(jq -nc --arg ref "$_full" --arg env "$_env" --argjson prod "$_prod" --argjson pr "$pr" --arg sha "$short" \
         '{ref:$ref,environment:$env,description:"settled: observed serving this build",
           auto_merge:false,required_contexts:[],production_environment:$prod,
           payload:{pr:$pr,sha:$sha,recorded_by:"change/settle.sh"}}' \
        | gh api "repos/$R/deployments" -X POST --input - --jq '.id' 2>/dev/null)
  # Gate on the id. A loop that checked only the health exit code once reported
  # success against an HTTP 422 error blob.
  case "$_id" in ''|*[!0-9]*) echo "   warn no $_env deployment record (API refused) -- C6 unattested"; continue ;; esac
  gh api "repos/$R/deployments/$_id/statuses" -X POST -f state=success \
    -f environment_url="$_url" -f description="observed at settlement on $short" >/dev/null 2>&1 \
    && ok "$_env deployment record $_id -> success" \
    || echo "   warn $_env record $_id created but status not set"
done

# REDLINE THE WINDOW. settle.sh checked for one and never closed it, so #11
# merged and settled while its window stayed open until 17:00Z. An unredlined
# window is a defect for two reasons: the schedule keeps claiming a change is
# in flight, and schedule.sh refuses an OVERLAPPING window on the same
# environment -- so a settled change's ghost blocks the next booking.
# Caught when #19 tried to book and preflight said "not on the calendar".
if [ -n "${win:-}" ]; then
  ./change/schedule.sh close "$win" passed >/dev/null 2>&1 \
    && ok "window $win redlined: passed" \
    || echo "   warn could not close window $win -- check the schedule by hand"
fi

# 5. Clear. Two different reasons, and the second is the load-bearing one.
#
#    ANNOTATIONS THAT RECORD -- staging:e2e, staging:uat, production:healthy.
#    Cleared because the PIR above summarises them and the PR timeline keeps
#    every add and remove with actor and timestamp. Nothing is lost.
#
#    ANNOTATIONS THAT HOLD -- deploy:staging IS the berth claim; guard 1 reads
#    it to decide whether the path to production is free. deploy:production and
#    blocked:* are the same shape. These are not notes about the change, they
#    are a lease on an environment, and leaving one set means the NEXT change
#    can never start. Clearing them is the release, not the tidying.
#
#    change:complete IS cleared here. It was set before the merge as the
#    terminal state of VALIDATION; once the forge records MERGED it restates
#    a fact the platform owns, and two records of one fact can disagree while
#    the platform's cannot.
#
#    NOT cleared: app:* and itil:* describe what the change WAS.
#    describe what the change was, and remain true after it shipped.
for l in change:start change:requested change:scheduled change:complete release release:start \
         staging:deployed staging:healthy production:deployed \
        deploy:staging deploy:production \
         staging:e2e staging:smoke staging:uat staging:passed staging:failed \
         staging:in-progress staging:e2e-failed staging:smoke-failed \
         production:e2e production:smoke production:healthy \
         production:e2e-failed production:smoke-failed \
         deployed:production blocked:queue blocked:lock blocked:diverged release; do
  gh pr edit "$pr" --repo "$R" --remove-label "$l" >/dev/null 2>&1 || true
done
# THE TOMBSTONE, last. change:end says the clearing above was settlement --
# a refusal at the lock, the reaper and an eviction also leave a change with
# no labels, and a reader should be able to tell those apart. It drives
# nothing; change:complete drove the merge and the PIR before it was cleared.
gh pr edit "$pr" --repo "$R" --add-label change:end >/dev/null 2>&1 || true
ok "berth released; validation labels cleared, change:complete included; change:end written"

echo
echo "  settled: #$pr merged -- the forge is the record now"

# The deployment marker FOLLOWS the release-complete notice, deliberately: it
# is telemetry about a release that has already happened, not a step the
# release depends on. marker.sh asks the front what it is serving rather than
# being handed a build, and exits 0 even when it cannot send, so a dashboard
# being down can never fail a deployment that succeeded.
./change/marker.sh "$pr" || true
echo "  labels:  $(gh pr view "$pr" --repo "$R" --json labels -q '[.labels[].name]|join(" ")')"
