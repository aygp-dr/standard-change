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
# WHAT IT TRUSTS, AND WHY. It reads the production:healthy label rather than
# probing production, because no GitHub runner can reach any environment here
# (docs/label-ownership.org, rule 2). The label is a proxy for the check run a
# reachable environment would have reported. That is weaker than probing and it
# is stated rather than hidden: the label is written only by gates/health.sh,
# and labeller.yml withdraws it on every push, so it cannot outlive its build.
set -eu
cd "$(dirname "$0")/.."
pr="${1:?usage: production-first.sh <pr>}"
repo="${GH_REPO:-${GITHUB_REPOSITORY:-aygp-dr/standard-change}}"

labels=$(gh pr view "$pr" --repo "$repo" --json labels -q '[.labels[].name]|join(" ")')
groups=$(./change/groups.sh "$pr" 2>/dev/null || true)

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
case " $labels " in
  *" production:healthy "*)
    echo "  ok    production:healthy is present on the current head"
    echo "        (written by gates/health.sh; withdrawn by the labeller on every push,"
    echo "         so it cannot describe a build other than this one)"
    exit 0 ;;
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
  NOT YET  production:healthy is absent. This is the expected state for a
           change that has not been deployed yet -- it is not a broken test.

        This change redeploys [$groups] and has not been observed running in
        production. Merging now would put main ahead of the estate: main would
        assert a change that no production replica is serving.

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
