#!/bin/sh
# switch.sh [blue|green|status] -- the cutover.
#
# `status` asks the RUNNING FRONT which colour it is serving, by making a
# request and reading x-colour. It does not read the state file: that is what
# the bastille switch did, and it reported blue while green was serving.
set -eu
cd "$(dirname "$0")"
FRONT="${FRONT_URL:-http://127.0.0.1:9230}"
case "${1:-status}" in
  status)
    c=$(curl -sI --max-time 5 "$FRONT/" | tr -d '\r' | awk 'tolower($1)=="x-colour:"{print $2}')
    s=$(curl -sI --max-time 5 "$FRONT/" | tr -d '\r' | awk 'tolower($1)=="x-build-sha:"{print $2}')
    [ -n "$c" ] || { echo "front at $FRONT is not answering" >&2; exit 1; }
    echo "  production = $c  serving $s   (asked the front, not the file)"
    ;;
  blue|green)
    want="$1"
    port=$([ "$want" = blue ] && echo 9210 || echo 9220)
    # Never cut over to a colour that is not answering. A cutover to a dead
    # replica is an outage performed deliberately.
    curl -s -o /dev/null --max-time 5 "http://127.0.0.1:$port/" \
      || { echo "refused: $want (:$port) is not answering -- cutting over would be an outage" >&2; exit 5; }
    printf '%s' "$want" > live
    sleep 0.2
    got=$(curl -sI --max-time 5 "$FRONT/" | tr -d '\r' | awk 'tolower($1)=="x-colour:"{print $2}')
    [ "$got" = "$want" ] || { echo "cutover did not take: front still reports '$got'" >&2; exit 6; }
    echo "  production -> $want   (confirmed by asking the front)"
    ;;
  *) echo "usage: switch.sh {blue|green|status}" >&2; exit 2 ;;
esac
