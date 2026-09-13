#!/bin/sh
# health.sh <base-url> <expected-sha> -- guard 5. Exit 0 healthy, 7 unhealthy.
set -eu
base="$1"; want="$2"; rc=0
for app in $(jq -r '.[].app' router/routes.json); do
  path=$(jq -r --arg a "$app" '.[] | select(.app==$a) | .health' router/routes.json)
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$base$path" || echo 000)
  sha=$(curl -sSI --max-time 10 "$base$path" | tr -d '\r' \
        | awk -F': ' 'tolower($1)=="x-build-sha"{print $2}')
  if [ "$code" != "200" ]; then echo "UNHEALTHY $app $path -> HTTP $code"; rc=7
  elif [ "$sha" != "$want" ]; then echo "UNHEALTHY $app serving $sha, expected $want"; rc=7
  else echo "ok $app $path"; fi
done
exit $rc
