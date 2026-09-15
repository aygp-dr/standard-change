#!/bin/sh
# shfmt.sh -- the shell scripts are formatted the one way, reported not rewritten.
#
# COMPANION TO shellcheck.sh, NOT A SECOND OPINION ON IT. shellcheck answers
# "is this correct"; this answers "is this shaped like the rest of the tree".
# They share a file set on purpose -- a formatter that covers a different set of
# scripts than the checker is a second inventory of the control plane, free to
# disagree with the first.
#
# -d, NEVER -w. This is a gate and a gate reports; it does not edit the thing it
# is judging. A formatter that rewrites on the way past turns "the tree was
# already right" and "the tree has been made right" into the same exit code,
# which is the same defect as a deploy step reporting success for a deploy it
# did not perform.
#
# THE FLAGS ARE THE TREE'S STYLE, READ OFF THE TREE:
#   -ln posix   these are #!/bin/sh scripts (gates/shebang.sh enforces that)
#   -i 2        two-space indent, which is what every script here uses
#   -ci         `case` arms indented inside the case, as in change/lock.sh:39
#
# EXIT 4 WHEN shfmt IS NOT INSTALLED, and 4 is not 0. docs/exit-codes.org:
# "4 = I could not check", and "4 blocks". A linter that is absent must not
# report what a linter that found nothing reports -- that collapse is the same
# unreachable-is-not-falsified defect the whole repo is built to refuse, and it
# is worse here than elsewhere because the absent case is the SILENT one: the
# tool is missing on exactly the host where nobody is looking.
#
# shfmt is not in FreeBSD base and is not installed on hydra today
# (`pkg install shfmt`, or `go install mvdan.cc/sh/v3/cmd/shfmt@latest`).
# Until it is, this gate returns 4 and says so, every run.
set -eu
cd "$(dirname "$0")/.."

command -v shfmt >/dev/null || {
  echo "  shfmt: NOT INSTALLED -- this surface was NOT checked (pkg install shfmt)"
  echo "         exit 4: 'I could not check' is not 'it passed' (docs/exit-codes.org)"
  exit 4
}

# DETECT BY SHEBANG, the same way and for the same reason as shellcheck.sh: the
# extensionless entry points `status` and `dashboard` are python3, and handing
# them to a shell formatter produces a diff with no relationship to the code.
# The globs are shellcheck.sh's, character for character, INCLUDING the gap:
# router/generate.sh, adopt/generate.sh, tla/check.sh and three experiment
# scripts are tracked shell and are in neither set. Widening it here alone would
# give the two gates different inventories of the control plane, which is the
# thing this comment is trying to prevent. The gap is recorded in
# docs/shell-review.org and is one change, not this one.
FILES=""
for f in gates/*.sh change/*.sh targets/*/*.sh targets/*/*/*.sh \
         idp envs status dashboard deploy-run; do
  [ -f "$f" ] || continue
  case "$(head -1 "$f")" in
    '#!/bin/sh') FILES="$FILES $f" ;;
    *) ;;
  esac
done

rc=0; n=0
for f in $FILES; do
  out=$(shfmt -ln posix -i 2 -ci -d "$f" 2>&1 || true)
  if [ -n "$out" ]; then
    printf '%s\n' "$out" | sed 's/^/  /'
    n=$((n + 1))
    rc=1
  fi
done
echo "  shfmt: $(echo "$FILES" | wc -w | tr -d ' ') scripts, $n unformatted"
exit $rc
