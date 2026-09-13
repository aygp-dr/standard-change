#!/bin/sh
# Run the gates here, and report the result to the forge. (gates/report.sh)
#
# WHY THIS EXISTS. Guard 2 asks "are the gates green on this head SHA?" and
# reads the forge. When GitHub stops scheduling jobs (issue #34) the answer is
# neither yes nor no -- nothing ran -- and preflight correctly returns 4,
# I COULD NOT CHECK. Every change then blocks, which is right and useless.
#
# The gates themselves do not need GitHub. They need a shell, node, python and
# an estate, all of which are here. So: run them here, and report the result
# where guard 2 looks.
#
# WHAT MAKES THIS NOT FORGERY. The gates ACTUALLY RUN, and every status is
# gated on the exit code of the command that produced it -- not on having
# invoked it. A status is written after a gate passes, never alongside. Three
# times today a status was asserted without checking the step it depended on,
# and each had to be withdrawn; the contexts here are set from `$?` and nothing
# else.
#
# WHAT MAKES IT HONEST. Every context is prefixed `local/`. It says, on the PR,
# that this was measured on a host and not by CI. Guard 2 may count it; a
# reader can always tell the difference; and when CI returns its contexts sit
# beside these rather than replacing them.
#
# The Checks API refuses a PAT -- "You must authenticate via a GitHub App" --
# so this uses the Statuses API, which GitHub folds into the same combined
# status that branch protection and guard 2 read.
set -eu
cd "$(dirname "$0")/.."
R="${GH_REPO:-${GITHUB_REPOSITORY:-aygp-dr/standard-change}}"
URL="${GATE_URL:-}"

# THE SUBJECT IS THE ARGUMENT, NOT THE TREE.
#
# This script used to read `git rev-parse HEAD` and ignore its argument
# entirely, so `report.sh 42` ran main's gates and posted the results onto
# main's SHA while printing a line that read as though it had gated #42. Guard
# 2 asks about the PR's head; a reporter that answers about the runner's
# checkout is the same defect as an e2e oracle taken from the runner's tree
# (PR #21) and as guard 5 passing on a SHA that does not exist.
#
# So: if a PR is named, its head SHA is resolved FROM THE FORGE, and the
# working tree must already BE that commit. This script does not check anything
# out -- moving the caller's tree under them is worse -- it refuses and says
# what to run. With no argument it reports on HEAD, which is what CI does.
SHA=$(git rev-parse HEAD)
if [ $# -gt 0 ]; then
  case "$1" in
    ''|*[!0-9]*) echo "usage: report.sh [pr-number]" >&2; exit 2 ;;
  esac
  want=$(gh pr view "$1" --repo "$R" --json headRefOid -q .headRefOid) \
    || { echo "refused: cannot resolve the head of #$1 from $R" >&2; exit 4; }
  if [ "$want" != "$SHA" ]; then
    echo "refused: #$1 is at ${want}" >&2
    echo "         this tree  is at ${SHA}" >&2
    echo "         a gate result is about a BUILD. Check out that commit and" >&2
    echo "         re-run, or run with no argument to report on this tree." >&2
    exit 3
  fi
  echo "subject: #$1, head $(echo "$SHA" | cut -c1-7) -- confirmed against $R"
fi

post() { # post <context> <state> <description>
  gh api "repos/$R/statuses/$SHA" -X POST -f state="$2" -f context="local/$1" \
    -f description="$3" ${URL:+-f target_url="$URL"} >/dev/null 2>&1 \
    || echo "   warn could not post local/$1 -- the gate result stands, the forge does not know it"
}

rc=0
run() { # run <context> <command...>
  ctx="$1"; shift
  printf '  %-16s ' "$ctx"
  if out=$("$@" 2>&1); then
    post "$ctx" success "passed on $(echo "$SHA" | cut -c1-7), run on $(hostname -s)"
    echo "pass"
  else
    post "$ctx" failure "FAILED on $(echo "$SHA" | cut -c1-7), run on $(hostname -s)"
    echo "FAIL"; echo "$out" | tail -5 | sed 's/^/      /'
    rc=1
  fi
}

echo "reporting gates for $(echo "$SHA" | cut -c1-7) to $R"

# gate-selftest FIRST and its result gates the rest: a suite that cannot prove
# it can fail produces no verdict that run, so reporting the others would be
# reporting nothing. The repo's central invariant, enforced in the reporter.
if ! gmake -s gate-selftest >/dev/null 2>&1; then
  post gate-selftest failure "the gates cannot prove they can fail; no verdict this run"
  echo "  gate-selftest    FAIL — no other result is reportable"
  exit 1
fi
post gate-selftest success "both directions confirmed on $(hostname -s)"
echo "  gate-selftest    pass"

run lint gmake -s lint
run test gmake -s test
[ -n "${ROUTER_URL:-}" ] && run e2e sh -c "ROUTER_URL=$ROUTER_URL ./gates/e2e.sh" || true

echo
[ "$rc" = 0 ] && echo "  all reported green" || echo "  REPORTED RED"
exit $rc
