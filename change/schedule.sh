#!/bin/sh
# schedule.sh -- the change schedule. Windows, freezes, and what happened.
#
# spec.org §Change schedule specifies a Google Calendar event per window. The
# calendar identity was an open item and this script was named as its trigger;
# it is resolved here in the other direction. The schedule is stored the way the
# rest of the IDP state is stored -- a CAS-guarded git ref (change/state.sh) --
# and a calendar becomes an EXPORTER of that store rather than its home.
#
# Why, plainly: a calendar is last-write-wins. Two agents booking the same slot
# both get an event and neither is told. That is the same failure the IDP state
# store exists to prevent, and the change schedule is the one place where it
# matters most, because the thing being double-booked is the path to
# production. Compare-and-swap first, human-readable calendar second.
#
#   block <pr> <groups> <minutes>   reserve a window   -> .change-event-id
#   check <event-id|START/END>      freezes/emergencies overlapping it
#   close <event-id> <result>       record what happened
#   list [--open]                   the schedule
#
# RESERVING IS NOT DEPLOYING. Every guard checked at booking is stale when the
# window opens; `check` is what activation re-runs. See the skill.
set -eu
cd "$(dirname "$0")/.."

REF="${SCHEDULE_REF:-refs/idp/schedule}"
QUANTUM="${SCHEDULE_QUANTUM:-30}"       # minutes; the calendar's slot size
repo="${GH_REPO:-${GITHUB_REPOSITORY:-aygp-dr/standard-change}}"

now() { date -u +%FT%TZ; }

read_sched() {
  old=$(git rev-parse --verify --quiet "$REF" || true)
  if [ -n "$old" ]; then
    printf '{"sha":"%s","body":%s}' "$old" "$(git cat-file -p "$old" | jq -Rs .)"
  else
    printf '{"sha":"","body":"{\\"windows\\":[],\\"freezes\\":[]}"}'
  fi
}

write_sched() {  # write_sched <expected-sha> <body>
  _blob=$(printf '%s' "$2" | git hash-object -w --stdin)
  git update-ref "$REF" "$_blob" "${1:-}" 2>/dev/null \
    || { echo "CAS conflict: the schedule changed under us" >&2; exit 9; }
}

