#!/bin/sh
# berth.sh status | check | expire <pr> [--selftest] -- expiry for the MUTEX.
#
# change/lock.sh says it plainly about itself: "the berth itself is the
# deploy:staging label and guard 1 reads THAT ... It is a record with a
# tiebreak, NOT THE MUTEX." So the 60-minute staleness rule in lock.sh expires
# the RECORD. The mutex -- the label -- has never expired at all, and a change
# can hold the path to production forever.
#
# five-properties P1 says the berth is "a mutex with a holder identity and an
# expiry ... an unrenewed lease lapses". The holder identity is there, the
# expiry is on the wrong object. This is that gap.
#
# THE DEFAULT IS MANUAL, AND THAT IS THE POINT. Automatically clearing a lock
# evicts a holder that may still be running: the lock is the only thing
# standing between two deployments, and a timer is not evidence that the holder
# is dead. Under BERTH_EXPIRY=manual (default) this MARKS and REFUSES; a person
# resolves it. BERTH_EXPIRY=auto restores timer-based eviction for estates that
# would rather risk a double deploy than a wedged berth.
#
#   BERTH_EXPIRY   manual (default) | auto
#   BERTH_TTL_MIN  minutes before the berth is stale (default 60)
#
# AGE COMES FROM THE FORGE, not from a label and not from our own record. A
# label cannot carry a timestamp (guard4.sh:28-51 is the same lesson), so the
# authority is the `labeled` timeline event: who added deploy:staging, and
# when. The lock record's started_at is read only as a cross-check, because two
# records of one fact can disagree and the platform's cannot.
#
# Exit: 0 berth free or healthy, 2 held (and stale, under manual), 4 could not
# determine -- docs/exit-codes.org, and 4 is not 0.
set -eu
R="${GH_REPO:-${GITHUB_REPOSITORY:-aygp-dr/standard-change}}"
POLICY="${BERTH_EXPIRY:-manual}"
TTL="${BERTH_TTL_MIN:-60}"
LABEL=deploy:staging
STALE=berth:stale

case "$POLICY" in manual|auto) ;; *)
  echo "berth: BERTH_EXPIRY must be 'manual' or 'auto', got '$POLICY'" >&2; exit 2 ;;
esac

age_min() {
  _t=$(date -u -j -f %Y-%m-%dT%H:%M:%SZ "$1" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null || echo "")
  [ -n "$_t" ] || { echo ""; return; }
  echo $(( ($(date -u +%s) - _t) / 60 ))
}

# When did this PR last ACQUIRE the berth? The last `labeled` event that has
# not been followed by an `unlabeled` for the same label. Anything less than
# that reads a re-label as a fresh claim, and #94 relabelled fourteen times.
acquired_at() { # acquired_at <pr>
  gh api "repos/$R/issues/$1/timeline" --paginate \
    -q "[.[]|select((.event==\"labeled\" or .event==\"unlabeled\") and .label.name==\"$LABEL\")]
        | last | select(.event==\"labeled\") | .created_at" 2>/dev/null
}
acquired_by() {
  gh api "repos/$R/issues/$1/timeline" --paginate \
    -q "[.[]|select((.event==\"labeled\" or .event==\"unlabeled\") and .label.name==\"$LABEL\")]
        | last | select(.event==\"labeled\") | .actor.login" 2>/dev/null
}

holders() {
  gh pr list --repo "$R" --state open --label "$LABEL" --json number -q '.[].number' 2>/dev/null
}

selftest() {
  rc=0
  # A policy checker that accepts every input is not a checker. Three cases,
  # and the third is the control that must NOT fire.
  out=$(BERTH_EXPIRY=nonsense sh "$0" status 2>&1 || true)
  case "$out" in *"must be 'manual' or 'auto'"*) ;; *)
    echo "  FAIL selftest: bad BERTH_EXPIRY was accepted"; rc=1 ;; esac
  # age_min must refuse to guess on an unparseable stamp rather than return 0,
  # because 0 minutes reads as "fresh" and would hide a stale berth forever.
  a=$(age_min "not-a-timestamp")
  [ -z "$a" ] || { echo "  FAIL selftest: age_min invented $a for a bad stamp"; rc=1; }
  a=$(age_min "2020-01-01T00:00:00Z")
  [ -n "$a" ] && [ "$a" -gt 1000000 ] || { echo "  FAIL selftest: age_min cannot age a real stamp"; rc=1; }
  [ "$rc" = 0 ] && echo "  ok    berth selftest: policy rejected, age refuses to guess, age works"
  return $rc
}

