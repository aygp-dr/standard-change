#!/bin/sh
# e2e.sh [group...] -- the third gate. Journeys through the router.
#
# ROUTER_URL is the router under test: a worktree block locally, a staging slot
# in CI. Same contract either way, which is the point of the port-block model.
#
# Asserts three things a per-app unit test cannot:
#   1. ROUTE OWNERSHIP -- each path is served by the app that declares it in
#      routes.json. A router that sends /search to core returns 200 and is wrong.
#      One app may declare `fallthrough`: it is the default location, and an
#      unclaimed path reaches it rather than 404ing at the router. Ownership is
#      still asserted -- the 404 must carry that app's name.
#   2. CROSS-APP JOURNEYS -- add-to-cart starts on pdp and asserts on /cart,
#      which no single app's tests can cover.
#   3. ONE ESTATE -- every app behind this router reports the same x-build-sha.
#      A block serving a mixed fleet is not a coherent thing to test.
#
# --pr <n> records the result as an OBSERVATION label, staging:e2e or
# staging:e2e-failed. The gate labels its own result because the gate is the
# instrument (change/observe.sh, guard4.sh).
set -eu
PR=''
ENV_=''
while [ $# -gt 0 ]; do
  case "$1" in
    --pr)  PR="${2:?--pr needs a number}"; shift 2 ;;
    --env) ENV_="${2:?--env needs a name}"; shift 2 ;;
    *)    break ;;
  esac
done
base="${ROUTER_URL:-http://127.0.0.1:10000}"
cd "$(dirname "$0")/.."
rc=0; pass=0

say()  { printf '  %-26s %s\n' "$1" "$2"; }
fail() { echo "FAIL $*"; rc=1; }

get()      { curl -s --max-time 5 "$base$1"; }
code()     { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$base$1"; }
owner()    { get "$1" | jq -r '.app // "-"' 2>/dev/null || echo -; }
buildsha() { curl -sI --max-time 5 "$base$1" | tr -d '\r' | awk 'tolower($1)=="x-build-sha:"{print $2}'; }
routedto() { curl -sI --max-time 5 "$base$1" | tr -d '\r' | awk 'tolower($1)=="x-routed-to:"{print $2}'; }
ctype()    { curl -sI --max-time 5 "$base$1" | tr -d '\r' | awk 'tolower($1)=="content-type:"{print $2}'; }

# 1. route ownership, straight from routes.json -- the source of truth
for app in $(jq -r '.[].app' router/routes.json); do
  for route in $(jq -r --arg a "$app" '.[]|select(.app==$a)|.routes[]' router/routes.json); do
    # A parameterised route has no universally valid instance. This gate used
    # to synthesize one by substitution (/c/:category -> /c/PROBE), which
    # assumed every value of every parameter exists -- true while the apps
    # echoed back whatever they were handed, false the moment plp started
    # checking the category against its catalogue, at which point /c/PROBE is
    # correctly a 404 and the ownership check failed on a working estate.
    #
    # The app declares a real instance in its routes.json (`probes`), because
    # the app is the only thing that knows one; lint-app.mjs checks the probe
    # lies inside the route it names, so this cannot be used to point the
    # ownership check at some easier path. Substitution stays the default for
    # routes whose parameters are still free (pdp's /p/:sku).
    path=$(jq -r --arg a "$app" --arg r "$route" \
             '.[]|select(.app==$a)|.probes[$r] // empty' router/routes.json)
    [ -n "$path" ] || path=$(printf '%s' "$route" | sed 's#:[a-zA-Z_]*#PROBE#g')
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

# 2. an unrouted path must 404 -- and the 404 must come from the app that
# declares fallthrough, not from the router. The router's default location
# proxies to core (nginx: location / { proxy_pass http://core; }), so core is
# what decides a path does not exist. Asserting only the status code would
# pass even if the router had quietly gone back to answering 404 itself, which
# is a different estate: it would mean core is NOT on the default path.
fbapp=$(jq -r '.[]|select(.fallthrough)|.app' router/routes.json)
c=$(code /definitely-not-a-route)
who=$(routedto /definitely-not-a-route)
[ "$c" = "404" ] && [ "$who" = "$fbapp" ] \
  && { say "/definitely-not-a-route" "404 from $who (correct)"; pass=$((pass+1)); } \
  || fail "unrouted path returned $c from '${who:--}', expected 404 from $fbapp"

# 2b. the fallthrough app serves its statics, and refuses what is not there.
# Same handler decides both, so this pins that 'default location' did not
# become 'core answers 200 for anything'.
c=$(code /statics/oneui.css); m=$(ctype /statics/oneui.css)
[ "$c" = "200" ] && [ "${m%%;*}" = "text/css" ] \
  && { say "/statics/oneui.css" "200 text/css"; pass=$((pass+1)); } \
  || fail "/statics/oneui.css returned $c $m, expected 200 text/css"

c=$(code /statics/not-a-file.css)
[ "$c" = "404" ] && { say "/statics/not-a-file.css" "404 (correct)"; pass=$((pass+1)); } \
                 || fail "missing static returned $c, expected 404"

# 2c. the statics root must not be an escape hatch out of the app.
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --path-as-is \
      "$base/statics/../../../../etc/passwd")
