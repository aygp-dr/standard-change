#!/bin/sh
# demonstrate.sh -- the oracle must come from the build, not from this tree. (#14)
#
# HYPOTHESIS. gates/e2e.sh sends its REQUESTS to $ROUTER_URL and, before this
# change, took its EXPECTATIONS from router/routes.json in the tree the script
# happened to live in. The working directory therefore decided the verdict:
# 24 checks and staging:e2e-failed from the main checkout, 27 and staging:e2e
# from the PR's worktree, against ONE deployed build on :9200.
#
# That instance was wrong in the SAFE direction, which was luck. The same
# mechanism is silent and green when the runner's tree declares FEWER routes
# than the build: every route the build added goes unprobed and the gate
# reports success because it did not know to look.
#
# SUCCESS CRITERION. Six assertions, listed in the table below. The load-
# bearing ones are A2 (the oracle names the build's routes, which this tree
# does not have) and A3 (an estate whose build cannot be established yields
# exit 4 and NO verdict, rather than a verdict against the wrong contract).
#
# NO SERVER, NO PORTS. The estates here are directories, not sockets. The
# transport is stubbed by stub/curl; gates/oracle.sh is the real file. See
# stub/curl for why that is the honest way round.
#
# RUN:
#   ./experiments/018-e2e-oracle/demonstrate.sh
#
# Exit 0 if every assertion holds, 1 otherwise, and it prints one line per
# assertion either way so a mutation run can be counted.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
here="$root/experiments/018-e2e-oracle"
work=$(mktemp -d "${TMPDIR:-/tmp}/e2eoracle.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM

PATH="$here/stub:$PATH"; export PATH
pass=0; fail=0

ok()   { pass=$((pass+1)); printf '  ok    %-4s %s\n' "$1" "$2"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %-4s %s\n' "$1" "$2"; }
check(){ # check <id> <desc> <expected> <actual>
  if [ "$3" = "$4" ]; then ok "$1" "$2"
  else bad "$1" "$2 -- expected [$3] got [$4]"; fi; }

# An estate is a directory: a sha it reports, and optionally a manifest body.
estate() { # estate <name> <sha> [manifest-file]
  mkdir -p "$work/$1"
  printf '%s' "$2" > "$work/$1/sha"
  if [ $# -ge 3 ]; then cp "$3" "$work/$1/estate.json"; fi
  echo "$work/$1"
}

# Run oracle.sh standalone against an estate. Prints its stdout; sets ORC_RC.
probe() { # probe <estate-dir> [env-assignments...]
  _d="$1"; shift
  set +e
  ORC_OUT=$(STUB_DIR="$_d" env "$@" sh "$root/gates/oracle.sh" http://stub 2>&1)
  ORC_RC=$?
  set -e
}

head=$(git -C "$root" rev-parse --short HEAD)

echo "== the build under test declares a route this tree does not have"
# plp's /c/:category is exactly the route #11 added and main did not have --
# the route whose absence from the runner's tree produced the two verdicts.
jq '[ .[] | if .app=="plp" then .routes += ["/c/:category"]
            | .probes = {"/c/:category":"/c/shoes"} else . end ]' \
   "$root/router/routes.json" > "$work/build-routes.json"
jq -n --slurpfile r "$work/build-routes.json" \
   '{sha:"bu11d00", block:"staging", base_port:9200, served_by:"router", routes:$r[0]}' \
   > "$work/manifest.json"
echo "  tree  declares $(jq '[.[].routes[]]|length' "$root/router/routes.json") routes at $head"
echo "  build declares $(jq '[.routes[].routes[]]|length' "$work/manifest.json") routes at bu11d00"
echo ""

echo "== assertions"

# A1. A build that publishes its route table IS the oracle.
d=$(estate publishes bu11d00 "$work/manifest.json")
probe "$d"
check A1 "manifest present -> oracle comes from the estate" \
  "0 estate" "$ORC_RC $(printf '%s' "$ORC_OUT" | awk '/^oracle:/{print $2}')"

# A2. THE POINT OF THE ISSUE. The oracle contains the route the BUILD owns and
# this tree does not. Before #14 this route was never probed and the gate said
# 27 checks passed -- green because it did not look.
check A2 "the oracle names a route absent from this tree" \
  "yes" "$(printf '%s' "$ORC_OUT" | grep -q '/c/:category' && echo yes || echo no)"

# A3. No manifest, and the estate is on a build this tree is not. The gate
# cannot say anything about that estate in EITHER direction: exit 4, no verdict.
# 4 is "I could not check" and it blocks (docs/exit-codes.org).
d=$(estate older 0ldbu1d)
probe "$d"
check A3 "no manifest + sha != HEAD -> exit 4, refused" \
  "4 REFUSED" "$ORC_RC $(printf '%s' "$ORC_OUT" | awk '/REFUSED/{print "REFUSED"; exit}')"

# A4. No manifest, but the estate is serving THIS tree. Then the tree IS the
# build and its routes.json is the build's -- established, not assumed.
d=$(estate mine "$head")
probe "$d"
check A4 "no manifest + sha == HEAD -> oracle is the tree, allowed" \
  "0 tree" "$ORC_RC $(printf '%s' "$ORC_OUT" | awk '/^oracle:/{print $2}')"

# A5. The shape check. A router predating the manifest falls through to core,
# whose 404 body also has a `routes` key -- an array of STRINGS describing one
# app. Accepting it yields an 8-app oracle from a 5-app estate. Here the estate
# is on THIS tree's sha, so a naive oracle would take core's answer and win;
# only the shape check sends it to the tree instead.
d=$(estate shapey "$head")
probe "$d"
check A5 "core's 404 body is not mistaken for a manifest" \
  "0 tree" "$ORC_RC $(printf '%s' "$ORC_OUT" | awk '/^oracle:/{print $2}')"

# A6. The escape hatch reproduces the old blindness on demand, and SAYS SO.
# gates/e2e.sh keys off tree-forced to record no label: a caller-supplied
# oracle may inform you, it may not convict.
d=$(estate older 0ldbu1d)
probe "$d" ORACLE_MODE=tree
check A6 "ORACLE_MODE=tree -> tree-forced, never plain tree" \
  "0 tree-forced" "$ORC_RC $(printf '%s' "$ORC_OUT" | awk '/^oracle:/{print $2}')"

# A7. THE OTHER END OF THE CONTRACT. oracle.sh only accepts a manifest whose
# shape says `served_by: "router"` with an array of app objects. Nothing else
# in the suite checks that router/server.js actually emits that shape, and a
# router that publishes something the oracle rejects would send every gate run
# down the refusal path -- green suite, dead pipeline.
#
# NOT EXERCISED OVER HTTP. Reaching the handler means binding a socket, which
# this host forbids while the estate is live, so this is a static contract
# check between the two files and is reported as such. The endpoint's live
# behaviour is UNVERIFIED here; see notes.org.
manifest_src=$(sed -n '/req.url.split/,/res.end(body)/p' "$root/router/server.js")
have=$(printf '%s' "$manifest_src" | grep -c "served_by: 'router'" || true)
have2=$(printf '%s' "$manifest_src" | grep -c 'routes: apps' || true)
check A7 "router/server.js emits the shape oracle.sh requires (static)" \
  "1 1" "$have $have2"

# A8. /__ is reserved, and the linter is what reserves it. If an app could
# claim /__estate.json the router would still answer it first, but the app
# would believe it owned a path it never receives -- and a later router that
# routed it would silently replace the oracle with an app's opinion.
lintdir="$work/lintapp/plp"
mkdir -p "$lintdir"
jq '.routes += ["/__estate.json"]' "$root/apps/plp/routes.json" > "$lintdir/routes.json"
set +e
lintout=$(node "$root/gates/lint-app.mjs" "$lintdir" 2>&1); lintrc=$?
set -e
check A8 "lint rejects an app route under /__" \
  "1 yes" "$lintrc $(printf '%s' "$lintout" | grep -q 'reserved for the estate' && echo yes || echo no)"

echo ""
echo "  $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