# The window for a change starting now, on quantum boundaries.
#
# START is the slot you are already in -- "now" should mean now, and a calendar
# shows the slot, not an arbitrary second. END is the first boundary that
# leaves at least <minutes> of window REMAINING from this moment.
#
# The naive version -- end = start + minutes -- was wrong, and booking #9 at
# :58 is what showed it: it handed back a window with ninety seconds left in
# it, because time already elapsed inside the slot was silently spent out of
# the change's budget. A window that cannot hold the work is not a reservation,
# it is a reservation-shaped object that expires mid-deploy. A change starting
# now and running thirty minutes occupies two calendar slots; that is what a
# calendar would show a person, so it is what this records.
# THE QUEUE. slot() used to answer only "the slot containing now", so a booking
# either got the berth immediately or was refused -- there was no way to say
# "after the one in front of me". Stacking ten approved changes meant waiting at
# a terminal for each window to close.
#
# `after` is the earliest start to consider. With it, this returns the first
# aligned slot at or after that time, so the caller can walk the reservations it
# already knows about and place itself behind the last one. The clash check in
# `block` is unchanged and still authoritative: this proposes, that disposes.
slot() {  # slot <minutes> [after-iso]
  python3 - "$QUANTUM" "$1" "${2:-}" <<'SLOT'
import datetime, math, sys
q, mins = int(sys.argv[1]), int(sys.argv[2])
after = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else ''
now = datetime.datetime.now(datetime.timezone.utc).replace(second=0, microsecond=0)
if after:
    t = datetime.datetime.strptime(after, '%Y-%m-%dT%H:%M:%SZ').replace(
        tzinfo=datetime.timezone.utc)
    # Never propose a slot in the past: a reservation that has already expired
    # is not a booking, and handing one back would look like success.
    now = max(now, t)
start = now.replace(minute=(now.minute // q) * q)
if start < now:
    start += datetime.timedelta(minutes=q)
    now = start
elapsed = (now - start).total_seconds() / 60
slots = math.ceil((elapsed + mins) / q)          # >= mins remaining, on a boundary
print(start.strftime('%Y-%m-%dT%H:%M:%SZ'))
print((start + datetime.timedelta(minutes=slots * q)).strftime('%Y-%m-%dT%H:%M:%SZ'))
SLOT
}

case "${1:-}" in
  # block <pr> <groups> <minutes> -- reserve a window for this change.
  block)
    pr="${2:?usage: schedule.sh block <pr> <groups> <minutes> [--at <iso8601-utc>]}"
    groups="${3:-}"; mins="${4:-$QUANTUM}"
    # A DESIGNATED BLOCK. Until now every booking was relative -- now, or behind
    # whatever is already queued -- so "the Tuesday 19:00 release slot", which is
    # how a change calendar is actually used, could not be expressed at all.
    #
    # --at names the start. It does NOT relax the clash check: a designated slot
    # that collides with an existing reservation is still refused, because two
    # changes holding one path to production is the thing the calendar exists to
    # prevent, and wanting a particular hour does not change that.
    AT=''
    shift 4 2>/dev/null || shift $#
    while [ $# -gt 0 ]; do
      case "$1" in
        --at) AT="${2:?--at needs an ISO 8601 UTC time, e.g. 2026-09-13T23:00:00Z}"; shift 2 ;;
        *)    echo "refused: unknown argument '$1'" >&2; exit 2 ;;
      esac
    done
    [ -n "$groups" ] || { echo "refused: no groups — nothing to deploy" >&2; exit 2; }

    # Walk to the back of the queue. Ask for a slot after the latest END among
    # the OPEN reservations on this environment -- an unresolved window is one
    # somebody is still entitled to, whether or not its clock has run out.
    # Without `--now` this never refuses for a clash; it places itself behind
    # whatever is already booked.
    st0=$(read_sched); cur0=$(echo "$st0" | jq -r .body)
    after=''
    if [ -n "$AT" ]; then
      # Refuse a designated slot that has already passed. Booking into the past
      # is never what was meant, and it would hand back a reservation the reaper
      # closes on its next sweep -- success-shaped and immediately worthless.
      _nown=$(now | tr -dc 0-9); _atn=$(echo "$AT" | tr -dc 0-9)
      if [ "${#_atn}" -lt 14 ]; then
        echo "refused: --at wants ISO 8601 UTC, e.g. 2026-09-13T23:00:00Z" >&2; exit 2
      fi
      if [ "$_atn" -lt "$_nown" ]; then
        echo "refused: $AT is in the past (now $(now))." >&2
        echo "  A booking behind the clock is closed by the next reap." >&2
        exit 2
      fi
      after="$AT"
    elif [ "${QUEUE:-1}" = 1 ]; then
      after=$(echo "$cur0" | jq -r --arg env "${CHANGE_ENV:-staging}" \
        '[.windows[]|select(.env==$env and .result==null)|.end]|max // empty')
    fi
    # shellcheck disable=SC2046  # the split IS the point: slot() prints two fields
    set -- $(slot "$mins" "$after"); start="$1"; end="$2"
    env="${CHANGE_ENV:-staging}"
    sha=$(gh pr view "$pr" --repo "$repo" --json headRefOid -q '.headRefOid' | cut -c1-7)
    url=$(gh pr view "$pr" --repo "$repo" --json url -q '.url')
    st=$(read_sched); old=$(echo "$st" | jq -r .sha); cur=$(echo "$st" | jq -r .body)

    # The id must be unique, and slot+pr is not: cancelling a booking and
    # rebooking it in the same slot -- which is exactly what a rejected window
    # leads to -- minted the same id twice, and `close` then resolved BOTH,
    # rewriting a cancelled window's history. Sequence within the slot.
    base="CHG-$(echo "$start" | tr -d ':-' | cut -c1-13)-$pr"
    n=$(echo "$cur" | jq --arg b "$base" '[.windows[]|select(.id|startswith($b))]|length + 1')
    id="$base.$n"

    # One environment, one window at a time. The calendar IS the berth here:
    # an overlapping booking on the same environment is a double-booked path to
    # production, and catching it at reservation is the cheap place to catch it.
    # Any OPEN window overlapping this one on this environment refuses, including
    # one held by the same PR. Excluding self let #9 book staging twice in the
    # same slot -- a double-booked path to production where both bookings were
    # the same change, which is not better. A cancelled or closed window does
    # not clash (result != null), so rebooking after a refusal still works.
    clash=$(echo "$cur" | jq -r --arg s "$start" --arg e "$end" --arg env "$env" \
      '[.windows[] | select(.env==$env and .result==null
                            and .start < $e and .end > $s)] | first | .id // empty')
    [ -z "$clash" ] || { echo "refused: $env is booked by $clash over $start..$end" >&2; exit 5; }

    new=$(echo "$cur" | jq --arg id "$id" --argjson pr "$pr" --arg g "$groups" \
      --arg env "$env" --arg s "$start" --arg e "$end" --arg sha "$sha" \
      --arg url "$url" --arg t "$(now)" \
      '.windows += [{id:$id, pr:$pr, groups:$g, env:$env, start:$s, end:$e,
                     sha:$sha, url:$url, booked_at:$t, result:null}]')
    write_sched "$old" "$new"
    printf '%s' "$id" > .change-event-id

    # THE CHANGE RECORD MOVES TO SCHEDULED. label-owners.tsv has declared
    # `change:scheduled` with owner `scheduler` and the note "set when a window
    # is booked" since the beginning, and nothing wrote it: nine booked changes
    # carried no lifecycle label at all, so "is this scheduled?" could only be
    # answered by reading the calendar. A declared label nobody writes is a
    # documented intention, not a state.
    #
    # ITIL 4: assessed and authorized -> SCHEDULED is the transition a booking
    # makes. The lifecycle group is <=1 active, so change:requested comes off --
    # the ask has been answered. CLEARING a human-owned label is allowed where
    # asserting it is not (docs/label-ownership.org: adding and removing are
    # different acts); the scheduler may answer an ask, it may not invent one.
    gh pr edit "$pr" --repo "$repo" \
      --add-label change:scheduled --remove-label change:requested >/dev/null 2>&1 || true

    echo "$id  $env  $start .. $end  pr=#$pr groups=$groups sha=$sha"
    ;;

  # check <event-id|START/END> -- what would refuse this window.
  #
  # Called at ACTIVATION, not at booking. A freeze declared after you booked is
  # exactly the case this exists for: the subject of the check can change after
  # the check, so it is re-run at the moment it is relied on.
  # windows <pr> [env] -- every OPEN window this change holds.
  #
  # `current` answers "does a window cover NOW", which is what the guards ask
  # and is deliberately narrow. It cannot see a FUTURE booking, so rescheduling
  # had no way to find the reservation it was replacing: #42 and #44 each ended
  # up holding two open windows, double-booking the berth against themselves.
  # The clash check did not catch it and should not have -- the windows did not
  # overlap. One change holding two slots is a different mistake, and nothing
  # could see it because nothing could ask this question.
  windows)
    _pr="${2:?usage: schedule.sh windows <pr> [env]}"
    _env="${3:-}"
    _st=$(read_sched); _cur=$(echo "$_st" | jq -r .body)
    echo "$_cur" | jq -r --argjson pr "$_pr" --arg env "$_env" \
      '.windows[] | select(.pr==$pr and .result==null)
                  | select($env=="" or .env==$env)
                  | "  \(.id)  \(.env)  \(.start) .. \(.end)  \(.sha)"'
    ;;


  check)
    arg="${2:?usage: schedule.sh check <event-id|START/END>}"
    cur=$(read_sched | jq -r .body)
    case "$arg" in
      */*) start="${arg%%/*}"; end="${arg##*/}" ;;
      *)   start=$(echo "$cur" | jq -r --arg i "$arg" '.windows[]|select(.id==$i)|.start')
           end=$(echo "$cur"   | jq -r --arg i "$arg" '.windows[]|select(.id==$i)|.end')
           [ -n "$start" ] || { echo "no such window: $arg" >&2; exit 2; } ;;
    esac
    echo "$cur" | jq -r --arg s "$start" --arg e "$end" \
      '[.freezes[] | select(.start < $e and .end > $s)] as $f
       | if ($f|length) == 0 then "clear  \($s) .. \($e)"
         else ($f[] | "FREEZE \(.start) .. \(.end)  \(.reason)") end'
    # exit 3 is preflight's freeze code; keep the same meaning here.
    n=$(echo "$cur" | jq --arg s "$start" --arg e "$end" \
          '[.freezes[]|select(.start < $e and .end > $s)]|length')
    [ "$n" -eq 0 ] || exit 3
    ;;

  # close <event-id> <result> -- what actually happened in the window.
  close)
    id="${2:?usage: schedule.sh close <event-id> <result>}"; result="${3:?}"
    st=$(read_sched); old=$(echo "$st" | jq -r .sha); cur=$(echo "$st" | jq -r .body)
    echo "$cur" | jq -e --arg i "$id" '[.windows[]|select(.id==$i)]|length > 0' >/dev/null \
      || { echo "no such window: $id" >&2; exit 2; }
    new=$(echo "$cur" | jq --arg i "$id" --arg r "$result" --arg t "$(now)" \
      '.windows |= map(if .id == $i then .result = $r | .closed_at = $t else . end)')
    write_sched "$old" "$new"
    echo "$id closed: $result"
    ;;

  # freeze <start> <end> <reason> -- a period nothing deploys in.
  freeze)
    s="${2:?usage: schedule.sh freeze <start> <end> <reason>}"; e="${3:?}"; r="${4:-change freeze}"
    st=$(read_sched); old=$(echo "$st" | jq -r .sha); cur=$(echo "$st" | jq -r .body)
    write_sched "$old" "$(echo "$cur" | jq --arg s "$s" --arg e "$e" --arg r "$r" \
      '.freezes += [{start:$s, end:$e, reason:$r}]')"
    echo "freeze $s .. $e  $r"
    ;;

  list)
    cur=$(read_sched | jq -r .body)
    if [ "${2:-}" = "--open" ]; then
      echo "$cur" | jq -r '.windows[]|select(.result==null)
        | "  \(.id)  \(.env)  \(.start) .. \(.end)  #\(.pr) \(.groups) \(.sha)"'
    else
      echo "$cur" | jq -r '.windows[]
        | "  \(.id)  \(.env)  \(.start) .. \(.end)  #\(.pr) \(.groups) \(.sha)  \(.result // "open")"'
      echo "$cur" | jq -r '.freezes[]|"  FREEZE \(.start) .. \(.end)  \(.reason)"'
    fi
    ;;

  # current <pr> [env] -- the open window covering NOW for this change, if any.
  # Prints the event id and exits 0; exits 1 with nothing when there is none.
  # This is what activation asks. It deliberately cannot book one.
  current)
    pr="${2:?usage: schedule.sh current <pr> [env]}"; env="${3:-${CHANGE_ENV:-staging}}"
    id=$(read_sched | jq -r .body | jq -r --argjson pr "$pr" --arg env "$env" --arg t "$(now)" \
      '[.windows[] | select(.pr==$pr and .env==$env and .result==null
                            and .start <= $t and .end > $t)] | first | .id // empty')
    [ -n "$id" ] || exit 1
    echo "$id"
    ;;

  show) read_sched | jq -r .body | jq . ;;

  *) echo "usage: schedule.sh {block <pr> <groups> <min>|check <id>|close <id> <result>|freeze <s> <e> <reason>|list [--open]|show}" >&2; exit 2 ;;
esac
