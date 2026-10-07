#!/bin/sh
# observation-test.sh -- can a measurement of build A authorize build B?
#
# Issue #16 in one sentence. #11's head moved 9d85a33 -> baed821, the labeller's
# withdrawal step did not fire, and `staging:e2e staging:smoke staging:uat` sat
# on the PR authorizing a build nobody had measured. Every part of the
# machinery was working as written; nothing in the suite could have noticed,
# because the only assertion about staleness was that a cleanup step existed.
#
# Two guards authorize on observations, and both had the hole:
#
#   change/guard4.sh            may this change reach production?
#   gates/production-first.sh   may this change reach main?
#
# Both are run here against recorded PR state, offline, with `gh` answered from
# gates/fixtures/gh.
#
#   ./gates/observation-test.sh            run both suites
#   ./gates/observation-test.sh --selftest run guard 4's cases against the guard
#                                          as it was BEFORE #16, and require the
#                                          stale-marker case to be AUTHORIZED
#
# --selftest is not decoration. A suite whose cases pass against the broken
# guard as well as the fixed one has established nothing (spec.org,
# Verification contract). The frozen pre-#16 guard is checked in beside the
# fixtures for exactly this, and the suite must be able to catch it.
set -eu
cd "$(dirname "$0")/.."
FX="$PWD/gates/fixtures/observations"
STUB="$PWD/gates/fixtures"

SELFTEST=0
[ "${1:-}" = "--selftest" ] && SELFTEST=1

# guard : case : expected
#   authorized  the guard says yes        refused  the guard says no
CASES="guard4:current:authorized
guard4:stale-marker:refused
guard4:no-record:refused
guard4:failed-rerun:refused
guard4:uat-withdrawn:refused
production-first:current:authorized
production-first:stale-marker:refused
production-first:no-record:refused
production-first:not-deployed:refused
production-first:nothing-deploys:authorized
production-first:unlabelled:refused
production-first:diff-unreachable:refused
production-first:label-only-surface:refused"

# THE TWO PRODUCTION-FIRST CASES ADDED FOR #29, and what each is for.
#
#   unlabelled        the PR the check actually sees. A required status check
#                     fires on `opened`; actions/labeler writes app:* about
#                     eight seconds later; and a label written by GITHUB_TOKEN
#                     cannot trigger the re-run that would correct the verdict.
#                     So the labels ARE absent at the only moment this gate ever
#                     runs, and reading them made it structurally incapable of
#                     blocking. The diff says apps/core, so it must refuse.
#
#   diff-unreachable  the fixture ships no diff.txt, so the stub `gh` exits 1 --
#                     "I could not determine", not "the diff is empty". The old
#                     `./change/groups.sh "$pr" 2>/dev/null || true` turned that
#                     into "deploys nothing" and passed. Unreachable is not
#                     falsified: it must refuse.
#
#   label-only-surface  the mirror of `unlabelled`, and the reason the guard
#                     takes the UNION rather than the diff alone. `labeler:skip`
#                     lets a human hand-set app:* to force a build across apps
#                     the diff does not touch (.github/labeler.yml), and that
#                     assertion is invisible in a diff. Diff-only derivation
#                     would read this PR as deploying nothing and wave it
#                     through.
#
# Both are mutation tests of the fix rather than of the pipeline: revert
# production-first.sh to the label-derived groups and `unlabelled` flips to
# authorized; put the `|| true` back and `diff-unreachable` flips with it.

script_for() {
  case "$1" in
    guard4)           echo "./change/guard4.sh" ;;
    production-first) echo "./gates/production-first.sh" ;;
  esac
}

show()    { FIXTURE="$FX/$1/$2" PATH="$STUB:$PATH" GH_REPO=o/r "$3" 42 2>&1 || true; }
verdict() { FIXTURE="$FX/$1/$2" PATH="$STUB:$PATH" GH_REPO=o/r "$3" 42 >/dev/null 2>&1 \
              && echo authorized || echo refused; }

fails=0
n=0

if [ "$SELFTEST" = 1 ]; then
  # Against the pre-#16 guard, assert only the thing that matters: the
  # stale-marker case must sail through. If it does not, the fixture is not
  # reproducing #16 and its pass against the current guard is worth nothing.
  old="$FX/guard4-before-16.sh"
  got=$(verdict guard4 stale-marker "$old")
  if [ "$got" = authorized ]; then
    echo "  ok    stale-marker   the pre-#16 guard AUTHORIZES a build measured on 9d85a33"
    echo "        so this suite can detect the defect; the current guard must refuse it"
    echo "  observation-test: the suite detects #16"
    exit 0
  fi
  echo "  FAIL  stale-marker   the pre-#16 guard refused it. This fixture does not"
  echo "        reproduce #16, so nothing here establishes that the fix fixed anything."
  exit 1
fi

for row in $CASES; do
  guard=${row%%:*}; rest=${row#*:}; case_=${rest%%:*}; want=${rest#*:}
  script=$(script_for "$guard")
  n=$((n + 1))
  got=$(verdict "$guard" "$case_" "$script")
  if [ "$got" = "$want" ]; then
    printf '  ok    %-16s %-16s %s\n' "$guard" "$case_" "$want"
  else
    printf '  FAIL  %-16s %-16s want %s, got %s\n' "$guard" "$case_" "$want" "$got"
    show "$guard" "$case_" "$script" | sed 's/^/          /'
    fails=$((fails + 1))
  fi
done

echo "  observation-test: $((n - fails))/$n cases, $fails failure(s)"
[ "$fails" = 0 ] || exit 1
