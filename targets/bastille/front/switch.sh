#!/bin/sh
# switch.sh {blue|green|status} -- flip production between the two estates.
#
# An atomic cutover, not a rollout: nginx reloads with one upstream, so no
# request is ever served by the estate being switched away from. Rollback is
# the same command with the other colour, which is why blue/green gives a
# reachable rollback target for free (spec.org, Refutation condition on the
# recorded production SHA staying reachable).
set -eu
cd "$(dirname "$0")"
BLUE=10.0.0.61; GREEN=10.0.0.62
case "${1:-status}" in
  blue|green)
    ip=$([ "$1" = blue ] && echo $BLUE || echo $GREEN)
    # Render from the tracked template, never edit a tracked file in place.
    sed "s/@PRODUCTION@/$ip/" nginx.conf.in > nginx.conf
    pkill -f 'nginx.*front/nginx.conf' 2>/dev/null || true
    sleep 1
    mkdir -p tmp && nginx -c "$PWD/nginx.conf" -p "$PWD" >/dev/null 2>&1 &
    sleep 1
    echo "production -> $1 ($ip)"
    ;;
  status)
    # Ask the RUNNING router; do not read the config file and call it fact.
    # The file is intent -- a reload may not have happened -- and reporting
    # intent as observation is the self-report failure this model is about.
    # This command said "blue" while green was serving, for exactly that reason.
    [ -f nginx.conf ] || sed "s/@PRODUCTION@/$BLUE/" nginx.conf.in > nginx.conf
    want=$(grep -o 'upstream production { server [0-9.]*' nginx.conf | grep -o '[0-9.]*$')
    want_col=blue; [ "$want" = "$GREEN" ] && want_col=green
    live_json=$(curl -s --max-time 3 http://127.0.0.1:9200/version.json 2>/dev/null || echo '{}')
    live_rep=$(printf '%s' "$live_json" | jq -r '.replica // "?"' 2>/dev/null || echo '?')
    live_col=unknown
    [ "$live_rep" = "1" ] && live_col=blue
    [ "$live_rep" = "2" ] && live_col=green
    if [ "$live_col" = "$want_col" ]; then
      echo "production = $live_col ($want)   serving $live_json"
    else
      echo "MISMATCH  config says $want_col ($want); the router is serving $live_col"
      echo "          $live_json"
      echo "          nginx was not reloaded after the config changed. Fix: switch.sh $want_col"
      exit 1
    fi
    ;;
  *) echo "usage: switch.sh {blue|green|status}" >&2; exit 2 ;;
esac
