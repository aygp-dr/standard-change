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
    # PRODUCTION IS LOUD. Everything else in this pipeline can be quiet -- a dev
    # block is disposable and staging is meant to be churned. This is the one
    # act that changes what strangers see, it is the one nobody can undo by
    # re-running it, and it had exactly one line of output.
    #
    # Printed BEFORE the switch, so if a person is watching they have a moment,
    # and so the record of what was about to happen survives a failure partway.
    _live=$(curl -sI --max-time 5 "$FRONT/" | tr -d '\r' | awk 'tolower($1)=="x-colour:"{print $2}')
    _lsha=$(curl -sI --max-time 5 "$FRONT/" | tr -d '\r' | awk 'tolower($1)=="x-build-sha:"{print $2}')
    _nsha=$(curl -sI --max-time 5 "http://127.0.0.1:$([ "$want" = blue ] && echo 9210 || echo 9220)/" \
              | tr -d '\r' | awk 'tolower($1)=="x-build-sha:"{print $2}')
    printf '\n\033[1;31m  ############  P R O D U C T I O N  C U T O V E R  ############\033[0m\n\n'
    printf '    front        %s\n' "$FRONT"
    printf '    live now     \033[1m%s\033[0m serving \033[1m%s\033[0m\n' "${_live:-unknown}" "${_lsha:-unknown}"
    printf '    switching to \033[1;33m%s\033[0m serving \033[1;33m%s\033[0m\n' "$want" "${_nsha:-unknown}"
    printf '    rollback     ./targets/node/switch.sh %s   (returns to %s)\n' \
           "${_live:-blue}" "${_lsha:-the previous build}"
    printf '    at           %s\n\n' "$(date -u +%FT%TZ)"
    if [ "${_nsha:-}" = "${_lsha:-x}" ]; then
      printf '    \033[33mnote\033[0m both colours are on the same build; this cutover changes nothing.\n\n'
    fi
    port=$([ "$want" = blue ] && echo 9210 || echo 9220)
    # Never cut over to a colour that is not answering. A cutover to a dead
    # replica is an outage performed deliberately.
    curl -s -o /dev/null --max-time 5 "http://127.0.0.1:$port/" \
      || { echo "refused: $want (:$port) is not answering -- cutting over would be an outage" >&2; exit 5; }
    printf '%s' "$want" > live
    sleep 0.2
    got=$(curl -sI --max-time 5 "$FRONT/" | tr -d '\r' | awk 'tolower($1)=="x-colour:"{print $2}')
    [ "$got" = "$want" ] || { echo "cutover did not take: front still reports '$got'" >&2; exit 6; }
    _after=$(curl -sI --max-time 5 "$FRONT/" | tr -d '\r' | awk 'tolower($1)=="x-build-sha:"{print $2}')
    printf '\033[1;32m    production is now %s serving %s\033[0m\n' "$want" "${_after:-unknown}"
    printf '    was %s serving %s -- rollback: ./targets/node/switch.sh %s\n' \
           "${_live:-unknown}" "${_lsha:-unknown}" "${_live:-blue}"
    printf '  ##############################################################\n\n'
    # Confirmed by ASKING THE FRONT, not by reading the file we just wrote.
    # switch.sh status used to read its own config while nginx served the other
    # colour, and said blue while green was live.
    ;;
  *) echo "usage: switch.sh {blue|green|status}" >&2; exit 2 ;;
esac
