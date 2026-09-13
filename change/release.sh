#!/bin/sh
# release.sh <pr> -- merge (if auto-merge enabled) and free the queue.
set -eu
pr="$1"; repo="${GH_REPO:-$GITHUB_REPOSITORY}"
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
