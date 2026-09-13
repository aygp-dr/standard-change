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
  -q '[.labels[].name] | index("change:emergency") // empty')
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
# Tell everyone waiting that they are now behind main and must rebase.
for w in $(gh pr list --repo "$repo" --state open --label blocked:queue --json number -q '.[].number'); do
  gh pr comment "$w" --repo "$repo" --body "Staging freed by #$pr. Rebase onto \`main\`, then add \`deploy:staging\`."
done
