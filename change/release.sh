#!/bin/sh
# release.sh <pr> -- merge (if auto-merge enabled) and free the queue.
set -eu
pr="$1"; repo="${GH_REPO:-$GITHUB_REPOSITORY}"

# Guard 4b, at the MERGE. Not redundant with the activation check: with more
# than one deployment in flight, two changes can both pass guard 4b (trunk has
# not moved yet) and then merge in sequence -- the first moves trunk, the
# second lands a tree predating it. Found in sim/ at berths=2. Activation is
# not the last point of reliance; the merge is.
emergency=$(gh pr view "$pr" --repo "$repo" --json labels \
  -q '[.labels[].name] | index("itil:emergency") // empty')
if [ -z "$emergency" ]; then
  state=$(gh pr view "$pr" --repo "$repo" --json mergeStateStatus -q .mergeStateStatus)
  if [ "$state" = "BEHIND" ] || [ "$state" = "DIRTY" ]; then
    base=$(gh pr view "$pr" --repo "$repo" --json baseRefOid -q .baseRefOid)
    class=$(./change/divergence.sh "$base" origin/main || true)
    case "$class" in
      artifact|hotfix)
        gh pr edit "$pr" --repo "$repo" --remove-label staging:passed \
                                        --remove-label deploy:production
        gh pr comment "$pr" --repo "$repo" --body \
          "Merge refused: \`main\` moved during your window and it was a \`$class\` change. Production is deployed but this tree predates what is now on main, so merging it would revert that. Rebase and re-run staging; the berth is held."
        exit 8 ;;
    esac
  fi
fi

if [ "${AUTO_MERGE:-1}" = "1" ]; then
  gh pr merge "$pr" --repo "$repo" --squash --delete-branch
else
  gh pr comment "$pr" --repo "$repo" --body "Production healthy. Ready to merge; the staging queue frees on merge."
fi
gh pr edit "$pr" --repo "$repo" \
  --remove-label deploy:staging --remove-label deploy:production \
  --remove-label staging:passed --remove-label production:healthy
./change/lock.sh release

# Announce ONCE, on the queue issue -- never fan out to every waiter.
#
# The previous version commented on each blocked:queue PR. At the several-
# hundred-PR scale that is one API call per waiter per release, and worse than
# the cost: the queue has no ordering, so telling everyone at once produces a
# thundering herd that all rebase and race for a berth exactly one of them can
# take. Announcing once turns the queue into something waiters read rather than
# something that pages them.
gh issue comment "${QUEUE_ISSUE:-1}" --repo "$repo" --body \
  "Staging freed by #$pr at $(date -u +%FT%TZ). Next claimant: rebase onto \`main\` first -- guard 0 will refuse a branch that is behind."
