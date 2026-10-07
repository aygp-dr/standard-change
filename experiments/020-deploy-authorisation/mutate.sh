#!/bin/sh
# mutate.sh -- break the authorisation, and require demonstrate.sh to notice. (#32)
#
# "Mutate the thing the check is about and require the check to fail. A suite
# that has never rejected anything is one nobody has tested."
#   -- spec.org, The defect taxonomy, class 7
#
# This one guards the act of deploying to a protected environment, so a suite
# that cannot detect the guard being removed is worth less than nothing: it
# would report green over the exact hole #32 describes.
#
# A mutation may have several parts, separated by a ||AND|| line, so that
# "remove both of these" is one mutation. `covered-by` declares a mutation
# unreachable on its own and names what does kill it; an undeclared survivor
# still fails the run.
#
# RUN:  ./experiments/020-deploy-authorisation/mutate.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
here="$root/experiments/020-deploy-authorisation"
TARGETS="change/authorize.sh targets/node/deploy.sh targets/bastille/deploy.sh"
bakdir=$(mktemp -d "${TMPDIR:-/tmp}/authorig.XXXXXX")
for f in $TARGETS; do mkdir -p "$bakdir/$(dirname "$f")"; cp "$root/$f" "$bakdir/$f"; done
restore_all() { for f in $TARGETS; do cp "$bakdir/$f" "$root/$f"; done; }

survived=0; applied=0; expected=0

# The applier lives in a FILE. As `python3 - <<PY` with the spec also on stdin,
# the interpreter eats the spec, sys.stdin.read() returns "", and
# text.replace("", "", 1) is a silent no-op -- a mutation runner that mutates
# nothing and reports the suite as full of holes.
applier=$(mktemp "${TMPDIR:-/tmp}/mutate.XXXXXX")
cat > "$applier" <<'PY'
import sys, pathlib
path = pathlib.Path(sys.argv[1])
text = path.read_text()
for part in sys.stdin.read().split("\n||AND||\n"):
    old, sep, new = part.partition("\n||=>||\n")
    if not sep:
        sys.stderr.write("malformed mutation spec: no ||=>|| separator\n"); sys.exit(3)
    old, new = old.strip("\n"), new.strip("\n")
    if not old:
        sys.stderr.write("malformed mutation spec: empty search text\n"); sys.exit(3)
    if old not in text:
        sys.stderr.write("mutation did not apply: %r not found\n" % old[:70]); sys.exit(3)
    text = text.replace(old, new, 1)
path.write_text(text)
PY
cleanup() { restore_all; rm -rf "$bakdir"; rm -f "$applier"; }
trap cleanup EXIT INT TERM

run_mutation() { # run_mutation <id> <file> <description> [covered-by]
  _id="$1"; _file="$2"; _desc="$3"; _cov="${4:-}"
  restore_all
  python3 "$applier" "$root/$_file"
  applied=$((applied+1))
  set +e
  out=$("$here/demonstrate.sh" 2>&1); rc=$?
  set -e
  killed=$(printf '%s\n' "$out" | awk '/^  FAIL /{n++} END{print n+0}')
  ids=$(printf '%s\n' "$out" | awk '/^  FAIL /{printf "%s ", $2}')
  if [ "$killed" -eq 0 ] && [ -n "$_cov" ]; then
    printf '  survived* %-4s %s\n' "$_id" "$_desc"
    printf '            ^ expected: unreachable alone, killed by %s\n' "$_cov"
    expected=$((expected+1))
  elif [ "$killed" -eq 0 ]; then
    printf '  SURVIVED  %-4s %s\n' "$_id" "$_desc"
    printf '            ^ 0 assertions failed. The suite does not test this.\n'
    survived=$((survived+1))
  else
    printf '  killed %-2s %-4s %s\n' "$killed" "$_id" "$_desc"
    printf '            by %s(suite exit %s)\n' "$ids" "$rc"
  fi
}

echo "== mutating the authorisation and the two deploy targets"
echo ""

# P1. THE HOLE ITSELF, restored: the deploy target stops asking. This is
# targets/node/deploy.sh exactly as it was when 766a522 reached staging.
run_mutation P1 targets/node/deploy.sh "the node target stops calling authorize.sh" <<'MUT'
authorisation=$("$root/change/authorize.sh" "$env" "$short") || exit $?
||=>||
authorisation="unchecked"
MUT

