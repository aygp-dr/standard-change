#!/bin/sh
# lock.sh acquire <pr> <target> | release | status -- the deployment lock.
#
# spec.org §Deployment lock: `acquire` writes pr, target, run-id, started_at
# to the lock body; `release` empties it; release runs in an always() step;
# a lock older than 60 minutes is stale and preflight clears it.
#
# THE FILE THAT DID NOT EXIST. deploy-staging.yml, deploy-production.yml and
# release.sh have called this since the workflows were written, and
# label-owners.tsv names it the owner of blocked:lock. It was never in the
# tree (#89), so every deploy run failed its always() cleanup with exit 127
# -- observed 2026-09-14 on runs 34897847816 and 34897883064 -- and a cleanup
# that cannot run is a berth that cannot be released.
#
# WHERE THE LOCK LIVES. The body of the estate issue, between two markers.
# That is what the spec names (§855: "read the deployment-lock ... issue #1
# body") and what preflight reads for the estate. It is last-write-wins,
# which state.sh warns about; the berth itself is the deploy:staging label
# and guard 1 reads THAT. This lock records who is deploying and since when,
# so a stale run can be told from a live one. It is a record with a
# tiebreak, not the mutex.
set -eu
R="${GH_REPO:-${GITHUB_REPOSITORY:-aygp-dr/standard-change}}"
ISSUE="${ESTATE_ISSUE:-1}"
STALE_MIN=60
OPEN='<!-- lock -->'; CLOSE='<!-- /lock -->'

body()  { gh issue view "$ISSUE" --repo "$R" --json body -q .body; }
lock()  { body | awk -v o="$OPEN" -v c="$CLOSE" 'index($0,o){f=1;next} index($0,c){f=0} f'; }
write() { # write <lock-text>
  _new=$(body | awk -v o="$OPEN" -v c="$CLOSE" 'index($0,o){skip=1} !skip{print} index($0,c){skip=0}')
  printf '%s\n%s\n%s\n%s\n' "$_new" "$OPEN" "$1" "$CLOSE" | gh issue edit "$ISSUE" --repo "$R" --body-file - >/dev/null
}
age_min() { # age_min <iso>
  _t=$(date -u -j -f %Y-%m-%dT%H:%M:%SZ "$1" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null || echo 0)
  echo $(( ($(date -u +%s) - _t) / 60 ))
}

case "${1:-status}" in
  status)
    l=$(lock)
    if [ -z "$l" ]; then echo "  lock: free"; else echo "  lock:"; echo "$l" | sed 's/^/    /'; fi ;;
  acquire)
    pr="${2:?acquire <pr> <target>}"; target="${3:?acquire <pr> <target>}"
    l=$(lock); held=$(echo "$l" | awk '$1=="pr:"{print $2}')
    if [ -n "$held" ] && [ "$held" != "$pr" ]; then
      since=$(echo "$l" | awk '$1=="started_at:"{print $2}')
      if [ "$(age_min "$since")" -lt "$STALE_MIN" ]; then
        gh pr edit "$pr" --repo "$R" --add-label blocked:lock >/dev/null 2>&1 || true
        echo "  lock: held by #$held on $(echo "$l" | awk '$1=="target:"{print $2}') since $since -- refused" >&2
        exit 2
      fi
      echo "  lock: #$held's lock is $(age_min "$since") min old (>$STALE_MIN) -- stale, clearing it"
    fi
    write "pr: $pr
target: $target
run-id: ${GITHUB_RUN_ID:-local-$$}
started_at: $(date -u +%FT%TZ)"
    gh pr edit "$pr" --repo "$R" --remove-label blocked:lock >/dev/null 2>&1 || true
    echo "  lock: acquired by #$pr for $target" ;;
  release)
    l=$(lock)
    [ -n "$l" ] || { echo "  lock: already free"; exit 0; }
    # ONLY YOUR OWN. deploy-staging.yml's always() step released the lock #95
    # held (2026-09-14 23:08): that run's acquire had been skipped -- it died at
    # preflight -- and its release ran anyway, on a lock another holder had
    # written. In CI, release only the lock this run acquired; a person running
    # this by hand (no GITHUB_RUN_ID) may release any lock, and says so.
    if [ -n "${GITHUB_RUN_ID:-}" ] && [ "$(echo "$l" | awk '$1=="run-id:"{print $2}')" != "$GITHUB_RUN_ID" ]; then
      echo "  lock: held by #$(echo "$l" | awk '$1=="pr:"{print $2}') under run $(echo "$l" | awk '$1=="run-id:"{print $2}'), not this run ($GITHUB_RUN_ID) -- not released"
      exit 0
    fi
    write ""
    echo "  lock: released (was #$(echo "$l" | awk '$1=="pr:"{print $2}'))" ;;
  *) echo "usage: lock.sh acquire <pr> <target> | release | status" >&2; exit 2 ;;
esac
