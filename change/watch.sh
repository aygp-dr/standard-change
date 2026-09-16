#!/bin/sh
# watch.sh [--once] -- the scheduler. Watches for `release` and acts on it.
#
# Exists because no GitHub runner can reach the estate: every workflow is
# ubuntu-latest and the jails are on hydra's 10.0.0/24. A label cannot deploy
# what a runner cannot see, so something on the host has to watch for it.
#
# `release` is a REQUEST -- a person saying "take this one all the way now".
# It is bare rather than `release:<env>` because it names no environment: it
# asks for the whole path, and the path is what the pipeline decides.
#
# This consumes the label. A trigger that stays on re-fires forever, and the
# second firing would deploy a change already in production.
#
# WHY THIS IS NOT "reserving is deploying" COLLAPSED: the rule is that booking
# a window is not a HUMAN's act -- hand-booking asserts an action nobody took.
# The scheduler booking one is the scheduler doing its job. Reservation and
# activation are still separate steps with the guards re-checked between them;
# `release` only says not to wait for a slot in between.
set -eu
cd "$(dirname "$0")/.."
R="${GH_REPO:-${GITHUB_REPOSITORY:-aygp-dr/standard-change}}"
INTERVAL="${WATCH_INTERVAL:-20}"
ONCE=0; [ "${1:-}" = "--once" ] && ONCE=1

log() { printf '%s  %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

tick() {
  pr=$(gh pr list --repo "$R" --state open --label release:start \
        --json number -q '[.[].number] | first // empty')
  [ -n "$pr" ] || return 0

  log "release requested on #$pr"
  # Consume FIRST. If activation dies, the change stops -- it does not retry
  # forever on a trigger nobody is watching. Re-requesting is a human act, and
  # it should be, because whatever killed the run is a thing to look at.
  gh pr edit "$pr" --repo "$R" --remove-label release >/dev/null
  gh pr edit "$pr" --repo "$R" --add-label release:started >/dev/null 2>&1 || true

  groups=$(./change/groups.sh "$pr")
  if [ -z "$groups" ]; then
    log "#$pr carries no app:* label; nothing to deploy"
    return 0
  fi

  # Book a window if none covers now. This is the scheduler acting, which is
  # the only thing allowed to.
  if ! ./change/schedule.sh current "$pr" staging >/dev/null 2>&1; then
    log "booking a window for #$pr ($groups)"
    ./change/schedule.sh block "$pr" "$groups" "${WINDOW_MINUTES:-30}" || {
      log "could not book a window for #$pr; staging is busy"; return 0; }
  fi

  log "activating #$pr"
  ./change/activate.sh "$pr" || log "#$pr activation exited $?"
}

if [ "$ONCE" = 1 ]; then tick; exit 0; fi
log "watching $R for \`release\` every ${INTERVAL}s (ctrl-c to stop)"
while :; do tick; sleep "$INTERVAL"; done
