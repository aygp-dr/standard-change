#!/bin/sh
# mutate.sh -- break the oracle, and require demonstrate.sh to notice. (#14)
#
# "Mutate the thing the check is about and require the check to fail. A suite
# that has never rejected anything is one nobody has tested."
#   -- spec.org, The defect taxonomy, class 7
#
# Three tests in this repository passed while asserting nothing, and all three
# were found this way rather than by reading. gates/oracle.sh decides the one
# variable that decided the verdict in #14, so a suite that cannot detect its
# removal is not evidence that #14 is fixed.
#
# Each mutation below is a defect somebody could plausibly write -- a dropped
# shape check, a fallback that no longer refuses, a comparison that always
# says yes -- not a syntax error. A mutation that kills 0 assertions is
# reported as SURVIVED and is a hole in the suite.
#
# Each mutation is fed on stdin as: the text to find, a line reading `||=>||`,
# then the text to put in its place. A mutation that does not apply is a hard
# error, not a pass -- a mutation runner that silently skips is itself a check
# that cannot fail.
#
# RUN:  ./experiments/017-e2e-oracle/mutate.sh
# Exit 0 if every mutation is caught, 1 if any survives.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
here="$root/experiments/017-e2e-oracle"
# Three files carry the fix and all three are mutated: the oracle that decides
# where expectations come from, the router that publishes them, and the linter
# that keeps an app from claiming the path they are published on.
TARGETS="gates/oracle.sh router/server.js gates/lint-app.mjs"
bakdir=$(mktemp -d "${TMPDIR:-/tmp}/mutorig.XXXXXX")
for f in $TARGETS; do mkdir -p "$bakdir/$(dirname "$f")"; cp "$root/$f" "$bakdir/$f"; done
restore() { for f in $TARGETS; do cp "$bakdir/$f" "$root/$f"; done; rm -rf "$bakdir"; }
trap restore EXIT INT TERM

survived=0
applied=0

# The applier lives in a FILE, not in a `python3 - <<PY` heredoc. With the
# program on stdin the interpreter consumes it, sys.stdin.read() then returns
# "" -- and "" is in every string, so `text.replace("", "", 1)` applied a
# no-op, every mutation SURVIVED, and the run looked like a suite with five
# holes in it. A mutation runner that silently mutates nothing is the same
# defect class it exists to find, which is the taxonomy being recursive again.
applier=$(mktemp "${TMPDIR:-/tmp}/mutate.XXXXXX")
cat > "$applier" <<'PY'
import sys, pathlib
path = pathlib.Path(sys.argv[1])
spec = sys.stdin.read()
old, sep, new = spec.partition("\n||=>||\n")
if not sep:
    sys.stderr.write("malformed mutation spec: no ||=>|| separator\n"); sys.exit(3)
old, new = old.strip("\n"), new.strip("\n")
if not old:
    sys.stderr.write("malformed mutation spec: empty search text\n"); sys.exit(3)
text = path.read_text()
if old not in text:
    sys.stderr.write("mutation did not apply: %r not found\n" % old[:70]); sys.exit(3)
path.write_text(text.replace(old, new, 1))
PY
restore_all() { for f in $TARGETS; do cp "$bakdir/$f" "$root/$f"; done; }
cleanup() { restore; rm -f "$applier"; }
trap cleanup EXIT INT TERM

run_mutation() { # run_mutation <id> <file> <description>  (spec on stdin)
  _id="$1"; _file="$2"; _desc="$3"
  restore_all
  python3 "$applier" "$root/$_file"
  applied=$((applied+1))
  set +e
  out=$("$here/demonstrate.sh" 2>&1); rc=$?
  set -e
  killed=$(printf '%s\n' "$out" | awk '/^  FAIL /{n++} END{print n+0}')
  ids=$(printf '%s\n' "$out" | awk '/^  FAIL /{printf "%s ", $2}')
  if [ "$killed" -eq 0 ]; then
    printf '  SURVIVED  %-4s %s\n' "$_id" "$_desc"
    printf '            ^ 0 assertions failed. The suite does not test this.\n'
    survived=$((survived+1))
  else
    printf '  killed %-2s %-4s %s\n' "$killed" "$_id" "$_desc"
    printf '            by %s(suite exit %s)\n' "$ids" "$rc"
  fi
}

echo "== mutating the three files that carry the fix"
echo ""

# M1. The manifest is never consulted: the oracle is always this tree. This is
# the pre-#14 behaviour exactly, and is the mutation that must not survive.
run_mutation M1 gates/oracle.sh "never ask the estate; always use this tree" <<'MUT'
  _m=$(curl -s --max-time 5 "$_base$ORACLE_MANIFEST_PATH" 2>/dev/null || true)
||=>||
  _m=""
MUT

# M2. The refusal becomes a fallback. The gate would then test a build it
# cannot identify against whatever contract it happens to be holding -- the
# defect restored, in the direction that passes rather than fails.
run_mutation M2 gates/oracle.sh "refuse -> silently fall back to the tree" <<'MUT'
  rm -f "$ORACLE"; ORACLE=''
||=>||
  ORACLE_FROM=tree; ORACLE_SHA="${_dep:--}"; ORACLE_WHY="fallback"; return 0
MUT

# M3. The sha comparison always agrees, so "the tree IS the build" is asserted
# rather than established. Class 3: observation is not intent.
run_mutation M3 gates/oracle.sh "oracle_same_sha always returns true" <<'MUT'
oracle_same_sha() {
  case "$1" in "$2"*) return 0 ;; esac
||=>||
oracle_same_sha() {
  return 0
MUT

# M4. Shape check weakened to "some JSON with a routes key", which is exactly
# what core's 404 body is: an 8-app oracle out of a 5-app estate.
run_mutation M4 gates/oracle.sh "accept any JSON carrying a routes key as the manifest" <<'MUT'
        (.served_by? == "router")
        and (.routes | type == "array" and length > 0
             and all(.[]; type == "object" and has("app") and (.routes | type == "array")))
||=>||
        has("routes")
MUT

# M5. The forced oracle stops announcing that it was forced, so gates/e2e.sh
# can no longer tell a caller-supplied oracle from an established one and will
# record a verdict for one.
run_mutation M5 gates/oracle.sh "ORACLE_MODE=tree reports itself as a normal tree oracle" <<'MUT'
    ORACLE_FROM=tree-forced
||=>||
    ORACLE_FROM=tree
MUT

# M6. The router stops declaring who answered. oracle.sh's shape check keys on
# served_by=="router", so a manifest without it is indistinguishable from an
# app's 404 body and every run falls through to the tree -- the whole fix,
# disabled from the other end, with nothing in gates/ changed.
run_mutation M6 router/server.js "router omits served_by from its manifest" <<'MUT'
    const body = JSON.stringify({ sha: SHA, block: BLOCK, base_port: BASE,
                                  served_by: 'router', routes: apps }, null, 2);
||=>||
    const body = JSON.stringify({ sha: SHA, block: BLOCK, base_port: BASE,
                                  routes: apps }, null, 2);
MUT

# M7. The reservation of /__ is dropped. An app may then claim the path the
# estate answers about itself on.
run_mutation M7 gates/lint-app.mjs "an app may claim a route under /__" <<'MUT'
        else if (route.startsWith('/__'))
          fail(`route "${route}" is under /__, reserved for the estate's own manifest`);
||=>||
MUT

echo ""
echo "  $applied mutations applied, $((applied - survived)) killed, $survived survived"
if [ "$survived" -ne 0 ]; then
  echo "  a surviving mutation is a hole in the suite, not a passing run"
  exit 1
fi
