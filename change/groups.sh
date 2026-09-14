#!/bin/sh
# groups.sh [--diff|--union] <pr> -- the deploy groups this change touches.
#
#   (default)  from the app:* LABELS. What the labeller decided, which is what
#              every downstream actor reads once a PR has settled down.
#   --diff     from the DIFF, through the labeller's own oracle.
#   --union    both. What a GUARD must use.
#
# WHY THERE ARE THREE AND NOT ONE.
#
# The labels are the right source for anything that runs after the labeller: it
# derives them from the diff once, in one place, and a second derivation is free
# to disagree with the first. That is why this script read labels and nothing
# else, and for the queue, the scheduler and the deployer it still does.
#
# It is the WRONG source for a check that runs on `opened`. Issue #29: on #28
# gates/production-first.sh ran at 17:03:50 and actions/labeler wrote app:core
# at 17:03:58, so the gate evaluated in the only window where the labels are
# guaranteed absent, printed "no app:* labels -- nothing deploys", and passed.
# It never corrected itself, because a label written by GITHUB_TOKEN does not
# trigger a workflow run -- GitHub's loop-prevention rule -- so the `labeled`
# type in the workflow's trigger list has never once fired. A required check
# that is structurally incapable of blocking is decoration.
#
# --union RATHER THAN --diff, because the two sources answer different
# questions and neither subsumes the other:
#
#   the diff   says what this change TOUCHES. Available immediately, and the
#              only thing available before the labeller runs.
#   the labels say what somebody DECLARED it deploys. `labeler:skip` exists so
#              a human can force a build across apps the diff does not touch
#              (.github/labeler.yml), and that assertion is invisible in a diff.
#
# A guard wants every group either source names, because more deployable
# surface means more to wait on, and the union is the fail-CLOSED direction.
# Taking the diff alone would silently drop a hand-set app:* label; taking the
# labels alone is issue #29.
#
# UNREACHABLE IS NOT EMPTY. Every path here fails loudly if `gh` cannot answer.
# An empty result from this script means "this change deploys nothing", which a
# guard reads as "nothing to wait for" and authorizes. Turning a failed API call
# into that answer is the repo's first defect class wearing a success exit code,
# so there is no `|| true` anywhere below and callers must not add one.
set -eu
cd "$(dirname "$0")/.."
mode='labels'
case "${1:-}" in
  --diff)  mode='diff';  shift ;;
  --union) mode='union'; shift ;;
  --*)     echo "usage: groups.sh [--diff|--union] <pr>" >&2; exit 2 ;;
esac
pr="${1:?usage: groups.sh [--diff|--union] <pr>}"
repo="${GH_REPO:-${GITHUB_REPOSITORY:-aygp-dr/standard-change}}"

from_labels() {
  gh pr view "$pr" --repo "$repo" --json labels \
    -q '[.labels[].name | select(startswith("app:")) | ltrimstr("app:")] | .[]'
}

# The glob rule lives in .github/labeler.yml and is read by exactly one piece of
# code -- gates/labeller-test.py, the labeller's oracle, whose SCENARIOS are the
# regression suite for that file. Re-implementing "apps/<x>/** plus shared/**"
# in shell here would be the second reader this header warns about.
from_diff() {
  files=$(gh pr diff "$pr" --repo "$repo" --name-only)
  printf '%s\n' "$files" | python3 ./gates/labeller-test.py --groups
}

# ONE ASSIGNMENT PER SOURCE. `out=$(printf '%s\n%s\n' "$(a)" "$(b)")` reads
# fine and is wrong: `set -e` does not propagate out of a command substitution
# nested inside another one's arguments, so a `gh pr diff` that FAILED
# contributed an empty string and this script exited 0 with half an answer.
# Measured, not reasoned about: against a fixture whose diff cannot be read,
# that form printed `plp` and exited 0. The union of a known set and an unknown
# one is unknown, and it has to refuse.
case "$mode" in
  labels) out=$(from_labels) ;;
  diff)   out=$(from_diff) ;;
  union)  a=$(from_labels)
          b=$(from_diff)
          out=$(printf '%s\n%s\n' "$a" "$b") ;;
esac

# Formatting AFTER the verdict is in hand, never in the expression that produces
# it (spec.org, The defect taxonomy #6). Each `out=$(...)` above is the whole
# command, so `set -e` sees gh's status; sorting here cannot launder it.
printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//'
echo
