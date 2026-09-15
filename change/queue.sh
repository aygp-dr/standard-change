#!/bin/sh
# queue.sh claim <pr>   -- guards 0 and 1. Exit 0 claim, 5 queue busy, 6 behind main.
set -eu
pr="$2"
repo="${GH_REPO:-$GITHUB_REPOSITORY}"

emergency=$(gh pr view "$pr" --repo "$repo" --json labels \
  -q '[.labels[].name] | index("itil:emergency") // empty')

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
  # THE LOCK IS deploy:staging, AND A REFUSAL RESETS THE CHANGE. Decided
  # 2026-09-14: a change that asks for staging while another holds it keeps
  # NO marker -- not the window, not the lifecycle, not the observations, and
  # not the human intent. blocked:queue used to be left behind as the trace of
  # this refusal, and a label left behind is a print statement that later
  # reads as a claim (spec.org, "the labels are print statements"). The person
  # re-states the intent when the lock is free; the comment below is the
  # record of why they have to. Rule LockResets in tla/Labels.tla.
  ./change/schedule.sh unschedule "$pr" "refused at the lock: staging held by #$holder" >/dev/null 2>&1 || true
  for l in deploy:staging blocked:queue change:scheduled change:requested change:start release \
           staging:hold staging:deployed staging:healthy staging:e2e staging:e2e-failed \
           staging:smoke staging:smoke-failed staging:uat staging:in-progress; do
    gh pr edit "$pr" --repo "$repo" --remove-label "$l" >/dev/null 2>&1 || true
  done
  gh pr comment "$pr" --repo "$repo" --body \
    "Refused at the lock: staging is held by #$holder. Every marker on this change has been cleared -- its window, its lifecycle, its observations and the intent that asked for it -- so that nothing here reads as a claim while it waits. When #$holder settles or its window lapses, say \`change:start\` again (rebase onto \`main\` first if it moved)."
  exit 5
fi

gh pr edit "$pr" --repo "$repo" --remove-label blocked:queue || true
echo "claimed"
