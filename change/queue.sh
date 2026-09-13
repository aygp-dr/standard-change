#!/bin/sh
# queue.sh claim <pr>   -- guards 0 and 1. Exit 0 claim, 5 queue busy, 6 behind main.
set -eu
pr="$2"
repo="${GH_REPO:-$GITHUB_REPOSITORY}"

emergency=$(gh pr view "$pr" --repo "$repo" --json labels \
  -q '[.labels[].name] | index("change:emergency") // empty')

# Guard 0: up to date with main (standard and normal changes only).
#
# CLASSIFIED, like guard 4b -- but at a different threshold, and the difference
# is the point:
#   guard 4b blocks on artifact|hotfix   -- your tree would REVERT what shipped
#   guard 0  blocks on pipeline and above -- that, PLUS: main changed how you
#            are verified, so your branch would pass under the old gates
#   inert    blocks neither               -- docs cannot affect either
#
# Before this, guard 0 blocked on ANY divergence, so a docs merge forced every
# open branch to rebase for nothing. Found by enabling Dependabot: weekly
# control-plane bumps would churn every branch, and it was worth asking which
# of that churn was earned.
if [ -z "$emergency" ]; then
  state=$(gh pr view "$pr" --repo "$repo" --json mergeStateStatus -q .mergeStateStatus)
  if [ "$state" = "BEHIND" ]; then
    base=$(gh pr view "$pr" --repo "$repo" --json baseRefOid -q .baseRefOid)
    class=$(./change/divergence.sh "$base" origin/main 2>/dev/null || echo artifact)
    if [ "$class" = "inert" ]; then
      gh pr comment "$pr" --repo "$repo" --body \
        "Behind \`main\`, but only by an \`inert\` change (docs or notes). Nothing you ship or are verified by has moved, so the berth is granted without a rebase."
      state=CLEAN
    else
      gh pr comment "$pr" --repo "$repo" --body \
        "Staging refused: \`main\` moved by a \`$class\` change. $( [ "$class" = pipeline ] && echo "Your branch would be verified by the OLD gates." || echo "Deploying this tree would revert what shipped." ) Rebase onto \`main\` and re-request."
    fi
  fi
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
