#!/bin/sh
# e2e.sh [group...] -- the third gate. Journeys through the router.
#
# ROUTER_URL is the router under test: a worktree block locally, a staging slot
# in CI. Same contract either way, which is the point of the port-block model.
#
# Asserts three things a per-app unit test cannot:
#   1. ROUTE OWNERSHIP -- each path is served by the app that declares it in
#      routes.json. A router that sends /search to core returns 200 and is wrong.
#   2. CROSS-APP JOURNEYS -- add-to-cart starts on pdp and asserts on /cart,
#      which no single app's tests can cover.
#   3. ONE ESTATE -- every app behind this router reports the same x-build-sha.
#      A block serving a mixed fleet is not a coherent thing to test.
set -eu
base="${ROUTER_URL:-http://127.0.0.1:10000}"
cd "$(dirname "$0")/.."
rc=0; pass=0

say()  { printf '  %-26s %s\n' "$1" "$2"; }
fail() { echo "FAIL $*"; rc=1; }

get()      { curl -s --max-time 5 "$base$1"; }
code()     { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$base$1"; }
owner()    { get "$1" | jq -r '.app // "-"' 2>/dev/null || echo -; }
buildsha() { curl -sI --max-time 5 "$base$1" | tr -d '\r' | awk 'tolower($1)=="x-build-sha:"{print $2}'; }

# 1. route ownership, straight from routes.json -- the source of truth
for app in $(jq -r '.[].app' router/routes.json); do
  for route in $(jq -r --arg a "$app" '.[]|select(.app==$a)|.routes[]' router/routes.json); do
    path=$(printf '%s' "$route" | sed 's#:[a-zA-Z_]*#PROBE#g')
    got=$(owner "$path"); c=$(code "$path")
    if [ "$c" = "200" ] && [ "$got" = "$app" ]; then
      say "$path" "200 $got"; pass=$((pass+1))
    elif [ "$c" != "200" ]; then
      # lead with the fault that actually happened; a 502 body still names the
      # app it tried to reach, so reporting ownership here reads as nonsense
      fail "$path -> HTTP $c (upstream '$app' unreachable)"
    else
      fail "$path -> 200 but served by '$got', expected '$app' (routing is wrong)"
    fi
  done
done

# 2. an unrouted path must 404 at the router, not fall through to an app
c=$(code /definitely-not-a-route)
[ "$c" = "404" ] && { say "/definitely-not-a-route" "404 (correct)"; pass=$((pass+1)); } \
                 || fail "unrouted path returned $c, expected 404"

# 3. cross-app journey: add-to-cart starts on pdp, asserts on cart (core)
sku=$(get /p/SKU123 | jq -r '.app' 2>/dev/null)
cart=$(get /cart    | jq -r '.app' 2>/dev/null)
[ "$sku" = "pdp" ] && [ "$cart" = "core" ] \
  && { say "journey add-to-cart" "pdp -> core"; pass=$((pass+1)); } \
  || fail "add-to-cart journey: pdp=$sku cart=$cart"

# 4. one estate: every app behind this router on the same build
shas=$(for app in $(jq -r '.[].app' router/routes.json); do
         r=$(jq -r --arg a "$app" '.[]|select(.app==$a)|.health' router/routes.json)
         buildsha "$r"
       done | sort -u | grep -c . || true)
[ "$shas" = "1" ] && { say "one estate" "all apps on one build"; pass=$((pass+1)); } \
                  || fail "router fronts $shas distinct builds; the block is not coherent"

echo "  $pass checks passed"
exit $rc
