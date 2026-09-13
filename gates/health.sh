#!/bin/sh
# health.sh <base-url> <expected-sha> [samples] -- guard 5. Exit 0, or 7.
#
# Asserts CONVERGENCE, not liveness. Two defects the single-sample version had:
#
#   1. It made TWO requests per route -- one for the status code, one for the
#      header -- so during a rolling deploy the first could hit an old replica
#      and the second a new one, and the pair would pass while the estate was
#      mixed. Both facts must come from ONE response.
#   2. One sample cannot distinguish "converged" from "I happened to reach a
#      new replica". A fleet that is 10% migrated passes one sample 10% of the
#      time, which is not a bug you find by re-running.
#
# So: N samples per route, every one must report the expected build. This is
# still only evidence, not proof -- see spec.org, What completes a deployment.
set -eu
base="$1"; want="$2"; samples="${3:-${HEALTH_SAMPLES:-5}}"; rc=0
MODE="${HEALTH_MODE:-header}"   # header | manifest (static targets)

for app in $(jq -r '.[].app' router/routes.json); do
  path=$(jq -r --arg a "$app" '.[] | select(.app==$a) | .health' router/routes.json)
  seen=""; bad=0
  n=1
  while [ "$n" -le "$samples" ]; do
    # Cache-bust. A CDN with max-age=600 serves the OLD build for ten
    # minutes after deploy, and a convergence check that trusts it is
    # measuring the CDN, not the estate (spec.org, Targets).
    bust="$(date +%s)-$n"
    if [ "$MODE" = "manifest" ]; then
      # Static targets (GitHub Pages) cannot set response headers, so the
      # served build is published as a generated file instead.
      body=$(curl -sS --max-time 10 -H "Cache-Control: no-cache" \
               "$base/version.json?_cb=$bust" 2>/dev/null || echo "{}")
      code=$(curl -sS -o /dev/null --max-time 10 -H "Cache-Control: no-cache" \
               -w "%{http_code}" "$base/version.json?_cb=$bust" 2>/dev/null || echo 000)
      sha=$(printf '%s' "$body" | jq -r '.sha // "-"' 2>/dev/null || echo "-")
    else
      # one request, both facts
      resp=$(curl -sS -o /dev/null --max-time 10 -H "Cache-Control: no-cache" \
               -w '%{http_code} %header{x-build-sha}' "$base$path?_cb=$bust" \
               2>/dev/null || echo "000 -")
      code=${resp%% *}; sha=${resp##* }
    fi
    case "$seen" in *" $sha "*) : ;; *) seen="$seen $sha " ;; esac
    if [ "$code" != "200" ] || [ "$sha" != "$want" ]; then bad=$((bad+1)); fi
    n=$((n+1))
  done
  distinct=$(echo "$seen" | tr ' ' '\n' | grep -c . || true)
  if [ "$bad" -gt 0 ]; then
    echo "UNHEALTHY $app: $bad/$samples samples not serving $want (saw:$seen)"
    rc=7
  elif [ "$distinct" -gt 1 ]; then
    echo "UNCONVERGED $app: still serving more than one build (saw:$seen)"
    rc=7
  else
    echo "ok $app $path ($samples/$samples on $want)"
  fi
done
exit $rc
