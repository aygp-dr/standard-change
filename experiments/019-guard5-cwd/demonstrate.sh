#!/bin/sh
# demonstrate.sh -- guard 5 must not depend on where you stand. (#24)
#
# HYPOTHESIS. gates/health.sh read `router/routes.json` as a BARE RELATIVE
# PATH, so the route table it probed came from the caller's working directory.
# Guard 5 is the guard documented as having no bypass, ever, and its label is
# the only evidence the forge gets that production converged.
#
# Two consequences, and the second is the one that matters:
#
#   1. WRONG VERDICT. Confirmed live on staging at e7b0e7d (#19): UNHEALTHY
#      from the main checkout, ok 5/5 from #19's worktree. Same estate, same
#      build, same command.
#
#   2. VACUOUS PASS. From any directory with no checkout under it, jq cannot
#      open the file, `for app in $(jq ...)` iterates an empty list under
#      `set -e` WITHOUT aborting, and the script exits 0 having sampled
#      nothing. With --pr that records `pass` and adds <env>:healthy.
#
# (2) is not in the issue. It was found while reproducing (1), and it is
# strictly worse: (1) refuses a healthy estate, (2) certifies an estate it
# never looked at.
#
# SUCCESS CRITERION. B1/B1b/B2 are the issue. B3-B6 are the vacuous pass and
# the refusal contract. All six must hold.
#
# NO SERVER, NO PORTS. Every case is decided before a sample is taken, or
# against a stubbed transport (stub/curl). Nothing here is ever run with --pr:
# this experiment must not be able to write a label or an evidence record.
#
# RUN:
#   ./experiments/019-guard5-cwd/demonstrate.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
here="$root/experiments/019-guard5-cwd"
work=$(mktemp -d "${TMPDIR:-/tmp}/guard5.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM
PATH="$here/stub:$PATH"; export PATH

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok    %-4s %s\n' "$1" "$2"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %-4s %s\n' "$1" "$2"; }
check(){ if [ "$3" = "$4" ]; then ok "$1" "$2"; else bad "$1" "$2 -- expected [$3] got [$4]"; fi; }

# An estate is a directory holding the sha every sample reports.
estate() { mkdir -p "$work/e-$1"; printf '%s' "$2" > "$work/e-$1/sha"; echo "$work/e-$1"; }

# Run the REAL gates/health.sh from a chosen cwd. G5_OUT, G5_RC.
guard5() { # guard5 <cwd> <stub-dir> <base> <sha> <samples>
  _cwd="$1"; _stub="$2"; shift 2
  set +e
  G5_OUT=$(cd "$_cwd" && STUB_DIR="$_stub" sh "$root/gates/health.sh" "$@" 2>&1)
  G5_RC=$?
  set -e
}

# Run a COPY of health.sh whose own tree carries a chosen route table. This is
# how the tree-side cases are reached now that the caller's cwd is ignored --
# which is itself the point of the fix.
#
# `-` as the route table means the tree has NO router/routes.json at all.
# `--old` as the script means the pre-#24 gates/health.sh, taken from git, so
# the suite can show it detects the defect rather than merely agreeing with
# the fix. A suite that cannot fail on the old code has not tested the new.
guard5_tree() { # guard5_tree <routes-json|-> <stub-dir> <base> <sha> <samples>
  _routes="$1"; _stub="$2"; shift 2
  _t=$(mktemp -d "${TMPDIR:-/tmp}/g5tree.XXXXXX")
  mkdir -p "$_t/gates" "$_t/router"
  if [ "$_old" = 1 ]; then
    git -C "$root" show "$BASELINE:gates/health.sh" > "$_t/gates/health.sh"
  else
    cp "$root/gates/health.sh" "$_t/gates/health.sh"
  fi
  [ "$_routes" = - ] || cp "$_routes" "$_t/router/routes.json"
  set +e
  G5_OUT=$(cd "$_t" && STUB_DIR="$_stub" sh "$_t/gates/health.sh" "$@" 2>&1); G5_RC=$?
  set -e
  rm -rf "$_t"
  _old=0
}
_old=0
old() { _old=1; }
# The commit this branch departs from. The pre-#24 script must come from
# somewhere that cannot drift as this branch is edited.
BASELINE="${BASELINE:-origin/main}"

refused() { printf '%s' "$G5_OUT" | awk '/REFUSED/{print "REFUSED"; exit}'; }
# A refusal must say WHICH thing it could not do. Without this the suite
# cannot tell two different refusals apart, and mutation showed exactly that:
# dropping the route-table validation still refused -- via the backstop, for
# the wrong reason -- and no assertion noticed.
why() { printf '%s\n' "$G5_OUT" | grep -qF "$1" && echo yes || echo no; }

