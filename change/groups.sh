#!/bin/sh
# groups.sh <pr> -- the deploy groups this change touches, from its app:* labels.
#
# The labels are the source, not the diff: the labeller derives them from the
# diff once, in one place, and everything downstream reads the result. Deriving
# them a second time here would be a second implementation of the same rule,
# free to disagree with the first.
set -eu
pr="${1:?usage: groups.sh <pr>}"
repo="${GH_REPO:-${GITHUB_REPOSITORY:-aygp-dr/standard-change}}"
gh pr view "$pr" --repo "$repo" --json labels \
  -q '[.labels[].name | select(startswith("app:")) | ltrimstr("app:")] | sort | join(" ")'
