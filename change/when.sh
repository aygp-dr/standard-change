#!/bin/sh
# when.sh <phrase> -- a person's time, as ISO 8601 UTC for schedule.sh --at.
#
# Accepts what a person types: "in 2h", "in 45m", "in 3d", "tomorrow 09:00",
# "today 17:30", "2026-09-16 14:00" (local), or an ISO UTC string (echoed).
# Local time is the machine's; the answer is always UTC, because the schedule
# and the forge speak UTC and a window booked in the wrong zone is the kind of
# mistake nobody notices until the reaper does. Exit 2 on anything it cannot
# read, saying so; it never guesses.
set -eu
p="${1:?usage: when.sh <phrase>}"
# a local wall-clock "YYYY-MM-DD HH:MM" -> epoch in the machine's zone -> UTC
local_utc() { e=$(date -j -f '%Y-%m-%d %H:%M' "$1" +%s) && date -u -r "$e" +%Y-%m-%dT%H:%M:00Z; }
case "$p" in
  *T*Z) printf '%s\n' "$p" ;;
  in\ [0-9]*m) n=${p#in }; n=${n%m}; date -u -v+"${n}M" +%Y-%m-%dT%H:%M:00Z ;;
  in\ [0-9]*h) n=${p#in }; n=${n%h}; date -u -v+"${n}H" +%Y-%m-%dT%H:%M:00Z ;;
  in\ [0-9]*d) n=${p#in }; n=${n%d}; date -u -v+"${n}d" +%Y-%m-%dT%H:%M:00Z ;;
  today\ [0-9]*:[0-9]*)    local_utc "$(date +%F) ${p#today }" ;;
  tomorrow\ [0-9]*:[0-9]*) local_utc "$(date -v+1d +%F) ${p#tomorrow }" ;;
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\ [0-9]*:[0-9]*) local_utc "$p" ;;
  *) echo "when.sh: cannot read \"$p\"; say: in 2h | in 45m | in 3d | today 17:30 | tomorrow 09:00 | 2026-09-16 14:00 | 2026-09-16T18:00:00Z" >&2; exit 2 ;;
esac