live=$(estate live abc1234)
stale=$(estate stale wrongsha)

empty="$work/not-a-checkout"; mkdir -p "$empty"

echo "== B0 -- the suite can see the defect"

# B0. THE PRE-#24 GATE, unreachable estate, sha that does not exist, no route
# table anywhere: it exits 0. `for app in $(jq ...)` does not abort under
# `set -e` when the substitution fails -- the list is empty, the loop body
# never runs, rc stays 0. With --pr that records `pass` and adds
# <env>:healthy for an estate nothing sampled.
#
# If this assertion ever fails, the rest of the suite proves nothing: it would
# mean the defect is not reproducible here and the other cases are agreeing
# with the fix rather than testing it.
old; guard5_tree - "$live" "http://127.0.0.1:1" deadbeef 2
check B0 "pre-#24 guard 5 PASSES having sampled nothing" "0" "$G5_RC"

echo ""
echo "== B1/B2 -- the verdict must not depend on the caller's directory"

# B1. The same inputs, the current gate. Exit 4: I could not check.
guard5_tree - "$live" "http://127.0.0.1:1" deadbeef 2
check B1 "the same run now refuses (exit 4)" "4 REFUSED" "$G5_RC $(refused)"
check B1c "and refuses for the RIGHT reason" "yes" "$(why 'no route table at')"

# B1b. And it emits no VERDICT LINE. Anchored at column 0 on purpose: guard 5
# prints its verdicts unindented ("ok core ...", "UNHEALTHY pdp ..."), and the
# refusal text deliberately contains the word UNHEALTHY in a sentence saying
# this is not that. An unanchored grep matched the explanation and failed the
# assertion -- a check that cannot pass is as useless as one that cannot fail.
check B1b "the refusal emits no verdict line" \
  "no" "$(printf '%s\n' "$G5_OUT" | grep -qE '^(ok |UNHEALTHY |UNCONVERGED )' && echo yes || echo no)"

# B2. THE ISSUE ITSELF. cwd holds a route table naming a health path the build
# does not serve -- the #19 shape, reduced to the part that decided it. The
# table must come from health.sh's OWN tree, so /p/PING is never probed.
other="$work/other-tree"; mkdir -p "$other/router"
jq '[ .[] | if .app=="pdp" then .health = "/p/PING" else . end ]' \
  "$root/router/routes.json" > "$other/router/routes.json"
guard5 "$other" "$live" http://stub abc1234 2
check B2 "a route table in cwd is NOT consulted" \
  "0 no" "$G5_RC $(printf '%s' "$G5_OUT" | grep -q '/p/PING' && echo yes || echo no)"

echo ""
echo "== B3-B6 -- a gate must not be able to pass by not looking"

# B3. An empty route table is not an estate with nothing wrong with it.
echo '[]' > "$work/empty.json"
guard5_tree "$work/empty.json" "$live" http://stub abc1234 2
check B3 "zero apps declared -> refusal, never a pass" "4 REFUSED" "$G5_RC $(refused)"
check B3b "and names the empty table as the reason" "yes" "$(why 'declares no apps')"

# B4. The run names the route table it used. `production:healthy` could not
# say which build it was about (#16); it also could not say which ROUTE TABLE,
# and #24 is the record of that being the deciding variable.

guard5 "$root" "$live" http://stub abc1234 2
check B4 "the run names the route table it used" \
  "0 yes" "$G5_RC $(printf '%s' "$G5_OUT" | grep -q "$root/router/routes.json" && echo yes || echo no)"

# B5. The refusal path must not have swallowed the ability to say no.
guard5 "$root" "$stale" http://stub abc1234 2
check B5 "an estate on the wrong build is still UNHEALTHY (7)" \
  "7 yes" "$G5_RC $(printf '%s' "$G5_OUT" | grep -q 'UNHEALTHY' && echo yes || echo no)"

# B6. An app that declares no health path cannot be asked about. Before this
# the path became the string "null", $base/null 404'd, and a defect in the
# route table was reported as an unhealthy estate.
jq '[ .[] | if .app=="pdp" then del(.health) else . end ]' \
  "$root/router/routes.json" > "$work/nohealth.json"
guard5_tree "$work/nohealth.json" "$live" http://stub abc1234 2
check B6 "an app with no health path -> refusal, not UNHEALTHY" \
  "4 REFUSED" "$G5_RC $(refused)"
check B6b "and names the app it could not ask about" "yes" "$(why "app 'pdp' declares no health path")"

echo ""
echo "  $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
