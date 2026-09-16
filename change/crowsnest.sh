#!/bin/sh
# crowsnest.sh [--once] -- report what is ACTIVE in the estate as sightings.
#
# POSTs to a crowsnest receiver (https://wal.sh/tools/crowsnest/), the v2.4
# contract: POST :8127/sightings, one object or an array.
#
# TELEMETRY, NOT EVIDENCE. This is the same rule change/marker.sh carries and
# for the same reason: the record of this estate is the forge -- observation
# records that name a build, deployment objects, the PIR. A sighting is a
# convenience for a person watching a board. So:
#
#   - nothing may read a sighting as authorization;
#   - a receiver that is down is REPORTED, never swallowed, and never fails
#     anything that was otherwise succeeding;
#   - this exits 0 on every path, because a dashboard being dark is not a
#     reason to fail a deployment.
#
# WHAT IT REPORTS. Only things that are ACTIVE or WRONG, because a board that
# lists everything is furniture:
#   berth.held        who holds the path, and for how long
#   invariant.fail    each finding from gates/pr-state-audit.py
#   window.open       windows that have not lapsed
#   production.live   the colour and build the FRONT is serving, asked not read
#   estate.flag       freeze or emergency, when set
#
# `run` is the PR number, so every sighting about one change correlates. The
# estate-wide ones use run=estate.
set -eu
cd "$(dirname "$0")/.."
CN="${CROWSNEST_URL:-http://127.0.0.1:8127/sightings}"
R="${GH_REPO:-${GITHUB_REPOSITORY:-aygp-dr/standard-change}}"
HOST=$(hostname -s 2>/dev/null || echo unknown)
NOW_MS=$(( $(date +%s) * 1000 ))
OUT=$(mktemp); trap 'rm -f "$OUT"' EXIT
printf '[' > "$OUT"; SEP=''

# sight <name> <status> <duration_ms> <run> <state> <attrs-json>
sight() {
  printf '%s{"name":"%s","service":"slipway","start":%s,"duration":%s,"status":"%s","run":"%s","state":"%s","attrs":%s}' \
    "$SEP" "$1" "$NOW_MS" "$3" "$2" "$4" "$5" "$6" >> "$OUT"
  SEP=','
}

# --- the berth -------------------------------------------------------------
lock=$(./change/lock.sh status 2>/dev/null || true)
held=$(printf '%s' "$lock" | awk '$1=="pr:"{print $2}')
since=$(printf '%s' "$lock" | awk '$1=="started_at:"{print $2}')
if [ -n "${held:-}" ]; then
  held_ms=0
  [ -n "${since:-}" ] && held_ms=$(( NOW_MS - $(date -j -f %Y-%m-%dT%H:%M:%SZ "$since" +%s 2>/dev/null || echo $(( NOW_MS/1000 )) ) * 1000 ))
  [ "$held_ms" -lt 0 ] && held_ms=0
  sight berth.held ok "$held_ms" "$held" "held by #$held since ${since:-unknown}" \
    "{\"host\":\"$HOST\",\"pr\":$held}"
else
  sight berth.free ok 0 estate "nobody holds the path to production" "{\"host\":\"$HOST\"}"
fi

# --- the invariants --------------------------------------------------------
# The audit exits 1 when it FINDS something. That is its verdict, not a failure
# to produce one -- the dashboard made exactly that mistake. Keep the output.
inv=$(python3 gates/pr-state-audit.py --json 2>/dev/null || true)
if [ -z "$inv" ]; then
  sight invariant.unknown unknown 0 estate "the audit did not run -- this is an UNREAD estate, not a clean one" \
    "{\"host\":\"$HOST\"}"
else
  n=$(printf '%s' "$inv" | python3 -c 'import json,sys;print(len(json.load(sys.stdin).get("findings",[])))' 2>/dev/null || echo 0)
  if [ "${n:-0}" = 0 ]; then
    sight invariant.clean ok 0 estate "all five invariants hold" "{\"host\":\"$HOST\"}"
  else
    printf '%s' "$inv" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for f in d.get("findings",[]):
    prs=",".join(str(x) for x in f.get("prs",[]))
    print(f["kind"]+"\t"+f["detail"].replace("\t"," ")+"\t"+prs)
' 2>/dev/null | while IFS="$(printf '\t')" read -r kind detail prs; do
      sight "invariant.fail" error 0 "${prs%%,*}" "$kind: $detail" \
        "{\"host\":\"$HOST\",\"prs\":\"$prs\"}"
    done
  fi
fi

# --- production, asked of the FRONT ---------------------------------------
st=$(./targets/node/switch.sh status 2>/dev/null || true)
col=$(printf '%s' "$st" | awk '{print $3}'); sha=$(printf '%s' "$st" | awk '{print $5}')
if [ -n "${sha:-}" ]; then
  sight production.live ok 0 estate "$col serving $sha" \
    "{\"host\":\"$HOST\",\"sha\":\"$sha\",\"colour\":\"$col\"}"
else
  sight production.live unknown 0 estate "the front did not answer" "{\"host\":\"$HOST\"}"
fi

# --- estate flags ----------------------------------------------------------
flags=$(gh issue view 1 --repo "$R" --json labels -q '[.labels[].name]|join(" ")' 2>/dev/null || echo UNREADABLE)
case " $flags " in
  *UNREADABLE*) sight estate.flag unknown 0 estate "could not read the holder issue" "{\"host\":\"$HOST\"}" ;;
  *" freeze "*|*" emergency "*) sight estate.flag error 0 estate "estate closed: $flags" "{\"host\":\"$HOST\"}" ;;
esac
printf ']' >> "$OUT"

code=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' -X POST \
         -H 'Content-Type: application/json' --data-binary @"$OUT" "$CN" 2>/dev/null || true)
case "$code" in
  20*) echo "  crowsnest: $(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$OUT" 2>/dev/null || echo '?') sighting(s) -> $CN" ;;
  400) echo "  crowsnest REFUSED the payload (400). A sighting with a non-finite number is rejected on ingest." >&2 ;;
  ""|000) echo "  crowsnest NOT REPORTED: $CN unreachable. The estate is unchanged; only the board is dark." >&2 ;;
  *)   echo "  crowsnest NOT REPORTED: receiver returned $code. The estate is unchanged." >&2 ;;
esac
exit 0
