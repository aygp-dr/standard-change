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
for o in staging:e2e staging:smoke staging:uat; do
  case " $labels " in
    *" $o "*) ok "$o" ;;
    *)        bad "$o missing -- cannot complete a change whose evidence is gone" ;;
  esac
done

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
if [ "$state" = "MERGED" ]; then ok "already merged"
else gh pr merge "$pr" --repo "$R" --squash --delete-branch >/dev/null && ok "merged, branch deleted"; fi

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
#    NOT cleared: change:complete is the record. app:* and change:standard
#    describe what the change was, and remain true after it shipped.
for l in change:requested deploy:staging deploy:production \
         staging:e2e staging:smoke staging:uat staging:passed staging:failed \
         staging:in-progress staging:e2e-failed staging:smoke-failed \
         production:e2e production:smoke production:healthy \
         production:e2e-failed production:smoke-failed \
         deployed:production blocked:queue blocked:lock blocked:diverged release; do
  gh pr edit "$pr" --repo "$R" --remove-label "$l" >/dev/null 2>&1 || true
done
gh pr edit "$pr" --repo "$R" --add-label change:complete >/dev/null
ok "berth released, working labels cleared"

echo
echo "  settled: #$pr is change:complete"
echo "  labels:  $(gh pr view "$pr" --repo "$R" --json labels -q '[.labels[].name]|join(" ")')"
