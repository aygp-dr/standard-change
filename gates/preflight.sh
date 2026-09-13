#!/bin/sh
# preflight.sh <pr> [env] -- say out loud what a person would check before deploying.
#
# Referenced by .github/workflows/deploy-staging.yml since the spec was written
# and never existed until now. Exit codes are the ones the spec assigned:
#   0 proceed   2 lock held   3 freeze   4 calendar unreachable   5 queue busy
# 4 BLOCKS. "I could not read the calendar" is not "the calendar is clear" --
# the same rule as docs/label-ownership.org: unreachable is not falsified.
#
# It is deliberately VERBOSE. ADR 0001 Option 0 says a person still confirms the
# things a machine cannot judge, and a person cannot confirm a list they have
# not been shown. Each line is phrased as the thing you would actually say to
# yourself, so that reading it is the check rather than a receipt for one.
set -eu
cd "$(dirname "$0")/.."
pr="${1:?usage: preflight.sh <pr> [env]}"
env="${2:-staging}"
R="${GH_REPO:-${GITHUB_REPOSITORY:-aygp-dr/standard-change}}"
rc=0
yes()  { printf '  \033[32m yes \033[0m %s\n' "$1"; }
no()   { printf '  \033[31m NO  \033[0m %s\n' "$1"; rc=${2:-1}; }
note() { printf '        %s\n' "$1"; }

head=$(gh pr view "$pr" --repo "$R" --json headRefOid -q .headRefOid)
short=$(echo "$head" | cut -c1-7)
labels=$(gh pr view "$pr" --repo "$R" --json labels -q '[.labels[].name]|join(" ")')
groups=$(./change/groups.sh "$pr" 2>/dev/null || true)

printf '\npreflight for #%s -> %s, at build %s\n\n' "$pr" "$env" "$short"

# --- am I on the calendar? -----------------------------------------------
if win=$(./change/schedule.sh current "$pr" "$env" 2>/dev/null); then
  yes "I'm on the calendar — window $win is open and covers right now"
else
  if ./change/schedule.sh list >/dev/null 2>&1; then
    no "I am NOT on the calendar. No open window for #$pr on $env covers now." 4
    note "book one:  ./change/schedule.sh block $pr \"$groups\" 30"
  else
    no "I could not READ the calendar, which is not the same as it being clear." 4
    note "exit 4 blocks. An unreadable schedule is an unknown, not a yes."
  fi
fi

# --- do the gates pass for this exact build? -----------------------------
bad=$(gh api "repos/$R/commits/$head/check-runs" \
       --jq '[.check_runs[]|select(.name|test("^(gate-selftest|lint|test|e2e)$"))|select(.conclusion!="success")]|length' 2>/dev/null || echo 99)
self=$(gh api "repos/$R/commits/$head/check-runs" \
       --jq '[.check_runs[]|select(.name=="gate-selftest")|select(.conclusion=="success")]|length' 2>/dev/null || echo 0)
if [ "$bad" = 99 ]; then
  no "I could not reach the forge to read the check runs." 4
elif [ "$bad" -eq 0 ] && [ "$self" -ge 1 ]; then
  yes "lint and the tests pass — on THIS head, $short, not on an earlier one"
  note "gate-selftest passed too, so those results are worth something:"
  note "a gate that cannot reject its own fail fixture produces no verdict."
else
  no "the gates are not green on $short ($bad not passing, self-test $self)"
fi

# --- is anyone else in staging? ------------------------------------------
holder=$(gh pr list --repo "$R" --state open --label deploy:staging \
          --json number -q "[.[].number]|map(select(. != $pr))|first // empty" 2>/dev/null || echo "?")
if [ "$holder" = "?" ]; then
  no "I could not check who holds the berth." 4
elif [ -z "$holder" ]; then
  yes "nobody else is in staging — the berth is free"
else
  no "someone else IS in staging: #$holder holds the berth" 5
  note "one path to production, one change at a time. Wait, or ask them."
fi

# --- is an emergency or a freeze in front of me? -------------------------
emg=$(gh pr list --repo "$R" --state open --label change:emergency \
       --json number -q "[.[].number]|map(select(. != $pr))|join(\", \")" 2>/dev/null || echo "?")
if [ "$emg" = "?" ]; then
  no "I could not check for emergencies in flight." 4
elif [ -z "$emg" ]; then
  yes "there is no emergency in flight ahead of me"
else
  no "an emergency is in flight: #$emg" 2
  note "it may land under you and invalidate your staging pass (guard 4b)."
fi

if [ -n "${win:-}" ] && ./change/schedule.sh check "$win" >/dev/null 2>&1; then
  yes "there is no change freeze over my window"
elif [ -n "${win:-}" ]; then
  no "a change FREEZE covers my window" 3
  ./change/schedule.sh check "$win" 2>&1 | sed 's/^/        /'
fi

# --- is a person holding this deliberately? ------------------------------
case " $labels " in
  *" hold:staging "*)
    no "a person put hold:staging on this — they want to look before it promotes" 2
    note "only a person may remove it. That is what makes it a hold." ;;
  *) yes "nobody has put a hold on this change" ;;
esac

# --- what am I actually about to move? -----------------------------------
printf '\n'
if [ -n "$groups" ]; then
  note "this deploys: $groups"
  n=$(printf '%s' "$groups" | wc -w | tr -d ' ')
  [ "$n" -gt 1 ] && note "$n apps at once — larger blast radius than a single-app change"
else
  note "this deploys NOTHING — no app:* label. Check that is what you meant."
fi
note "labels: $labels"

printf '\n'
if [ "$rc" = 0 ]; then printf '  \033[32mproceed\033[0m\n\n'
else printf '  \033[31mdo not proceed\033[0m (exit %s)\n\n' "$rc"; fi
exit "$rc"
