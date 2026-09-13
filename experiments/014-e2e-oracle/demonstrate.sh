#!/bin/sh
# demonstrate.sh [base-url] -- make gates/e2e.sh be wrong, then watch it refuse.
#
# HYPOTHESIS (issue #14). Before this experiment's change, gates/e2e.sh takes
# its expectations from router/routes.json in the tree it runs in while sending
# its requests to ROUTER_URL. A runner tree that declares FEWER routes than the
# deployed build therefore passes green having never probed the routes the
# build added -- the failure mode that is wrong in the UNSAFE direction, as
# opposed to the one actually observed on :9200 (which merely failed a working
# estate).
#
# SUCCESS CRITERION. Against ONE estate, from ONE stale tree:
#   1. the pre-#14 gate exits 0 with FEWER checks than the estate has routes;
#   2. the post-#14 gate probes every route the BUILD declares, and says out
#      loud that the tree and the build disagree;
#   3. the post-#14 gate, pointed at a build that publishes no route table and
#      reports a different sha than the tree, exits 4 and records nothing;
#   4. ORACLE_MODE=tree reproduces (1)'s blindness on demand and refuses to
#      record a verdict for it.
#
# RUN (dev block 1; the estate must already be up from THIS tree):
#   ./experiments/014-e2e-oracle/demonstrate.sh http://127.0.0.1:9010
set -eu
base="${1:-${ROUTER_URL:-http://127.0.0.1:9010}}"
root=$(cd "$(dirname "$0")/../.." && pwd)
stub_port="${STUB_PORT:-9016}"     # block 1, offsets 6-9 are unallocated
work=$(mktemp -d -t e2eoracle)
# Kill the stub BEFORE removing the directory that holds its pid file. The
# other order leaves a listener on $stub_port and the next run dies EADDRINUSE.
cleanup() {
  [ -f "$work/.stub.pid" ] && kill "$(cat "$work/.stub.pid")" 2>/dev/null
  rm -rf "$work"
  return 0
}
trap cleanup EXIT INT TERM

hr() { printf '\n== %s\n' "$*"; }

# ---- 0. the estate under test ------------------------------------------------
hr "0. the estate at $base"
curl -s --max-time 5 "$base/__estate.json" | jq -e '.routes|length>0' >/dev/null 2>&1 || {
  echo "no estate publishing /__estate.json at $base." >&2
  echo "start block 1 from this tree first (gmake port-alloc; gmake dev)." >&2
  exit 2; }
estate_sha=$(curl -s --max-time 5 "$base/__estate.json" | jq -r .sha)
estate_routes=$(curl -s --max-time 5 "$base/__estate.json" | jq '[.routes[].routes[]]|length')
echo "  build $estate_sha declares $estate_routes routes"

# ---- 1. a runner tree that is NOT the build ----------------------------------
# The CI shape: the gate runs from a checkout, the build runs somewhere else.
# Here the checkout is one route behind -- plp's /c/:category, exactly the
# route PR #11 added and main did not have.
hr "1. a stale runner tree (one route behind the build)"
git -C "$root" archive HEAD | tar -x -C "$work"
cp "$root/gates/e2e.sh" "$root/gates/oracle.sh" "$work/gates/"   # the fix, uncommitted
git -C "$root" show HEAD:gates/e2e.sh > "$work/gates/e2e-before.sh"
chmod +x "$work/gates/e2e-before.sh"
jq 'del(.probes) | .routes = ["/search"]' "$root/apps/plp/routes.json" > "$work/apps/plp/routes.json"
( cd "$work" && sh router/generate.sh >/dev/null )
echo "  tree declares: $(jq -c '[.[].routes[]]|length' "$work/router/routes.json") routes"
echo "  missing from the tree: plp /c/:category"

