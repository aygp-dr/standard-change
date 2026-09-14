#!/bin/sh
# production-first.sh <pr> -- a change that deploys must reach PRODUCTION
# before it reaches main.
#
# THE ORDERING THIS ENFORCES. In this model the merge is SETTLEMENT, not
# authorization: production deploys from the branch, converges, and main
# follows. Trunk trailing production for the length of a window is the intended
# state; trunk RUNNING AHEAD of production is not.
#
# It exists because on 2026-09-13 #12 -- a security fix -- was merged to main
# on the strength of staging alone. main then said the XSS was fixed while
# every production replica still served the vulnerable build. Nothing stopped
# it: merge-on-healthy.yml TRIGGERS on production:healthy, and a trigger is not
# a gate. `gh pr merge` walked straight past it.
#
# WHAT IT TRUSTS, AND WHY. It cannot probe production: no GitHub runner can
# reach any environment here (docs/label-ownership.org, rule 2). So it relies
# on what gates/health.sh recorded when it ran where production IS visible.
#
# It used to rely on the production:healthy LABEL, with the reasoning that
# "labeller.yml withdraws it on every push, so it cannot outlive its build".
# That reasoning was load-bearing and it was wrong: on #11 the withdrawal did
# not fire and observations taken on 9d85a33 sat on a head of baed821 (issue
# #16). A guard that is sound only while another workflow keeps firing fails
# OPEN when it stops.
#
# It now reads health.sh's observation RECORD, which names the SHA that was
# sampled, and requires it to name the head being merged. The label is still
# required alongside it -- a person or a later run may withdraw it, and that
# withdrawal should still stop a merge -- but the label is no longer what
# establishes that the measurement is about THIS build.
set -eu
cd "$(dirname "$0")/.."
pr="${1:?usage: production-first.sh <pr>}"
repo="${GH_REPO:-${GITHUB_REPOSITORY:-aygp-dr/standard-change}}"
EV="./change/evidence.sh"

labels=$(gh pr view "$pr" --repo "$repo" --json labels -q '[.labels[].name]|join(" ")')

# THE LABELS ARE NOT HERE YET WHEN THIS RUNS, AND THEY NEVER WILL BE.
#
# Issue #29. This check fires on `pull_request: opened`. actions/labeler writes
# app:* about eight seconds later. On #28 the two are on the clock:
#
#   17:03:50  production-first  -> "no app:* labels -- nothing deploys"  success
#   17:03:58  labeller adds app:core
#
# and the same script run by hand afterwards said NOT YET, exit 1. Opposite
# verdict, same PR, same head; the only difference was when.
#
# The `labeled` type in this workflow's trigger list was supposed to correct
# that. It cannot: actions/labeler writes with GITHUB_TOKEN, and an event
# produced by GITHUB_TOKEN does not start another workflow run. That is
# GitHub's loop prevention working as designed, and the consequence is that the
# labeller can never wake the gate that reads its labels. 484 runs of this
# workflow, none of them from a label. So the gate evaluated exactly once, in
# the only window where the labels are guaranteed absent, and then never again
# -- a required status check structurally incapable of blocking a new PR.
#
# It now derives from the DIFF, unioned with whatever labels have since
# arrived. .github/workflows/labeller.yml learned this one workflow over:
# "Derive from the DIFF, not from the labels actions/labeler just wrote."
#
# AND THE `|| true` IS GONE. It turned "gh could not answer" into "this change
# deploys nothing", which this script then reports as `ok` and exits 0. That is
# defect class 1 -- unreachable is not falsified -- inside the guard, and it is
# the second way this check could not block. An unreachable forge must refuse.
groups=$(./change/groups.sh --union "$pr")

# NOT EVERY app:* LABEL IS A THING WE DEPLOY.
#
# external/ holds stand-ins for services we do not own. mock runs in every
# environment because the estate needs something at /api/, but it is test
# infrastructure, not a deployable of ours -- there is no production release of
# somebody else's service for us to wait on. It needs to RUN; it does not need
# a production deployment.
#
# The distinction is the directory, which is why the mock was moved out of
# apps/ in the first place: apps/ means deployable unit. app:mock lives in the
# app:* namespace for routing and labelling, and that namespace turned out to
# conflate two things.
EXTERNAL="mock"
deployable=""
for g in $groups; do
  skip=0
  for e in $EXTERNAL; do [ "$g" = "$e" ] && skip=1; done
  [ "$skip" = 0 ] && deployable="$deployable $g"
