#!/bin/sh
# marker.sh <pr> [front-url] -- emit a deployment marker, AFTER the release is
# complete. Called from the tail of change/settle.sh; safe to run by hand.
#
# IT ASKS, IT IS NOT TOLD. The build and the colour are read from the front at
# the moment the marker is sent. The first five markers sent by hand were
# composed from "whatever production is serving right now" while naming five
# different PRs, so four of them claimed a build that was not theirs. A marker
# that is HANDED a build inherits whatever mistake the caller made; one that
# asks can only be wrong about the instant it asked, which it also records.
#
# IDENTITY GOES IN `event`, AND IT MUST FIT IN FIFTY BYTES. The beacon's schema
# declares exactly two properties, `source` and `event`, and silently discards
# everything else -- pr, build, env and colour were all dropped on the first
# five markers. So the identity is packed into the one field that survives.
#
# And that field is TRUNCATED AT 50 CHARACTERS, silently. Measured by sending
# 40/48/50/56/64 bytes and reading back what was kept, because the schema does
# not say so: the first attempt at this fix emitted
# "deployment pr=69 env=production build=0b23ee1 colour=blue at=..." and what
# survived was "...build=0b23ee1 colo" -- cut mid-word, colour and timestamp
# gone. Assuming a field holds what you put in it is the same defect as
# assuming a gate ran; both are fixed by reading the value back.
#
# So the event is built SHORT, and the length is asserted before sending. A
# marker that would be truncated is not sent silently -- truncation is how a
# build identifier turns into a different build identifier.
#
# TELEMETRY IS NOT EVIDENCE, and this is the one place in this repo where a
# failed write is not fatal. The record of a deployment is the PIR comment and
# the forge deployment object, both written before this runs. A marker is a
# convenience for a dashboard. So a marker that cannot be sent is REPORTED --
# never silently swallowed -- and does not fail a release that already
# succeeded. Nothing downstream may read a marker as authorization.
set -eu
cd "$(dirname "$0")/.."
pr="${1:?usage: marker.sh <pr> [front-url]}"
front="${2:-${MARKER_FRONT:-http://127.0.0.1:9230}}"
beacon="${MARKER_BEACON:-http://127.0.0.1:7510/webhook}"

hdr() { curl -sI --max-time 5 "$front/" 2>/dev/null | tr -d '\r' \
          | awk -v k="$1" 'tolower($1)==k{print $2}'; }
build=$(hdr 'x-build-sha:')
colour=$(hdr 'x-colour:')

# An unreachable front is not a build of "unknown". Say which one it is: the
# marker still goes, and it says the estate could not be observed rather than
# inventing a value -- unreachable is not falsified.
# Short by construction: pr and build are the two facts a marker exists to
# carry, so they go first and nothing optional is allowed to push them out.
# The timestamp is NOT included -- the beacon stamps its own `ts` on arrival,
# and spending twenty of fifty bytes to restate it worse is how the build got
# truncated the first time.
if [ -z "${build:-}" ]; then
  event="deploy pr=$pr prod b=UNOBSERVED front-unreachable"
else
  event="deploy pr=$pr prod b=$build ${colour:-?}"
fi

# THE LENGTH IS A GUARD, not a formatting nicety. A truncated build identifier
# is a DIFFERENT build identifier, and it would be recorded as fact.
if [ "${#event}" -gt 50 ]; then
  echo "  MARKER NOT SENT: event is ${#event} chars and the beacon keeps 50;" >&2
  echo "  it would truncate to '$(printf '%.50s' "$event")'." >&2
  echo "  A truncated build is a different build. The release stands." >&2
  exit 0
fi

body=$(printf '{"source":"standard-change","event":"%s"}' "$event")
# No `|| echo 000` here: curl ALREADY writes 000 to stdout on a connection
# failure, so the fallback concatenated onto it and reported "000000" -- a
# status code that does not exist, in the branch that handles being unable to
# reach anything. `|| true` keeps set -e from firing without adding output.
code=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' -X POST \
         -H 'Content-Type: application/json' -d "$body" "$beacon" 2>/dev/null || true)
case "$code" in
  20*) echo "  marker sent: $event" ;;
  429) echo "  MARKER NOT SENT: rate limited (429). The release stands; only the marker is missing." >&2 ;;
  000) echo "  MARKER NOT SENT: $beacon unreachable. The release stands; only the marker is missing." >&2 ;;
  *)   echo "  MARKER NOT SENT: beacon returned $code. The release stands; only the marker is missing." >&2 ;;
esac
exit 0
