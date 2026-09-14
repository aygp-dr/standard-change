#!/bin/sh
# deploy-provenance.sh <env> <sha> [--rollback] -- the other half of
# production-first. Exit 0 proceed, 1 refused, 4 could not determine.
#
# WHAT IT ENFORCES. A production deployment must come from an OPEN pull
# request's head, not from main.
#
# gates/production-first.sh enforces one direction of the ordering: main must
# not run ahead of production. Nothing enforced the other: production must not
# run behind a merge. targets/node/deploy.sh refused a fabricated SHA and had
# no opinion about which REAL commit it was handed, so main's HEAD was as
# acceptable as a branch head (issue #26).
#
# WHY IT IS NOT TIDINESS. In this model the merge is SETTLEMENT: production
# deploys from the branch under review, converges, and trunk follows. So at the
# moment of a production deploy the change is by definition NOT yet on main. A
# deploy of main is therefore a deploy of every change merged since the last
# one -- which is a release, not a change. The window, the UAT, the PIR and the
# deployment record would all name a single PR while the build contains N.
#
# It is also what keeps blue/green rollback meaningful. The idle colour is
# supposed to hold THE PREVIOUS CHANGE. If deploys come from main the idle
# colour is an arbitrary trunk state, and "roll back" stops meaning "undo this
# change" and starts meaning "whatever was there last".
#
# THE THREE EDGE CASES, DECIDED RATHER THAN ASSUMED (issue #26 asked for this).
#
#   rollback    A rollback deploys an old SHA that is now on main, and must
#               stay possible. It is NOT a change deploy, so it is an explicit
#               MODE rather than an exception: --rollback. It is not a free
#               pass -- the SHA must have a deployment record in the forge,
#               i.e. this estate served it before. "Roll back to a build that
#               was never deployed" is a deploy wearing a rollback's name.
#
#   emergency   itil:emergency does NOT bypass this. It bypasses guards 0 and 1
#               -- being behind main, and the berth -- because those are about
#               ORDERING AGAINST OTHER CHANGES, and an emergency is allowed to
#               go first. This guard is about what the build CONTAINS, and an
#               emergency remedy is still one change on one branch. An
#               emergency deployed from main ships every unrelated change
#               merged since the last deploy, at the worst possible moment,
#               with nobody looking at any of them. If the emergency has no
#               branch, it is not ready to deploy.
#
#   bootstrap   The first deploy into an empty estate has no PR. It also has no
#               production to protect, so it is a dev or staging deploy in
#               everything but name -- and every non-production environment is
#               waved through below. Bring production up from the PR that
#               introduces it.
#
# UNREACHABLE IS NOT FALSIFIED, AND IT IS NOT AUTHORIZED EITHER. If `gh` cannot
# answer, this exits 4 and blocks (docs/exit-codes.org). A guard whose subject
# could not be observed has not been satisfied.
set -eu
cd "$(dirname "$0")/.."
env="${1:?usage: deploy-provenance.sh <env> <sha> [--rollback]}"
sha="${2:?usage: deploy-provenance.sh <env> <sha> [--rollback]}"
ROLLBACK=''
shift 2
while [ $# -gt 0 ]; do
  case "$1" in
    --rollback) ROLLBACK=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
repo="${GH_REPO:-${GITHUB_REPOSITORY:-aygp-dr/standard-change}}"

# ONLY PRODUCTION. dev blocks are disposable and staging is meant to be churned
# -- both are deployed from whatever somebody wants to look at, which is the
# point of having them. Widening this to staging would break the ordinary
# "deploy main to staging and see" and protect nothing.
case "$env" in
  production-*|production) ;;
  *) exit 0 ;;
esac

short=$(printf '%s' "$sha" | cut -c1-7)

if [ -n "$ROLLBACK" ]; then
  # A rollback target must be a build this estate has already served. The forge's
  # deployment history is the record, and it is the one place that survives the
  # labels being cleared.
  if ! recs=$(gh api "repos/$repo/deployments?sha=$sha" --jq 'length' 2>/dev/null); then
    echo "  4  could not read the deployment history for $short." >&2
    echo "     A rollback target has to be a build this estate served before, and" >&2
    echo "     that cannot be established right now. 4 blocks; it does not proceed." >&2
    exit 4
  fi
  if [ "${recs:-0}" -lt 1 ]; then
    echo "  refused: $short has no deployment record -- this estate has never served it." >&2
    echo "     --rollback returns production to a PRIOR STATE. A SHA with no" >&2
    echo "     deployment behind it is not a prior state; deploying it is a change" >&2
    echo "     deploy wearing a rollback's name, and it would skip every guard a" >&2
    echo "     change deploy passes." >&2
    exit 1
  fi
  echo "  ok   rollback to $short -- $recs deployment record(s), this estate has served it"
  exit 0
fi

# THE OPEN-PR TEST. `gh pr list` and not the search index: search is eventually
# consistent and a head pushed seconds ago can be missing from it, which would
# refuse a legitimate deploy for a reason nobody could reproduce.
if ! heads=$(gh pr list --repo "$repo" --state open --limit 200 \
               --json number,headRefOid -q '.[] | "\(.headRefOid) \(.number)"' 2>/dev/null); then
  echo "  4  could not list the open pull requests." >&2
  echo "     Production deploys from an open PR's head and that cannot be" >&2
  echo "     established right now. 4 blocks; it does not proceed." >&2
  exit 4
fi

pr=$(printf '%s\n' "$heads" | awk -v s="$sha" '$1==s {print $2; exit}')
if [ -n "$pr" ]; then
  echo "  ok   $short is the head of open PR #$pr"
  exit 0
fi

# The refusal. Say WHICH commit this is where we can, because "not an open PR
# head" sends somebody looking for a typo when the answer is "you typed main".
mainref="${MAIN_REF:-origin/main}"
mainsha=$(git rev-parse --verify "$mainref^{commit}" 2>/dev/null || echo '')
{
  if [ -n "$mainsha" ] && [ "$mainsha" = "$sha" ]; then
    echo "  refused: $short is ${mainref}'s HEAD, not an open PR's head."
    echo "     A deploy of main is a release of everything merged since the last"
    echo "     one, and the window, the UAT and the deployment record would all"
    echo "     name a single change while the build contains N."
  else
    echo "  refused: $short is not the head of any open pull request."
    echo "     It may already be merged, or be an older commit on a branch."
  fi
  cat <<'MSG'

     Production deploys from the BRANCH UNDER REVIEW. The merge is settlement,
     not authorization: production takes the change, converges, and trunk
     follows -- so at the moment of a production deploy the change is not yet
     on main. Deploying main means the change reached trunk before production
     saw it, which is the ordering gates/production-first.sh exists to prevent.

     If this is a rollback, say so:   --rollback
     itil:emergency does NOT bypass this. It bypasses the ordering guards (0
     and 1); this one is about what the build contains, and an emergency is
     still one change on one branch.
MSG
} >&2
exit 1
