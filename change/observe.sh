#!/bin/sh
# observe.sh <pr> uat [--on <url>] -- record a HUMAN observation.
#
# The standing rule is that a person never adds an observation label, because
# doing so asserts a measurement nobody took. UAT is the exception that shows
# the rule was stated too broadly: the correct rule is
#
#   an observation label may be added by the INSTRUMENT that took the
#   measurement, and for user acceptance the instrument is a person.
#
# So this exists, it is the only human-added observation, and it records what
# was looked at -- because "someone said it was fine" is not evidence unless it
# says fine *where*, on *which build*.
set -eu
pr="${1:?usage: observe.sh <pr> uat [--on <url>]}"
kind="${2:?}"
shift 2
url="http://127.0.0.1:9200"
[ "${1:-}" = "--on" ] && { url="$2"; shift 2; }
repo="${GH_REPO:-${GITHUB_REPOSITORY:-aygp-dr/standard-change}}"
[ "$kind" = uat ] || { echo "only 'uat' may be recorded by a person" >&2; exit 2; }

sha=$(curl -sI --max-time 5 "$url/" | tr -d '\r' | awk 'tolower($1)=="x-build-sha:"{print $2}')
[ -n "$sha" ] || { echo "refused: $url is not serving a build -- nothing to accept" >&2; exit 3; }
head=$(gh pr view "$pr" --repo "$repo" --json headRefOid -q .headRefOid | cut -c1-7)

# The build a person looked at must be the build under review. Accepting a
# different one is the two-estate mistake with a human in the loop.
[ "$sha" = "$head" ] || {
  echo "refused: $url serves $sha but #$pr is $head -- you accepted a different build" >&2
  exit 4; }

gh pr edit "$pr" --repo "$repo" --add-label staging:uat >/dev/null
gh pr comment "$pr" --repo "$repo" --body \
  "\`staging:uat\` — a person used **$url** on build \`$sha\` and accepted it.

Recorded by \`change/observe.sh\`, which checked that the build served there is the head of this PR. The only observation label a human may add: for user acceptance, the person *is* the instrument." >/dev/null
echo "  #$pr <- staging:uat  (a person accepted $sha on $url)"
