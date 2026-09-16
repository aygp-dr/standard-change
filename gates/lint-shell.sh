#!/bin/sh
# lint-shell.sh -- the three questions asked of the shell control plane.
#
#   gates/shellcheck.sh   is it correct
#   gates/shebang.sh      does it name its interpreter the agreed way
#   gates/shfmt.sh        is it shaped like the rest of the tree
#
# Each can fail on a file the other two pass, so all three run and the worst
# code survives -- an early refusal must not hide a later one, because the run
# that hides it is the run where somebody stops looking.
#
# WHY THIS IS A SCRIPT AND NOT THREE LINES OF MAKEFILE. `make` reports every
# recipe failure as its own "Error 1" and exits 2, so an exit code a recipe
# produces cannot be read by a recipe that invoked it. That is fine for
# pass/fail and fatal here: exit 4 means "I could not check" and is the one
# code this gate exists to carry intact (docs/exit-codes.org). Put the logic in
# a script and both `gmake lint-shell` and `gmake lint` get the real number.
#
# Exit 0 clean, 1 findings, 4 a checker was not installed and its surface was
# NOT examined.
set -eu
cd "$(dirname "$0")/.."

rc=0

# The correctness check runs FIRST, and the order is consequence rather than
# cost: a parse error in change/ or gates/ makes every later verdict a verdict
# from scripts that do not run.
#
# (No comment line here may BEGIN with the checker's own name -- a comment of
# that shape is read as a directive and fails to parse. Writing this file is
# the third time that has been demonstrated; the first two are recorded in
# gates/shellcheck.sh's own header, which is where I read about it before
# doing it anyway.)
./gates/shellcheck.sh || rc=1
./gates/shebang.sh || rc=1

# 4 is carried, never rounded. `[ $rc = 0 ]` guards it so a real finding
# (1) always outranks "I could not check" (4) -- there is something to fix
# either way, and the actionable one is the one to report.
./gates/shfmt.sh && s=0 || s=$?
case "$s" in
  0) ;;
  4) [ "$rc" = 0 ] && rc=4 || true ;;
  *) rc=1 ;;
esac

exit "$rc"
