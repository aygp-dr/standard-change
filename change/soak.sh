#!/bin/sh
# soak.sh <pr> <seconds> [url] -- hold a staging deploy before promoting it.
#
# WHY A HOLD AT ALL. Everything upstream of this is a point measurement: the
# gates ran once, e2e walked once, smoke walked once. All of them pass against a
# process that has been alive for four seconds and will fall over in ninety --
# a leak, a handle exhaustion, a timer that fires late, an upstream that drops
# the connection after its first keep-alive. Production finds those; staging is
# where they are cheap.
#
# So the change is held, and the estate is re-asked THROUGHOUT the hold rather
# than at the end of it. A single probe after five minutes proves the estate is
# up now, which is the same thing the deploy already proved. Probing all the way
# through is what makes the five minutes mean anything.
#
# WHAT A FAILURE MEANS. It does not go to production and it does not merge. The
# change goes to the BACK OF THE QUEUE -- it is not dead, it is not next.
set -eu
cd "$(dirname "$0")/.."
PR="${1:?usage: soak.sh <pr> <seconds> [url]}"
SECS="${2:?seconds}"
URL="${3:-http://127.0.0.1:9200}"
R="${GH_REPO:-${GITHUB_REPOSITORY:-aygp-dr/standard-change}}"
INTERVAL="${SOAK_INTERVAL:-15}"

HEAD=$(gh pr view "$PR" --repo "$R" --json headRefOid -q .headRefOid)
SHORT=$(echo "$HEAD" | cut -c1-7)

echo "soak #$PR @ $SHORT on $URL for ${SECS}s, probing every ${INTERVAL}s"

n=0; bad=0; elapsed=0
while [ "$elapsed" -lt "$SECS" ]; do
  n=$((n + 1))
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$URL/" 2>/dev/null || echo 000)
  sha=$(curl -sI --max-time 5 "$URL/" 2>/dev/null | tr -d '\r' \
        | awk 'tolower($1)=="x-build-sha:"{print $2}')
  # BOTH conditions. A 200 from the PREVIOUS build is not this change surviving
  # the soak -- it is the estate surviving without it, which is the failure the
  # blue/green front makes easiest to miss.
  if [ "$code" = 200 ] && [ "$sha" = "$SHORT" ]; then
    printf '.'
  else
    printf '\n  probe %d at %ds: HTTP %s sha=%s (want 200 %s)\n' \
      "$n" "$elapsed" "$code" "${sha:-none}" "$SHORT"
    bad=$((bad + 1))
  fi
  sleep "$INTERVAL"
  elapsed=$((elapsed + INTERVAL))
done
echo

if [ "$bad" -gt 0 ]; then
  echo "  SOAK FAILED: $bad of $n probes did not serve $SHORT healthily." >&2
  echo "  Not promoting, not merging. This change goes to the back of the queue." >&2
  exit 1
fi
echo "  soak passed: $n/$n probes served $SHORT over ${SECS}s"
