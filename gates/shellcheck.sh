#!/bin/sh
# Lint every shell gate and change script. (gates/shellcheck.sh)
#
# NOTE: no comment line here may begin with the tool's own name, because a
# comment of that shape is read as a DIRECTIVE and fails to parse. This file
# linting itself is how that surfaced -- twice, since the note explaining it
# was written in the very shape it warns about.
#
# Exit 0 clean, 1 findings, 2 shellcheck not installed. Same contract as every
# other gate (docs/exit-codes.org).
#
# -S warning, not -S style. The repo's rule is ZERO FINDINGS OR THE GATE FAILED
# -- a gate with a warning tier is a gate that gets ignored -- so the threshold
# is set where every finding is worth acting on and none are advisory.
#
# It found two real defects on its first run:
#   change/state.sh  \> for lexicographic comparison of ISO timestamps, which is
#                    UNDEFINED in POSIX sh (SC3012). In the BERTH HOLD, which
#                    decides whether somebody else still owns the path to
#                    production.
#   change/ports.sh  $p referenced where it was never assigned (SC2154).
set -eu
cd "$(dirname "$0")/.."
command -v shellcheck >/dev/null || { echo "  shellcheck not installed (pkg install shellcheck)"; exit 2; }

# DETECT BY SHEBANG, not by name. The first version listed `status` and
# `dashboard` as shell because they are extensionless entry points -- they are
# python3, and shellcheck reported 12 parse errors that said nothing about
# either script. A linter that lints the wrong language produces findings with
# no relationship to the code, which is worse than no linter: it trains you to
# skim.
FILES=""
for f in gates/*.sh change/*.sh targets/*/*.sh targets/*/*/*.sh \
         idp envs status dashboard deploy-run; do
  [ -f "$f" ] || continue
  case "$(head -1 "$f")" in
    '#!'*sh|'#!'*"/sh "*|'#!'*bash*|'#!/bin/sh'*) FILES="$FILES $f" ;;
    *) case "$f" in *.sh) FILES="$FILES $f" ;; esac ;;
  esac
done

rc=0; n=0
for f in $FILES; do
  [ -f "$f" ] || continue
  # SC2178/SC2128 are excluded globally, with the reason here rather than as a
  # directive repeated in five files: several scripts use `set -- $(f)` to take
  # positional parameters from a function that prints fields, and the checker
  # reads a later plain assignment to an unrelated variable as an array being
  # flattened. Every instance was inspected and none was a defect.
  out=$(shellcheck -s sh -S warning -e SC2178,SC2128 -f gcc "$f" 2>/dev/null || true)
  if [ -n "$out" ]; then
    echo "$out" | sed 's/^/  /'
    n=$((n + $(echo "$out" | grep -c .)))
    rc=1
  fi
done
echo "  shellcheck: $(echo "$FILES" | wc -w | tr -d ' ') scripts, $n finding(s)"
exit $rc
