#!/bin/sh
# reap.sh [--dry-run] -- close windows whose time has passed.
#
# WHY THIS HAS TO EXIST. Nothing resolves a window. `close` is called on the
# success path by settle.sh and on the failure path by abort.sh, and both are
# reached only by a change somebody is actively driving. A window whose change
# was never driven just sits there, unresolved, forever.
#
# That is not cosmetic. `schedule.sh current` returns exit 0 for an expired
# window, so a stale reservation keeps answering "yes, you have a window" long
# after it closed -- which is how #38 reached guard 4 authorized at 20:39 with
# a window that ended at 20:30. And `block` places new reservations after the
# latest END among OPEN windows, so one un-reaped lapse pushes the whole queue
# out behind a window nobody is using.
#
# EXPIRED IS ITS OWN CLOSURE CODE. It is not `failed` -- nothing was attempted,
# so there is nothing that failed. It is not `cancelled` -- nobody decided
# against it. The reservation simply lapsed, and that is a fact about the
# schedule rather than about the change. The change itself is untouched and
# still eligible; it needs a new window, and BOOKING ONE IS NOT THIS SCRIPT'S
# JOB. A reaper that rebooks is a scheduler nobody asked for, and it would hide
# exactly the signal worth seeing: that the slots are too short for the work.
set -eu
cd "$(dirname "$0")/.."
DRY=''
[ "${1:-}" = "--dry-run" ] && DRY=1
R="${GH_REPO:-${GITHUB_REPOSITORY:-aygp-dr/standard-change}}"
NOW=$(date -u +%FT%TZ)
NOWN=$(echo "$NOW" | tr -dc 0-9)

n=0
ONLY="${CHANGE_ENV:-}"
./change/schedule.sh list --open 2>/dev/null | while read -r id env start _ end rest; do
  [ -n "$id" ] || continue
  # Scope by environment when asked. Unset means every environment, which is
  # what a coordinator sweeping the whole schedule wants; CHANGE_ENV=staging
  # reaps only staging. The field was being parsed and thrown away, which is
  # how a reaper ends up closing a production window during a staging sweep.
  [ -z "$ONLY" ] || [ "$env" = "$ONLY" ] || continue
  endn=$(echo "$end" | tr -dc 0-9)
  [ "$endn" -lt "$NOWN" ] || continue        # still running, or not yet started
  pr=$(echo "$rest" | awk '{print $1}' | tr -d '#')
  n=$((n + 1))
  printf '  %-28s #%-4s %s .. %s  LAPSED\n' "$id" "$pr" "$start" "$end"

  # THE BERTH IS THE PART THAT HURTS. A window can lapse having already claimed
  # staging, and deploy:staging is cleared by settle.sh -- which that change
  # will never reach. Left alone it blocks every subsequent change with guard 1
  # while its own window is gone, which is a deadlock with no declared cause.
  held=$(gh pr view "$pr" --repo "$R" --json labels \
           -q '[.labels[].name]|index("deploy:staging") // empty' 2>/dev/null || echo '')
  if [ -n "$DRY" ]; then
    [ -n "$held" ] && echo "      would also release deploy:staging from #$pr"
    continue
  fi
  ./change/schedule.sh close "$id" expired >/dev/null 2>&1 \
    && echo "      window closed: expired"
  if [ -n "$held" ]; then
    gh pr edit "$pr" --repo "$R" --remove-label deploy:staging >/dev/null 2>&1 \
      && echo "      deploy:staging released -- the berth was held by a lapsed window"
  fi
  # Said on the PR, because a reservation disappearing with no record is how an
  # audit ends up unable to explain a gap in the schedule.
  gh pr comment "$pr" --repo "$R" --body \
"Window \`$id\` (\`$start\` .. \`$end\`) **lapsed** and was closed \`expired\` by \`change/reap.sh\`.

Nothing was attempted, so this is not a failure and not a cancellation — the reservation simply ran out. This change is still eligible and still approved; it needs a **new window**, and the reaper deliberately does not book one. A reaper that rebooks hides the signal worth seeing: that the slot was too short for the work it was holding." >/dev/null 2>&1
done

# Counted from the SCHEDULE, not from a variable the loop incremented: the
# while runs in a subshell behind the pipe, so any counter it kept would read
# back as 0 here. Ask the thing that knows.
tot=$(./change/schedule.sh list 2>/dev/null | awk '$NF=="expired"' | wc -l | tr -d ' ')
echo "  $tot expired window(s) on the schedule"
