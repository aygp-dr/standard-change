#!/bin/sh
# scheduler.sh [--once] -- the mini's scheduler: watches for release:start and
# runs change/driver.sh, one change at a time.
#
# watch.sh is this same loop for the jail estate: it consumes `release`, books
# a window, and calls activate.sh, which deploys with bastille. None of that
# runs on macOS. This one consumes nothing itself -- driver.sh consumes the
# intent at the moment it takes the lock, so a start that could not begin
# (lock held by another operator, exit 5) stays said and is retried.
#
# ORDER. Oldest PR number first. The label carries no timestamp, so "who said
# start first" is not on the PR list; it is in the timeline, which this does
# not read. A person who wants order books a window.
#
# Trigger to fold this into watch.sh: the first target other than jails that
# watch.sh has to drive.
set -eu
cd "$(dirname "$0")/.."
R="${GH_REPO:-${GITHUB_REPOSITORY:-aygp-dr/standard-change}}"
INTERVAL="${SCHED_INTERVAL:-20}"
told=''; deferred=''
log() { printf '%s  scheduler  %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
tick() {
  # release:skip first: nothing to release, no berth to wait for
  for pr in $(gh pr list --repo "$R" --state open --label release:skip --json number -q 'sort_by(.number)|.[].number'); do
    log "release:skip on #$pr"; ./change/unaffected.sh "$pr" || log "#$pr: unaffected.sh exit $?"
  done
  for pr in $(gh pr list --repo "$R" --state open --label release:start --json number -q 'sort_by(.number)|.[].number'); do
    log "release:start on #$pr"
    rc=0; ./change/driver.sh "$pr" || rc=$?
    case $rc in
      0) log "#$pr settled"; told=$(echo " $told " | sed "s/ $pr / /") ;;
      5) # One holder; try the same one next tick. Say so ONCE: #104's owner sat
         # five minutes on release:start with no acknowledgement (experiments/023).
         case " $told " in *" $pr "*) ;; *)
           told="$told $pr"
           holder=$(gh pr list --repo "$R" --state open --label deploy:staging --json number -q '[.[].number]|first // empty')
           # The other operator holds the RECORD without the label for most of a run ("#?" on #106).
           [ -n "$holder" ] || holder=$(./change/lock.sh status | awk '$1=="pr:"{print $2}')
           gh pr comment "$pr" --repo "$R" --body "Heard \`release:start\`. Waiting: the berth (\`deploy:staging\`) is held by #${holder:-unknown: the record names no PR}. This ticket is retried every ${INTERVAL}s and takes the berth when it is free; nothing is asked of you." >/dev/null 2>&1 || true ;;
         esac
         # CONTINUE, do not return: returning told only the first waiter, and
         # #108's owner sat thirteen minutes on release:start with no word.
         log "#$pr waits: lock held"; continue ;;
      6) log "#$pr refused: behind main" ;;
      4) log "#$pr blocked: scheduled, and the calendar is not readable here" ;;
      7) # a window ahead: the scheduled case; say so once, then leave it to its window
         case " $deferred " in *" $pr "*) ;; *)
           deferred="$deferred $pr"
           w=$(./change/schedule.sh windows "$pr" 2>/dev/null | awk -v now="$(date -u +%FT%TZ)" '$3 > now {print $1" at "$3; exit}')
           gh pr comment "$pr" --repo "$R" --body "Heard \`release:start\`. This change holds a window ahead (\`${w}\`), so the driver waits for it: nothing runs before the window opens, and nothing is asked of you. To go sooner, unschedule the window first." >/dev/null 2>&1 || true ;;
         esac
         log "#$pr deferred to its window" ;;
      *) log "#$pr ended: driver exit $rc" ;;
    esac
  done
}
if [ "${1:-}" = "--once" ]; then tick; exit 0; fi
log "watching $R for release:start every ${INTERVAL}s"
while :; do tick; sleep "$INTERVAL"; done