[ "$c" = "404" ] && { say "/statics/ traversal" "404 (correct)"; pass=$((pass+1)); } \
                 || fail "statics traversal returned $c, expected 404"

# 2e. owning a route is not promising every address under it exists.
#
# The same property as 2b, one level up: for core the prefix is /statics/ and
# the FILE decides; for plp the prefix is /c/ and the CATALOGUE decides. The
# ownership loop above now probes /c/shoes, a category that exists, so without
# this check "plp returns 200 for every /c/*" would sail through every gate --
# which is the shape of the defect 2b was written for.
#
# The 404 must carry plp's name. A router-level 404 would mean plp is not on
# the path at all, and a 200 with an empty page would mean a person asking for
# a category we do not carry is told, by every machine in between, that they
# found one.
c=$(code /c/definitely-not-a-category)
who=$(routedto /c/definitely-not-a-category)
[ "$c" = "404" ] && [ "$who" = "plp" ] \
  && { say "/c/<unknown category>" "404 from plp (correct)"; pass=$((pass+1)); } \
  || fail "unknown category returned $c from '${who:--}', expected 404 from plp"

# 2d. a browser must get a page, not a payload.
#
# Added after :9200 returned application/json to `Accept: text/html`. The estate
# is clickable when the node apps serve it and is not when the jails do, because
# targets/bastille/app.py does not content-negotiate -- so the thing a person
# opens in a browser has never been the thing any gate looked at.
#
# This check is expected to FAIL against the bastille jails today. That is the
# point: it is the difference between "the tests pass" and "the tests pass on
# what we deploy", and the gate should be the thing that says so.
htmltype() { curl -sI --max-time 5 -H 'Accept: text/html,application/xhtml+xml' "$base$1" \
               | tr -d '\r' | awk 'tolower($1)=="content-type:"{print $2}'; }
# /c/<unknown> is in this list deliberately: a no-results page is still a PAGE.
# An error path that quietly stops content-negotiating is the easiest place for
# a JSON blob to reach a person, because nobody clicks the sad path on purpose.
for path in / /checkout /search /c/definitely-not-a-category; do
  m=$(htmltype "$path")
  case "${m%%;*}" in
    text/html) say "browser GET $path" "text/html"; pass=$((pass+1)) ;;
    *)         fail "browser GET $path returned '${m:-none}', expected text/html" ;;
  esac
done

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

# Record it. Named for WHAT was measured -- contracts on this estate at this
# build -- because `staging:passed` could not say, and that ambiguity was used
# once to satisfy guard 4 with a measurement from a different estate.
if [ -n "$PR" ]; then
  repo="${GH_REPO:-${GITHUB_REPOSITORY:-aygp-dr/standard-change}}"
  sha=$(curl -sI --max-time 5 "$base/" | tr -d '\r' | awk 'tolower($1)=="x-build-sha:"{print $2}')
  # The label must name the environment it observed. Hardcoding "staging" made
  # a run against the PRODUCTION front record staging:e2e -- the same
  # ambiguity that let one estate's pass overwrite another's failure, one level
  # up. Derived from --env, or from the port when it is one we know.
  if [ -z "$ENV_" ]; then
    case "$base" in
      *:9200*) ENV_=staging ;;
      *:9230*) ENV_=production ;;
      *:9210*) ENV_=production-blue ;;
      *:9220*) ENV_=production-green ;;
      *)       ENV_=unknown ;;
    esac
  fi
  if [ "$rc" = 0 ]; then add="$ENV_:e2e"; rm_="$ENV_:e2e-failed"
  else                   add="$ENV_:e2e-failed"; rm_="$ENV_:e2e"; fi
  gh pr edit "$PR" --repo "$repo" --add-label "$add" --remove-label "$rm_" >/dev/null 2>&1 \
    || gh pr edit "$PR" --repo "$repo" --add-label "$add" >/dev/null 2>&1 || true
  echo "  #$PR <- $add  (observed on $base at build ${sha:-unknown})"
fi
exit $rc