# P2. The same for the jail target. Two callers is the point of one script.
run_mutation P2 targets/bastille/deploy.sh "the jail target stops calling authorize.sh" <<'MUT'
authorisation=$("$root/change/authorize.sh" "$env" "$sha") || exit $?
||=>||
authorisation="unchecked"
MUT

# P3. THE D16 MUTATION. The call is piped, so $? becomes sed's and every
# refusal is discarded while looking like it was honoured. This is the defect
# that put an unmerged build into production for ninety seconds, rebuilt in
# the script written to prevent it.
run_mutation P3 targets/node/deploy.sh "the authorisation is piped, discarding its verdict" <<'MUT'
authorisation=$("$root/change/authorize.sh" "$env" "$short") || exit $?
||=>||
authorisation=$("$root/change/authorize.sh" "$env" "$short" | sed 's/^/  /')
MUT

# P4. FAIL OPEN. An unreachable forge deploys anyway. The issue names this as
# the tempting wrong answer: it produces an authorised-LOOKING estate.
run_mutation P4 change/authorize.sh "unreachable forge proceeds instead of refusing" <<'MUT'
  exit 4
fi

pr=$(printf '%s' "$prs" | jq -r --arg s "$sha" \
||=>||
  echo "unauthorised: could not verify"
  exit 0
fi

pr=$(printf '%s' "$prs" | jq -r --arg s "$sha" \
MUT

# P5. A SHA that heads no open PR is waved through -- 766a522, again.
run_mutation P5 change/authorize.sh "no open PR at this SHA is allowed through" <<'MUT'
if [ -z "$pr" ]; then
||=>||
if [ -z "$pr" ] && false; then
MUT

# P6. preflight's verdict is read but not honoured, so the window, the freeze,
# the lock and the gates all become advisory again -- D9's "preflight's exit
# code is advice nobody receives", one layer in.
run_mutation P6 change/authorize.sh "preflight's exit code is ignored" <<'MUT'
if [ "$prc" -ne 0 ]; then
||=>||
if false; then
MUT

# P7. Every exit code from preflight is flattened to 1, so a freeze, a busy
# queue and "I could not check" all report as a plain refusal. 4 in particular
# stops being distinguishable, which is the collapse docs/exit-codes.org is
# written to prevent.
run_mutation P7 change/authorize.sh "preflight's exit codes are flattened to 1" <<'MUT'
  exit "$prc"
||=>||
  exit 1
MUT

# P8. An environment nobody classified is treated as a dev block. This is the
# assumption that created the issue, one level up.
run_mutation P8 change/authorize.sh "an unknown environment is assumed unprotected" <<'MUT'
    say "REFUSED: authorize.sh does not know whether '$env' is protected."
||=>||
    echo "unclassified: assumed open"
    exit 0
    say "REFUSED: authorize.sh does not know whether '$env' is protected."
MUT

# P9. The break glass stops being recorded: it still authorises, but the
# deployment record can no longer say the estate was deployed without checks.
# An override that leaves no trace is a bypass.
run_mutation P9 change/authorize.sh "break glass authorises without recording a reason" <<'MUT'
  echo "break-glass: $DEPLOY_BREAK_GLASS"
||=>||
  echo "ok"
MUT

# P10. The dev-block fast path is removed, so a dev block now needs the forge.
# Not a security hole -- the opposite -- but it would make every worktree
# depend on GitHub, and the suite should notice a change of that size.
run_mutation P10 change/authorize.sh "dev blocks are no longer exempt" <<'MUT'
  dev-[0-9])
    say "authorize: $env is a dev block -- unrestricted by design."
    echo "dev-block: no authorisation required"
    exit 0 ;;
||=>||
  dev-[0-9])                        penv=staging ;;
MUT

echo ""
echo "  $applied mutations applied, $((applied - survived - expected)) killed, $expected expected survivor(s), $survived unexplained"
if [ "$survived" -ne 0 ]; then
  echo "  a surviving mutation is a hole in the suite, not a passing run"
  exit 1
fi
