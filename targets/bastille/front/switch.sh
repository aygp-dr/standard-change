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
    # python, not sed: the replacement contains '#', which terminates a
    # '#'-delimited BSD sed expression and silently corrupts the edit.
    python3 - "$ip" "$1" <<'PY'
import re, sys
ip, colour = sys.argv[1], sys.argv[2]
c = open('nginx.conf').read()
c = re.sub(r'upstream production \{ server [0-9.]+; \}.*',
           f'upstream production {{ server {ip}; }}   # {colour}', c)
open('nginx.conf', 'w').write(c)
PY
    pkill -f 'nginx.*front/nginx.conf' 2>/dev/null || true
    sleep 1
    mkdir -p tmp && nginx -c "$PWD/nginx.conf" -p "$PWD" >/dev/null 2>&1 &
    sleep 1
    echo "production -> $1 ($ip)"
    ;;
  status)
    cur=$(grep -o 'upstream production { server [0-9.]*' nginx.conf | grep -o '[0-9.]*$')
    col=$([ "$cur" = "$BLUE" ] && echo blue || echo green)
    echo "production = $col ($cur)   serving $(curl -s --max-time 3 http://127.0.0.1:9100/version.json | jq -c . 2>/dev/null)"
    ;;
  *) echo "usage: switch.sh {blue|green|status}" >&2; exit 2 ;;
esac
