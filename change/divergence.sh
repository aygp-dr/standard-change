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
#   pipeline  changes how you are VERIFIED or DEPLOYED, not what you ship
#   artifact  changes the DEPLOYABLE ENTITY itself
#   hotfix    an emergency change landed; you are provably missing it
#
# apps/** IS the deployable entity. In a container world the deployable is an
# image and apps/<x>/ maps to one; in this monorepo the directory is the
# closest honest approximation, so any change to apps/** on the deploy path is
# a blocker. targets/** is deliberately NOT artifact -- it is the deployment
# MECHANISM. Changing deploy.sh changes how a thing ships, not what ships, so
# it demands re-verification (pipeline) rather than a revert.
#
# This distinction was found by a live window: slot 1 forfeited on an
# `artifact` class driven entirely by targets/bastille/**, while the change
# under test shipped apps/pdp and nothing on main had touched apps/ at all.
# True by the letter, wrong in substance.
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
      # the deployable entity, and the config deployed alongside it
      apps/*|router/*)                        class=artifact ;;
      # how it is verified or shipped -- re-verify, but nothing is reverted
      targets/*|gates/*|change/*|.github/*|Makefile)
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
