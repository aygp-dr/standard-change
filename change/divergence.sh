#!/bin/sh
# divergence.sh <base-sha> [head-sha] -- classify what landed on main under you.
#
# Guard 4b must not treat every merge alike. "You are behind main" and "you are
# about to ship an image missing a hotfix" are different facts with different
# costs, and collapsing them either over-blocks (a README merge forces a full
# re-verify) or under-blocks (a hotfix merge does not).
#
# Classes, lowest to highest. The highest class present wins.
#   inert     nothing that can appear in a deployed artifact
#   pipeline  changes how you would be verified, not what you would ship
#   artifact  changes the image you would deploy
#   hotfix    an emergency change landed; you are provably missing it
#
# Exit: 0 inert, 1 pipeline, 2 artifact, 3 hotfix.
set -eu
base="$1"; head="${2:-origin/main}"

paths=$(git diff --name-only "$base".."$head")
[ -n "$paths" ] && class=inert || { echo "inert"; exit 0; }

# Was any merged commit from an emergency change? The trailer is written by
# release.sh; the label is gone from the PR by the time we look.
if git log --format='%B' "$base".."$head" | grep -q '^Change-Type: emergency'; then
  class=hotfix
else
  for p in $paths; do
    case "$p" in
      apps/*|router/*|targets/*)              class=artifact ;;
      gates/*|change/*|.github/*|Makefile)
        [ "$class" = artifact ] || class=pipeline ;;
      *) : ;;   # docs, .meta, scenarios, experiments, tla, README -- inert
    esac
  done
fi

echo "$class"
case "$class" in
  inert)    exit 0 ;;
  pipeline) exit 1 ;;
  artifact) exit 2 ;;
  hotfix)   exit 3 ;;
esac
