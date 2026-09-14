#!/bin/sh
# serving.sh <base-url> -- what build is that front serving right now?
#
# Prints the SHA on stdout. Exit 0 it answered, 4 it could not be determined.
#
# WHY THIS IS A FILE AND NOT A LINE. The idiom
#
#   curl -sI --max-time 5 "$URL/" | tr -d '\r' | awk 'tolower($1)=="x-build-sha:"{print $2}'
#
# appears in eight places in this repository, and in all eight the exit status
# belongs to awk. curl failing -- connection refused, DNS, timeout, a 502 --
# produces an empty string and a zero status, so "the front is not answering"
# and "the front answered and named no build" are the same value. That is
# defect class 1, unreachable is not falsified (spec.org, The defect taxonomy),
# eight times over, and class 6 with it: a verdict formatted through a pipe is
# the pipe's verdict.
#
# So: capture, test, THEN format. curl's status is checked before anything is
# parsed, and a caller that gets exit 4 has been told it does not know, rather
# than being handed an empty string it will read as "nothing is deployed".
#
# This is not a gate. It reports what it saw; deciding what that means belongs
# to the caller, because "serving a different build" is correct after a
# rollback and alarming after a cutover.
set -eu
url="${1:?usage: serving.sh <base-url>}"
hdr=$(curl -sS -I --max-time "${SERVING_TIMEOUT:-5}" -H 'Cache-Control: no-cache' "$url/" 2>/dev/null) || {
  echo "  4  $url is not answering -- what it serves cannot be determined" >&2
  exit 4; }
sha=$(printf '%s' "$hdr" | tr -d '\r' | awk 'tolower($1)=="x-build-sha:"{print $2}')
if [ -z "$sha" ]; then
  # It answered, and named no build. Different from unreachable, and still not
  # a SHA: an instrument that cannot identify the build it measured produces no
  # usable observation (spec.org, A verdict must name the build it is about).
  echo "  4  $url answered but set no x-build-sha -- it cannot say what it serves" >&2
  exit 4
fi
printf '%s\n' "$sha"
