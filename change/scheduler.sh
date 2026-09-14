#!/bin/sh
# scheduler.sh [--once] -- the mini's scheduler: watches for change:start and
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
log() { printf '%s  scheduler  %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
tick() {
  for pr in $(gh pr list --repo "$R" --state open --label change:start --json number -q 'sort_by(.number)|.[].number'); do
    log "change:start on #$pr"
    rc=0; ./change/driver.sh "$pr" || rc=$?
    case $rc in
      0) log "#$pr settled" ;;
      5) log "#$pr waits: lock held" ; return 0 ;;   # one holder; try the same one next tick
      6) log "#$pr refused: behind main" ;;
      *) log "#$pr ended: driver exit $rc" ;;
    esac
  done
}
if [ "${1:-}" = "--once" ]; then tick; exit 0; fi
log "watching $R for change:start every ${INTERVAL}s"
while :; do tick; sleep "$INTERVAL"; done
