#!/bin/sh
# python-lint.sh -- lint the python half of the control plane with whatever is here.
#
# THE PYTHON IS NOT A SIDESHOW. gates/pbt-pipeline.py is the exhaustive model
# that `gate-selftest` leans on, gates/label-audit.py is the only thing that can
# see an undeclared label, and sim/ is the evidence behind every scheduling
# claim in spec.org. `gmake lint` covered 42 shell scripts and 4 node apps and
# said nothing about any of it.
#
# THE CASCADE, and why it is not four different gates wearing one name.
#
#   ruff        the whole of pyflakes, fast, and what is actually here
#   flake8      pyflakes plus pycodestyle
#   pyflakes    the floor: real defects, no style
#   py_compile  syntax only -- stdlib, so it is always available
#
# A cascade is a hazard: the verdict depends on which tool the host happened to
# have, so the same tree is green on one machine and red on another and neither
# run is wrong. That is two oracles for one question, which is the defect
# change/activate.sh and gates/preflight.sh spent a day being.
#
# So the RULE SET IS PINNED TO THE NARROWEST TIER, not to the best tool
# available. `--select F,E9` is exactly what pyflakes reports -- undefined
# names, unused imports and variables, shadowed imports, syntax errors -- so
# ruff and flake8 and pyflakes all answer the SAME question and only differ in
# how fast. Style is deliberately out: this repo has never agreed a python
# style, and a gate that invents one produces findings nobody acts on, which is
# the warning tier arriving by the back door.
#
# py_compile is the floor and it is honest about being one: it proves the files
# parse and nothing more. It says so in its own output rather than letting a
# pass read as the same pass the tiers above it give.
#
# Exit 0 clean, 1 findings, 4 nothing available at all (docs/exit-codes.org --
# which cannot happen while python3 runs this script, and is kept because the
# day it can is the day the floor moved).
set -eu
cd "$(dirname "$0")/.."

# The file set, declared. apps/ has no python today; the glob is here so that
# adding some does not silently leave it unlinted.
#
# idp-api/ IS NOT IN THIS SET and that is a gap, not a decision: idp-api/mock/
# is python this gate can read and does not. It is left out because widening
# the scope and adding the gate in one change means the finding it produces
# arrives as "the new linter is noisy" rather than as a defect. Recorded in
# docs/shell-review.org; the trigger to widen is the first idp-api defect that
# an F-class rule would have caught.
FILES=""
for f in gates/*.py sim/*.py apps/*/*.py apps/*/*/*.py; do
  [ -f "$f" ] && FILES="$FILES $f"
done
# The extensionless entry points are python3 too -- same shebang detection as
# gates/shellcheck.sh, same reason: a name is not a language.
for f in idp envs status dashboard deploy-run; do
  [ -f "$f" ] || continue
  case "$(head -1 "$f")" in '#!'*python*) FILES="$FILES $f" ;; esac
done
[ -n "$FILES" ] || { echo "  python: no sources to lint"; exit 0; }
NF=$(echo "$FILES" | wc -w | tr -d ' ')

# NAME THE TOOL THAT RAN, on every path. "python: 0 findings" from py_compile
# and from ruff are different claims about the same tree, and a reader who
# cannot tell which one they got has been handed a verdict with no instrument
# attached (spec.org, defect class 3: an instrument records its own result).
SEL=F,E9

if command -v ruff >/dev/null; then                  RUFF="ruff"
elif python3 -c 'import ruff' 2>/dev/null; then      RUFF="python3 -m ruff"
else                                                 RUFF=""
fi

if [ -n "$RUFF" ]; then
  # The VERSION is part of the instrument's name. Two ruff versions disagree
  # about what F-class means, so "ruff said nothing" without a version is a
  # verdict whose oracle cannot be identified later.
  # shellcheck disable=SC2086
  VER=$($RUFF --version 2>/dev/null | head -1); VER=${VER:-version-unknown}
  # shellcheck disable=SC2086  # $RUFF is a command plus its flags; the split is the point
  out=$($RUFF check --select "$SEL" --no-cache --output-format concise $FILES 2>&1) && rc=0 || rc=$?
  [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/  /'
  echo "  python: $NF files, $VER --select $SEL"
  [ "$rc" = 0 ] || exit 1
  exit 0
fi

if command -v flake8 >/dev/null; then
  out=$(flake8 --select=F,E9 $FILES 2>&1) && rc=0 || rc=$?
  [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/  /'
  echo "  python: $NF files, flake8 --select=F,E9"
  [ "$rc" = 0 ] || exit 1
  exit 0
fi

if command -v pyflakes >/dev/null || python3 -c 'import pyflakes' 2>/dev/null; then
  command -v pyflakes >/dev/null && PF="pyflakes" || PF="python3 -m pyflakes"
  # shellcheck disable=SC2086
  out=$($PF $FILES 2>&1) && rc=0 || rc=$?
  [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/  /'
  echo "  python: $NF files, pyflakes"
  [ "$rc" = 0 ] || exit 1
  exit 0
fi

# THE FLOOR, AND IT SAYS SO. py_compile proves the files parse. It does not
# know about an undefined name, an unused import or a shadowed one, so its
# silence is a much weaker claim than the tiers above and must not be printed in
# the same words as theirs.
echo "  python: no linter installed (ruff, flake8, pyflakes all absent)."
echo "          FALLING BACK TO python3 -m py_compile -- SYNTAX ONLY."
echo "          This does NOT check undefined names, unused imports or shadowing."
# shellcheck disable=SC2086
if python3 -m py_compile $FILES 2>&1 | sed 's/^/  /'; then
  echo "  python: $NF files parse. That is all that was established."
  exit 0
fi
exit 1
