#!/bin/sh
# queue.sh claim <pr>   -- guards 0 and 1. Exit 0 claim, 5 queue busy, 6 behind main.
set -eu
pr="$2"
repo="${GH_REPO:-$GITHUB_REPOSITORY}"

emergency=$(gh pr view "$pr" --repo "$repo" --json labels \
  -q '[.labels[].name] | index("change:emergency") // empty')

# Guard 0: up to date with main (standard and normal changes only)
if [ -z "$emergency" ]; then
  state=$(gh pr view "$pr" --repo "$repo" --json mergeStateStatus -q .mergeStateStatus)
  case "$state" in
    BEHIND|BLOCKED|DIRTY)
      gh pr edit "$pr" --repo "$repo" --remove-label deploy:staging
      gh pr comment "$pr" --repo "$repo" --body \
        "Staging refused: branch is \`$state\` relative to \`main\`. Rebase onto \`main\` and re-add \`deploy:staging\` — deploying a tree behind main would revert the previous deployment."
      exit 6 ;;
  esac
fi

# Guard 1: no other open PR holds staging
holder=$(gh pr list --repo "$repo" --state open --label deploy:staging \
  --json number -q "[.[].number] | map(select(. != $pr)) | first // empty")
if [ -n "$holder" ]; then
  gh pr edit "$pr" --repo "$repo" --add-label blocked:queue --remove-label deploy:staging
  gh pr comment "$pr" --repo "$repo" --body \
    "Staging is held by #$holder. Re-add \`deploy:staging\` once it merges; you will need to rebase onto \`main\` first."
  exit 5
fi

gh pr edit "$pr" --repo "$repo" --remove-label blocked:queue || true
echo "claimed"
