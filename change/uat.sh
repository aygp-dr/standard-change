#!/bin/sh
# uat.sh <pr> [url] -- are we still in the deploy window; if so, test staging as UAT.
#
# That sentence is the whole script, and the ORDER in it is the point.
#
# THE LAW. A guard whose subject can change after it is checked must be
# re-checked at the moment it is relied on. The window is the sharpest case:
# preflight checks it before the staging deploy, the deploy takes a minute, the
# smoke walk takes another, and acceptance is recorded after both. Nothing
# re-read the calendar in between -- change/observe.sh and change/guard4.sh do
# not mention the schedule at all. So a change could deploy inside its window,
# spend the window measuring, and record acceptance after the window shut, with
# every guard green.
#
# It happened: #38 deployed at 19:48 into a window closing at 20:30, and the
# acceptance that authorized it was still valid at 20:39 with the window nine
# minutes expired. preflight said NOT ON THE CALENDAR; guard 4 said authorized.
#
# So this checks the window THREE times: before measuring, after measuring, and
# it records only if both agree. A measurement that straddles the close of the
# window is not acceptance inside the window.
#
# WHY SMOKE IS THE INSTRUMENT. docs/control-path.org delegates acceptance to a
# proxy for the grind, granted iff gates/smoke.sh exits 0. That is a DELEGATION
# with a stated condition, not a claim that smoke is user acceptance. The record
# says which it was; the label cannot.
set -eu
cd "$(dirname "$0")/.."
PR="${1:?usage: uat.sh <pr> [staging-url]}"
URL="${2:-http://127.0.0.1:9200}"
R="${GH_REPO:-${GITHUB_REPOSITORY:-aygp-dr/standard-change}}"

HEAD=$(gh pr view "$PR" --repo "$R" --json headRefOid -q .headRefOid)
SHORT=$(echo "$HEAD" | cut -c1-7)

# THE CALENDAR IS ASKED THE WAY PREFLIGHT ASKS IT. change/schedule.sh current
# returns exit 0 for a window whose end has PASSED -- it finds the PR's window
# and does not compare the end to now, which is why it and preflight disagreed
# about #38. Until that is fixed in one place, this reads the window's end and
# compares it here rather than trusting the exit code.
window_open() {
  ev=$(./change/schedule.sh current "$PR" staging 2>/dev/null || true)
  [ -n "$ev" ] || return 1
  end=$(./change/schedule.sh list 2>/dev/null | awk -v e="$ev" '$1==e {print $5}')
  [ -n "$end" ] || return 1
  now=$(date -u +%FT%TZ)
  # RFC3339 in UTC with a fixed Z suffix sorts lexicographically, but POSIX sh
  # leaves `[ a \< b ]` undefined (SC3012) and this runs under /bin/sh on
  # FreeBSD. Compare the digits as an integer instead -- same ordering, defined
  # everywhere, and it cannot silently do something else on another shell.
  [ "$(echo "$now" | tr -dc 0-9)" -lt "$(echo "$end" | tr -dc 0-9)" ] || return 1
  echo "$ev|$end"
}

echo "uat for #$PR @ $SHORT against $URL"

W=$(window_open) || {
  echo "  NO   the deploy window is not open. Acceptance is not recorded." >&2
  echo "       A change outside its window does not get accepted into it." >&2
  echo "       Book one:  ./change/schedule.sh block $PR \"<groups>\" 30" >&2
  exit 7
}
echo "  yes  window ${W%%|*} is open, closes ${W##*|}"

# The build under test must be the build the window is FOR. An acceptance is
# about a build (issue #16) and so is a booking.
SERVING=$(curl -sI --max-time 5 "$URL/" | tr -d '\r' | awk 'tolower($1)=="x-build-sha:"{print $2}')
if [ "$SERVING" != "$SHORT" ]; then
  echo "  NO   staging is serving '${SERVING:-nothing}', not $SHORT." >&2
  echo "       There is nothing here to accept on this change's behalf." >&2
  exit 4
fi
echo "  yes  staging is serving $SHORT"

echo "  ..   walking the estate (gates/smoke.sh)"
if ./gates/smoke.sh "$URL" >/tmp/uat.$$.log 2>&1; then
  RC=0
else
  RC=$?
fi
tail -2 /tmp/uat.$$.log | sed 's/^/       /'
rm -f /tmp/uat.$$.log

[ "$RC" -eq 0 ] || { echo "  NO   smoke exited $RC; the delegation grants acceptance only on 0." >&2; exit 1; }

# RE-CHECK. The measurement took time, and the window may have closed during it.
W2=$(window_open) || {
  echo "  NO   smoke passed, but the window CLOSED while it ran." >&2
  echo "       The measurement is real and the acceptance is not: it would be" >&2
  echo "       recorded outside the window it claims to be inside. Re-book and" >&2
  echo "       re-run -- the estate is fine, the clock is not." >&2
  exit 7
}
echo "  yes  window still open after the walk (${W2##*|})"

./change/observe.sh "$PR" uat --on "$URL"
