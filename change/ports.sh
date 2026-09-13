#!/bin/sh
# Port-block manager. Each worktree owns ten ports: router at 10000+10n,
# apps at fixed offsets. ports.tsv is the CMDB (spec.org, Router and ports).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# The registry is the CMDB for the whole clone, so it lives in the MAIN
# worktree, not in each one. git worktree list prints the main checkout first.
MAIN=$(git -C "$ROOT" worktree list --porcelain | awk '/^worktree /{print $2; exit}')
# Block base. 10000 is loopback-only on hydra: pf passes 192.168.86.0/24 to
# 8000:9999 and 7000:7699 but not 10000+. Set PORT_BASE=9000 for a block that
# is reachable from another host without touching the firewall.
BASE0="${PORT_BASE:-10000}"
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
      b=$(awk -F'\t' -v w="$WT" '$2==w {print $1}' "$REG")
      echo "already allocated: block $b"
    else
      b=$(next_block)
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
      var="PORT_$(echo "$a" | tr 'a-z' 'A-Z')"; eval "p=\$$var"
      BUILD_SHA="$SHA" BLOCK="$BLOCK" PORT="$p" node "$WT/apps/$a/src/server.js" \
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
