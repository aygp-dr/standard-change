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
    [ -f nginx.conf ] || sed "s/@PRODUCTION@/$BLUE/" nginx.conf.in > nginx.conf
    cur=$(grep -o 'upstream production { server [0-9.]*' nginx.conf | grep -o '[0-9.]*$')
    col=$([ "$cur" = "$BLUE" ] && echo blue || echo green)
    echo "production = $col ($cur)   serving $(curl -s --max-time 3 http://127.0.0.1:9100/version.json | jq -c . 2>/dev/null)"
    ;;
  *) echo "usage: switch.sh {blue|green|status}" >&2; exit 2 ;;
esac
