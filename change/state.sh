#!/bin/sh
# IDP state with compare-and-swap, using GitHub as the only storage.
#
# Backends, both CAS, no extra infra:
#   contents  PUT /repos/:o/:r/contents/:path with the blob `sha` you read.
#             GitHub returns 409 if anyone wrote first. History is git history.
#   ref       update-ref / push with an expected old value. Same guarantee,
#             works offline, used by the simulator.
#
# The CAS is the whole point: `gh issue edit` and repo variables are
# last-write-wins, so two agents racing for the path to production both
# "succeed" and one hold silently vanishes.
set -eu

BACKEND="${IDP_BACKEND:-ref}"
BRANCH="${IDP_BRANCH:-idp-state}"
PATH_IN_REPO="${IDP_PATH:-state.json}"
REF="refs/idp/state"

read_state() {
  case "$BACKEND" in
    contents)
      gh api "repos/$GITHUB_REPOSITORY/contents/$PATH_IN_REPO?ref=$BRANCH" \
         --jq '{sha: .sha, body: (.content | @base64d)}' 2>/dev/null \
         || echo '{"sha":"","body":"{}"}'
      ;;
    ref)
      old=$(git rev-parse --verify --quiet "$REF" || true)
      if [ -n "$old" ]; then
        printf '{"sha":"%s","body":%s}' "$old" "$(git cat-file -p "$old" | jq -Rs .)"
      else
        echo '{"sha":"","body":"{}"}'
      fi
      ;;
  esac
}

# write_state <expected-sha> <json>   -- exit 9 on CAS conflict
write_state() {
  expected="$1"; body="$2"
  case "$BACKEND" in
    contents)
      set -- --method PUT -f message="idp: $(date -u +%FT%TZ) [skip ci]" \
             -f branch="$BRANCH" -f content="$(printf '%s' "$body" | base64 | tr -d '\n')"
      [ -n "$expected" ] && set -- "$@" -f sha="$expected"
      gh api "repos/$GITHUB_REPOSITORY/contents/$PATH_IN_REPO" "$@" >/dev/null 2>&1 \
        || { echo "CAS conflict: state changed under us" >&2; exit 9; }
      ;;
    ref)
      _blob=$(printf '%s' "$body" | git hash-object -w --stdin)
      if [ -n "$expected" ]; then
        git update-ref "$REF" "$_blob" "$expected" 2>/dev/null \
          || { echo "CAS conflict: state changed under us" >&2; exit 9; }
      else
        git update-ref "$REF" "$_blob" "" 2>/dev/null \
          || { echo "CAS conflict: state already exists" >&2; exit 9; }
      fi
      ;;
  esac
}

now() { date -u +%FT%TZ; }
plus() { python3 -c "import datetime,sys;print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(minutes=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"; }
# extend from the later of (current deadline, now) -- never shorten a hold.
plus_from() { python3 -c "
import datetime,sys
base=sys.argv[1]; mins=int(sys.argv[2])
t=datetime.datetime.now(datetime.timezone.utc)
if base:
    b=datetime.datetime.fromisoformat(base.replace('Z','+00:00'))
    t=max(t,b)
print((t+datetime.timedelta(minutes=mins)).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1" "$2"; }

case "${1:-}" in
  show)
    read_state | jq -r .body | jq .
    ;;

  # claim <pr> <minutes> -- take the path to production for a window.
  claim)
    pr="$2"; mins="${3:-30}"
    st=$(read_state); sha=$(echo "$st" | jq -r .sha); cur=$(echo "$st" | jq -r .body)
    holder=$(echo "$cur" | jq -r '.holder.pr // empty')
    until=$(echo "$cur" | jq -r '.holder.until // empty')
    if [ -n "$holder" ] && [ "$holder" != "$pr" ] && [ "$until" \> "$(now)" ]; then
      echo "held by PR #$holder until $until" >&2; exit 5
    fi
    new=$(echo "$cur" | jq --arg pr "$pr" --arg u "$(plus "$mins")" --arg t "$(now)" \
      '.holder = {pr:$pr, since:$t, until:$u, extensions:0}
       | .log += [{at:$t, event:"claim", pr:$pr, until:$u}]')
    write_state "$sha" "$new"
    echo "PR #$pr holds the path to production until $(echo "$new" | jq -r .holder.until)"
    ;;

  # extend <pr> <minutes> <reason> -- keep the position, push the deadline out.
  # Used when an emergency preempts you: you did not go stale, you were
  # invalidated, so you keep the queue position and get time to rebase.
  extend)
    pr="$2"; mins="$3"; reason="${4:-preempted}"
    st=$(read_state); sha=$(echo "$st" | jq -r .sha); cur=$(echo "$st" | jq -r .body)
    [ "$(echo "$cur" | jq -r '.holder.pr // empty')" = "$pr" ] || {
      echo "PR #$pr does not hold the path" >&2; exit 5; }
    _cur_until=$(echo "$cur" | jq -r '.holder.until // empty')
    new=$(echo "$cur" | jq --arg u "$(plus_from "$_cur_until" "$mins")" --arg t "$(now)" --arg r "$reason" \
      '.holder.until = $u | .holder.extensions += 1
       | .holder.revalidate = true
       | .log += [{at:$t, event:"extend", reason:$r, until:$u}]')
    write_state "$sha" "$new"
    echo "extended to $(echo "$new" | jq -r .holder.until) ($reason); revalidate required"
    ;;

  release)
    pr="$2"
    st=$(read_state); sha=$(echo "$st" | jq -r .sha); cur=$(echo "$st" | jq -r .body)
    new=$(echo "$cur" | jq --arg t "$(now)" --arg pr "$pr" \
      'del(.holder) | .log += [{at:$t, event:"release", pr:$pr}]')
    write_state "$sha" "$new"
    echo "released"
    ;;

  # emergency <pr> -- bypasses the queue without evicting the holder.
  emergency)
    pr="$2"
    st=$(read_state); sha=$(echo "$st" | jq -r .sha); cur=$(echo "$st" | jq -r .body)
    new=$(echo "$cur" | jq --arg pr "$pr" --arg t "$(now)" \
      '.emergency = {pr:$pr, at:$t}
       | .log += [{at:$t, event:"emergency", pr:$pr}]')
    write_state "$sha" "$new"
    echo "emergency #$pr proceeding; holder (if any) keeps position and must revalidate"
    ;;

  *) echo "usage: state.sh {show|claim <pr> <min>|extend <pr> <min> <reason>|release <pr>|emergency <pr>}" >&2; exit 2 ;;
esac
