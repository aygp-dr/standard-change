#!/bin/sh
# mutate.sh -- break guard 5's fix, and require demonstrate.sh to notice. (#24)
#
# "Mutate the thing the check is about and require the check to fail. A suite
# that has never rejected anything is one nobody has tested."
#   -- spec.org, The defect taxonomy, class 7
#
# Guard 5 is the guard with no bypass, ever, and its label is the only evidence
# the forge gets that production converged. Its defect was that it could PASS
# without sampling anything. A suite for that fix which cannot detect the fix
# being removed is worth nothing.
#
# Each mutation is a defect somebody could plausibly write. A mutation that
# kills 0 assertions is a hole in the suite and is reported as SURVIVED.
#
# Specs are fed on stdin: text to find, a line reading `||=>||`, replacement.
#
# RUN:  ./experiments/019-guard5-cwd/mutate.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
here="$root/experiments/019-guard5-cwd"
TARGETS="gates/health.sh"
bakdir=$(mktemp -d "${TMPDIR:-/tmp}/g5orig.XXXXXX")
for f in $TARGETS; do mkdir -p "$bakdir/$(dirname "$f")"; cp "$root/$f" "$bakdir/$f"; done
restore_all() { for f in $TARGETS; do cp "$bakdir/$f" "$root/$f"; done; }

survived=0; applied=0; expected=0

# The applier lives in a FILE. Running it as `python3 - <<PY` while the spec
# is also on stdin makes the interpreter eat the spec, sys.stdin.read() return
# "", and text.replace("", "", 1) a no-op -- every mutation "applies", nothing
# changes, and the report reads as a suite full of holes.
applier=$(mktemp "${TMPDIR:-/tmp}/mutate.XXXXXX")
cat > "$applier" <<'PY'
import sys, pathlib
path = pathlib.Path(sys.argv[1])
text = path.read_text()
# A mutation may have several parts, separated by a ||AND|| line, so that
# "remove BOTH of these guards" is one mutation rather than two. Every part
# must apply; a part that does not match is a hard error, never a skip.
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

# run_mutation <id> <file> <description> [covered-by]
#
# `covered-by` declares this mutation UNREACHABLE ON ITS OWN and names the
# mutation that does kill it. It is the only way a survivor is not a failure,
# and it costs a name: an expected survivor with nothing covering it is still
# a hole. Without this the choice is to hide a known-redundant guard or to
# delete defence in depth because the suite cannot see it.
run_mutation() {
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

echo "== mutating gates/health.sh"
echo ""

# N1. THE ORIGINAL DEFECT, restored exactly: the route table comes from the
# caller's cwd again. Everything else about the fix stays.
run_mutation N1 gates/health.sh "route table read from the caller's cwd again" <<'MUT'
ROUTES="$root/router/routes.json"
||=>||
ROUTES="router/routes.json"
MUT

# N2. The refusal becomes a pass. This is the vacuous-pass bug with the
# diagnosis left in: it knows it cannot check, and returns 0 anyway.
run_mutation N2 gates/health.sh "refuse() exits 0 instead of 4" <<'MUT'
  exit 4
}
||=>||
  exit 0
}
MUT

# N3. The guards on the route table are dropped, so an unreadable or empty
# table falls through to the loop -- which iterates nothing and exits 0.
run_mutation N3 gates/health.sh "stop validating the route table before probing" <<'MUT'
[ -f "$ROUTES" ] || refuse "no route table at $ROUTES"
apps=$(jq -r '.[].app' "$ROUTES" 2>/dev/null) \
  || refuse "$ROUTES is not a readable route table"
[ -n "$apps" ] || refuse "$ROUTES declares no apps; there is nothing to converge"
||=>||
apps=$(jq -r '.[].app' "$ROUTES" 2>/dev/null || true)
MUT

# N4. The backstop on the sample count goes. EXPECTED TO SURVIVE ALONE: with
# the route-table validation still in place, `probed` can only be 0 on a path
# that has already refused, so nothing observable changes. That is not a hole
# in the suite, it is what defence in depth looks like from a mutation runner,
# and N7 is the mutation that kills it. Declared rather than discovered.
run_mutation N4 gates/health.sh "drop the zero-apps-probed backstop" N7 <<'MUT'
[ "$probed" -gt 0 ] || refuse "zero apps were probed"
||=>||
MUT

# N5. An app with no health path is probed anyway: jq yields the STRING
# "null", $base/null 404s, and a defect in the route table is reported as an
# unhealthy estate.
run_mutation N5 gates/health.sh "probe apps that declare no health path" <<'MUT'
  [ -n "$path" ] && [ "$path" != null ] \
    || refuse "app '$app' declares no health path in $ROUTES"
||=>||
MUT

# N6. The run stops naming the route table it used, so a verdict again cannot
# say which oracle produced it.
run_mutation N6 gates/health.sh "stop naming the route table in the output" <<'MUT'
echo "guard 5: $(printf '%s\n' "$apps" | grep -c .) apps from $ROUTES, $samples samples each"
||=>||
MUT

# N7. BOTH backstops at once. N4 alone cannot be killed: with the route-table
# validation in place, `probed` can only be 0 on a path that has already
# refused, so the backstop is unreachable by construction and no assertion can
# distinguish its presence. That is worth knowing rather than hiding -- it is
# defence in depth, and the honest way to show it is to remove both and watch
# the original exit-0 vacuous pass come back.
run_mutation N7 gates/health.sh "remove BOTH the validation and the backstop" <<'MUT'
[ -f "$ROUTES" ] || refuse "no route table at $ROUTES"
apps=$(jq -r '.[].app' "$ROUTES" 2>/dev/null) \
  || refuse "$ROUTES is not a readable route table"
[ -n "$apps" ] || refuse "$ROUTES declares no apps; there is nothing to converge"
||=>||
apps=$(jq -r '.[].app' "$ROUTES" 2>/dev/null || true)
||AND||
[ "$probed" -gt 0 ] || refuse "zero apps were probed"
||=>||
MUT

echo ""
echo "  $applied mutations applied, $((applied - survived - expected)) killed, $expected expected survivor(s), $survived unexplained"
if [ "$survived" -ne 0 ]; then
  echo "  a surviving mutation is a hole in the suite, not a passing run"
  exit 1
fi