# ---- 2. the defect: green because it did not look ----------------------------
hr "2. the PRE-#14 gate, stale tree -> deployed build"
set +e
before=$(cd "$work" && ROUTER_URL="$base" ./gates/e2e-before.sh 2>&1); before_rc=$?
set -e
echo "$before" | sed 's/^/  | /'
echo "  exit $before_rc"
before_n=$(echo "$before" | awk '/checks passed/{print $1}')

# ---- 3. the fix: the oracle comes from the build ------------------------------
hr "3. the POST-#14 gate, SAME stale tree -> SAME build"
set +e
after=$(cd "$work" && ROUTER_URL="$base" ./gates/e2e.sh 2>&1); after_rc=$?
set -e
echo "$after" | sed 's/^/  | /'
echo "  exit $after_rc"
after_n=$(echo "$after" | awk '/checks passed/{print $1}')

# ---- 4. a build that cannot be checked at all --------------------------------
# No route table, and a sha that is not this tree. Before #14 this was the
# silent case: the gate would have asserted the tree's contract against an
# unknown build. Now it is the loud one.
hr "4. the POST-#14 gate -> a build that publishes nothing and is not this tree"
cat > "$work/stub.mjs" <<'STUB'
import { createServer } from 'node:http';
createServer((req, res) => {
  res.writeHead(200, { 'content-type': 'application/json', 'x-build-sha': '0000000' });
  res.end('{}');
}).listen(Number(process.argv[2]), '127.0.0.1');
STUB
node "$work/stub.mjs" "$stub_port" & echo $! > "$work/.stub.pid"
sleep 1
set +e
refused=$(cd "$work" && ROUTER_URL="http://127.0.0.1:$stub_port" ./gates/e2e.sh 2>&1); refused_rc=$?
set -e
echo "$refused" | sed 's/^/  | /'
echo "  exit $refused_rc"

# ---- 5. the escape hatch cannot convict --------------------------------------
hr "5. ORACLE_MODE=tree: the old behaviour, on purpose, unlabelled"
set +e
# --pr with a repo that does not exist: the point is that the label branch is
# never reached, and nothing should be able to reach GitHub if that is wrong.
forced=$(cd "$work" && ORACLE_MODE=tree GH_REPO=aygp-dr/no-such-repo-oracle-demo \
           ROUTER_URL="$base" ./gates/e2e.sh --pr 0 2>&1); forced_rc=$?
set -e
echo "$forced" | sed 's/^/  | /'
echo "  exit $forced_rc"
forced_n=$(echo "$forced" | awk '/checks passed/{print $1}')

# ---- verdict -----------------------------------------------------------------
hr "verdict"
ok=0
check() { if [ "$2" = "$3" ]; then echo "  PASS $1"; else echo "  FAIL $1 (got '$2', want '$3')"; ok=1; fi; }
[ "$before_rc" = 0 ] && echo "  PASS the pre-#14 gate reported success" \
                     || { echo "  FAIL the pre-#14 gate did not report success"; ok=1; }
if [ "$before_n" -lt "$after_n" ]; then
  echo "  PASS it did so with $before_n checks where the build needs $after_n --"
  echo "       $((after_n - before_n)) contract(s) of the deployed build went unprobed"
else
  echo "  FAIL the stale tree did not check less ($before_n vs $after_n)"; ok=1
fi
check "the fixed gate probes the build's routes" \
      "$(echo "$after" | grep -c '/c/shoes')" 1
check "and names the disagreement" \
      "$(echo "$after" | grep -c 'note: the build owns plp /c/:category')" 1
check "an unestablishable oracle exits 4" "$refused_rc" 4
check "and says REFUSED" "$(echo "$refused" | grep -c '^REFUSED')" 1
check "a forced oracle reproduces the blindness" "$forced_n" "$before_n"
check "and records no verdict" \
      "$(echo "$forced" | grep -c 'nothing: the oracle was supplied by the caller')" 1
echo
[ "$ok" = 0 ] && echo "  014: hypothesis supported" || echo "  014: NOT supported"
exit "$ok"