[ "${1:-status}" = "--selftest" ] && { selftest; exit $?; }

case "${1:-status}" in
  status|check)
    hs=$(holders) || { echo "berth: could not list holders -- nothing was checked" >&2; exit 4; }
    if [ -z "$hs" ]; then echo "  berth: free (policy=$POLICY ttl=${TTL}m)"; exit 0; fi
    rc=0; n=0
    for pr in $hs; do
      n=$((n+1))
      at=$(acquired_at "$pr" || true)
      if [ -z "$at" ]; then
        # The label is held and the forge has no acquisition event for it. That
        # is not "fresh" -- it is unmeasurable, and unmeasurable blocks.
        echo "  berth: #$pr holds $LABEL and no labeled event names when -- cannot age it" >&2
        rc=4; continue
      fi
      age=$(age_min "$at"); who=$(acquired_by "$pr" || echo '?')
      if [ -z "$age" ]; then echo "  berth: #$pr acquired at an unparseable '$at'" >&2; rc=4; continue; fi
      if [ "$age" -lt "$TTL" ]; then
        printf '  berth: #%s holds it, %sm old (<%sm), by %s -- live\n' "$pr" "$age" "$TTL" "$who"
        continue
      fi
      printf '  berth: #%s holds it, %sm old (>=%sm), by %s -- STALE\n' "$pr" "$age" "$TTL" "$who"
      [ "${1:-status}" = "check" ] || { rc=2; continue; }
      gh pr edit "$pr" --repo "$R" --add-label "$STALE" >/dev/null 2>&1 || true
      if [ "$POLICY" = auto ]; then
        gh pr edit "$pr" --repo "$R" --remove-label "$LABEL" >/dev/null 2>&1 || true
        gh pr comment "$pr" --repo "$R" --body \
"The staging berth was held for ${age} minutes (TTL ${TTL}m) and \`BERTH_EXPIRY=auto\`, so \`$LABEL\` has been cleared and the path to production is free.

This is an eviction on a timer, not evidence that the deployment stopped. If it was still running, its next write will find the berth held by someone else." >/dev/null 2>&1 || true
        echo "    cleared (BERTH_EXPIRY=auto)"
      else
        gh pr comment "$pr" --repo "$R" --body \
"The staging berth has been held by this change for ${age} minutes, past the ${TTL}m TTL, so it is marked \`$STALE\`.

**Nothing has been cleared.** The default is manual resolution: a timer is not evidence that a deployment stopped, and clearing a live holder is how two changes deploy at once.

To release it, once you have checked nothing is still deploying:

    gh pr edit $pr --remove-label $LABEL
    ./change/lock.sh release

Or set \`BERTH_EXPIRY=auto\` on the estate to evict on the timer instead." >/dev/null 2>&1 || true
        echo "    marked $STALE; not cleared (BERTH_EXPIRY=manual)"
        rc=2
      fi
    done
    printf '  berth: %s holder(s) examined, policy=%s ttl=%sm\n' "$n" "$POLICY" "$TTL"
    exit $rc ;;
  expire)
    pr="${2:?usage: berth.sh expire <pr>}"
    gh pr edit "$pr" --repo "$R" --remove-label "$LABEL" >/dev/null 2>&1 || true
    gh pr edit "$pr" --repo "$R" --remove-label "$STALE" >/dev/null 2>&1 || true
    echo "  berth: released #$pr by hand" ;;
  *) echo "usage: berth.sh status | check | expire <pr> | --selftest" >&2; exit 2 ;;
esac
