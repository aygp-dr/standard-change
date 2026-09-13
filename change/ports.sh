#!/bin/sh
# Port-block manager. Each worktree owns ten ports: router at 10000+10n,
# apps at fixed offsets. ports.tsv is the CMDB (spec.org, Router and ports).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# The registry is the CMDB for the whole clone, so it lives in the MAIN
# worktree, not in each one. git worktree list prints the main checkout first.
MAIN=$(git -C "$ROOT" worktree list --porcelain | awk '/^worktree /{print $2; exit}')
# Block base. 9000, not 10000: pf passes 192.168.86.0/24 to 8000:9999 and
# 7000:7699 but NOT 10000+, so a block at 10000 is loopback-only and looks
# from another host exactly like nothing listening. The project range is
# 9000-9099 for worktree blocks (spec.org, Port allocation on a shared host).
BASE0="${PORT_BASE:-9000}"
REG="${PORTS_REGISTRY:-$MAIN/ports.tsv}"
WT=$(git -C "$ROOT" rev-parse --show-toplevel)
BR=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)

[ -f "$REG" ] || printf 'block\tworktree\tbranch\tallocated_at\n' > "$REG"

next_block() {
  used=$(awk -F'\t' 'NR>1 {print $1}' "$REG" 2>/dev/null | sort -n)
  n=0; for u in $used; do [ "$u" -eq "$n" ] && n=$((n+1)); done; echo "$n"
}

case "${1:-}" in
  alloc)
    if grep -q "	$WT	" "$REG" 2>/dev/null; then
      # ONE row per worktree, and say so loudly if that is not true. This
      # printed every matching row, so a registry with two rows for this
      # worktree made b the two-line string "0\n6" and every later $((...))
      # failed with "variable conversion error" -- a corrupt CMDB surfacing as
      # an arithmetic error three lines away from the cause.
      dupes=$(awk -F'\t' -v w="$WT" '$2==w {print $1}' "$REG" | wc -l | tr -d ' ')
      b=$(awk -F'\t' -v w="$WT" '$2==w {print $1; exit}' "$REG")
      if [ "$dupes" -gt 1 ]; then
        echo "warn: ports.tsv holds $dupes rows for this worktree; using block $b." >&2
        echo "  A worktree holds at most one block. Reconcile with: ./change/ports.sh list" >&2
      fi
      echo "already allocated: block $b"
    else
      b=$(next_block)
      # Refuse BEFORE writing. The first version appended the row and then
      # refused, leaving a stale allocation for a block nobody could use.
      #
      # Ten blocks only. Block 10 starts at 9100, which is the TEAM tier --
      # environments that exist but cannot promote. A dev block there would be
      # squatting an address whose number claims something else, and the tiers
      # only mean anything if the boundary holds (spec.org, The port map).
      if [ "$b" -gt 9 ]; then
        echo "refused: block $b would start at $((BASE0 + 10 * b))," >&2
        echo "  which is the team tier. dev is 9000-9099, team 9100-9199," >&2
        echo "  protected 9200+. A dev block must not cross the boundary." >&2
        echo "  Free a block first:  ./change/ports.sh free   (list: ports.sh list)" >&2
        exit 4
      fi
      printf '%s\t%s\t%s\t%s\n' "$b" "$WT" "$BR" "$(date -u +%FT%TZ)" >> "$REG"
      echo "allocated block $b"
    fi
    base=$((BASE0 + 10 * b))
    { echo "BLOCK=$b"; echo "BASE_PORT=$base"
      for a in $(jq -r '.[].app' "$ROOT/router/routes.json"); do
        off=$(jq -r --arg a "$a" '.[]|select(.app==$a)|.port_offset' "$ROOT/router/routes.json")
        echo "PORT_$(echo "$a" | tr 'a-z' 'A-Z')=$((base + off))"
      done
    } > "$WT/.env.ports"
    echo "wrote $WT/.env.ports (router :$base)"
    ;;
  free)
    tmp="$REG.tmp"; awk -F'\t' -v w="$WT" 'NR==1 || $2!=w' "$REG" > "$tmp" && mv "$tmp" "$REG"
    rm -f "$WT/.env.ports"; echo "freed"
    ;;
  run-apps)
    . "$WT/.env.ports"
    SHA=$(git -C "$WT" rev-parse --short HEAD)
    mkdir -p "$WT/.run"
    for a in $(jq -r '.[].app' "$ROOT/router/routes.json"); do
      # An explicit assignment rather than `eval "p=$var"`. The eval form sets p
      # invisibly, so neither a reader nor shellcheck (SC2154) can see where it
      # comes from. Two directives failed to silence it because the use is an
      # assignment prefix inside a loop; making the dataflow visible was the
      # better fix than arguing with the linter.
      var="PORT_$(echo "$a" | tr 'a-z' 'A-Z')"
      p=$(eval "printf '%s' \"\$$var\"")
      # apps/ is ours; external/ stands in for services we do not deploy
      d="$WT/apps/$a"; [ -d "$d" ] || d="$WT/external/$a"
      BUILD_SHA="$SHA" BLOCK="$BLOCK" PORT="$p" node "$d/src/server.js" \
        > "$WT/.run/$a.log" 2>&1 &
      echo $! > "$WT/.run/$a.pid"
    done
    BUILD_SHA="$SHA" BLOCK="$BLOCK" BASE_PORT="$BASE_PORT" node "$WT/router/server.js" \
      > "$WT/.run/router.log" 2>&1 &
    echo $! > "$WT/.run/router.pid"
    echo "block $BLOCK up: router :$BASE_PORT (sha $SHA)"
    ;;
  stop)
    for f in "$WT"/.run/*.pid; do [ -f "$f" ] || continue; kill "$(cat "$f")" 2>/dev/null || true; rm -f "$f"; done
    echo "stopped"
    ;;
  list) column -t -s'	' "$REG" 2>/dev/null || cat "$REG" ;;
  *) echo "usage: ports.sh {alloc|free|run-apps|stop|list}" >&2; exit 2 ;;
esac