done
deployable=$(printf '%s' "$deployable" | sed 's/^ //')

# A change with no deployable surface cannot be "in production" and must not be
# held hostage to a deployment it does not need. Docs, notes, pipeline-only
# changes and external stubs merge on their gates alone.
if [ -z "$groups" ]; then
  echo "  ok    no app:* labels -- nothing deploys, so nothing to wait for"
  exit 0
fi
if [ -z "$deployable" ]; then
  echo "  ok    touches only external stand-ins [$groups] -- not ours to deploy"
  echo "        external/ is a service we do not own. It must RUN, which the"
  echo "        gates already assert; there is no production release of it to"
  echo "        wait on. It still has to pass lint, test and e2e."
  exit 0
fi
groups="$deployable"

echo "  this change deploys: $groups"

head=$(gh pr view "$pr" --repo "$repo" --json headRefOid -q .headRefOid | cut -c1-7)

# TWO DIFFERENT REDS, AND THEY MUST NOT READ ALIKE.
#
#   NOT YET   nothing has been deployed. The expected state for most of a PR's
#             life, and not a finding about anything.
#   FAIL      something claims to have been observed and the claim does not
#             hold up -- the label is here and the measurement behind it is
#             missing, failed, or about a different build. That IS a finding.
#
# Collapsing them was half of #16: the label's presence was the whole signal,
# so "observed on an older build" and "observed on this one" looked identical.
lede='FAIL'
why=''
case " $labels " in
  *" production:healthy "*)
    if ev=$("$EV" latest "$pr" production healthy 2>/dev/null); then
      verdict=${ev%% *}; rest=${ev#* }; evsha=${rest%% *}; who=${rest#* }
      if [ "$verdict" = pass ] && [ "$evsha" = "$head" ]; then
        echo "  ok    production:healthy, and gates/health.sh recorded it on $head (by $who)"
        exit 0
      elif [ "$verdict" != pass ]; then
        why="the last production:healthy observation is a FAILURE on \`$evsha\`."
      else
        why="production:healthy is on this PR, but the observation behind it names
           \`$evsha\` and the head is \`$head\`. That measurement is about a
           different build. This is the #16 shape: the label survived a push the
           measurement did not."
      fi
    else
      why="production:healthy is on this PR, but no observation record stands
           behind it. gates/health.sh records the SHA it sampled; a label with
           no record is a claim nobody can date."
    fi ;;
  *) lede='NOT YET'
     why="production:healthy is absent. This is the expected state for a
           change that has not been deployed yet -- it is not a broken test." ;;
esac

# RED HERE IS NORMAL, AND SAYING SO MATTERS.
#
# This check is red for most of a PR's life, by design -- it goes green only
# after production converges. A red X that is indistinguishable from a broken
# test trains people to ignore red, which is the failure mode a required check
# is supposed to prevent.
#
# It cannot report `neutral` instead: GitHub counts neutral as passing for
# required checks, so it would stop blocking and the gate would be decoration.
# Failure is the only conclusion that blocks, so the fix is the message.
cat <<MSG
  $lede  $why

        This change redeploys [$groups] and has not been observed running in
        production ON THIS HEAD. Merging now would put main ahead of the
        estate: main would assert a change that no production replica is
        serving.

        The merge is settlement, not authorization. Deploy to production
        first, let gates/health.sh observe convergence, then merge.

          ./targets/node/deploy.sh production-<idle colour> <sha>
          ./gates/health.sh --pr $pr <front-url> <sha>
          ./targets/node/switch.sh <colour>

        This check re-runs on every label change, so it turns green by itself
        the moment gates/health.sh records production:healthy. Nothing to
        re-push.

        To merge anyway you must remove the app:* labels, which is a claim that
        this change deploys nothing -- visible, and false if it is false.
MSG
exit 1
