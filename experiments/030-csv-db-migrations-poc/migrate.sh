#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Ledger shape borrows Django's django_migrations table: id, app, name,
# applied -- an autoincrementing id, a fixed app label (one app here), the
# migration's name (its filename without extension, same as Django's
# convention of naming the migration after the file), and an applied
# timestamp. Rails' schema_migrations is a single `version` column; Ragtime's
# ragtime_migrations is `id, created_at`. Django's is the richest of the
# three without inventing anything, so it's what this ledger copies.
#
# The ledger is not a separate mechanism bolted onto the "database" -- it is
# db/tables/migrations.csv, one more table, read and written by the same
# kind of awk that reads users.csv.
#
# up/down file pairing (NNNN_name.sh / NNNN_name.down.sh) borrows from
# golang-migrate and Flyway's .up/.down file convention, rather than Rails'
# single invertible `change` method or Django's in-file reverse_code --
# because these are shell scripts, not a DSL a framework can introspect and
# invert automatically.

LEDGER=db/tables/migrations.csv
APP=poc

usage() {
  echo "usage: $0 [up|down]" >&2
  exit 1
}

is_applied() {
  local name="$1"
  awk -F, -v n="$name" -v a="$APP" 'NR>1 && $2==a && $3==n {found=1} END{exit !found}' "$LEDGER"
}

next_id() {
  wc -l < "$LEDGER" | tr -d ' '
}

show_state() {
  echo
  echo "-- db/tables/migrations.csv --"
  column -s, -t "$LEDGER" 2>/dev/null || cat "$LEDGER"
  echo
  echo "-- db/tables --"; ls db/tables
  echo
  echo "-- db/indexes --"; ls db/indexes
  echo
  echo "-- db/views --"; ls db/views
}

cmd_up() {
  mkdir -p db/tables db/indexes db/views
  if [ ! -f "$LEDGER" ]; then
    echo "id,app,name,applied" > "$LEDGER"
  fi
  for f in db/migrations/*.sh; do
    case "$f" in *.down.sh) continue ;; esac
    name=$(basename "$f" .sh)
    if is_applied "$name"; then
      echo "skip (applied): $name"
      continue
    fi
    echo "applying: $name"
    bash "$f"
    id=$(next_id)
    applied_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "${id},${APP},${name},${applied_at}" >> "$LEDGER"
  done
  show_state
}

cmd_down() {
  if [ ! -f "$LEDGER" ]; then
    echo "nothing to roll back -- no ledger yet"
    exit 0
  fi
  last=$(tail -n 1 "$LEDGER")
  if [ "$last" = "id,app,name,applied" ] || [ -z "$last" ]; then
    echo "nothing to roll back -- ledger is empty"
    exit 0
  fi
  name=$(echo "$last" | awk -F, '{print $3}')
  down_script="db/migrations/${name}.down.sh"
  if [ ! -f "$down_script" ]; then
    echo "no down migration for $name ($down_script missing) -- refusing" >&2
    exit 1
  fi
  echo "rolling back: $name"
  bash "$down_script"
  sed '$d' "$LEDGER" > "${LEDGER}.tmp" && mv "${LEDGER}.tmp" "$LEDGER"
  show_state
}

case "${1:-up}" in
  up)   cmd_up ;;
  down) cmd_down ;;
  *)    usage ;;
esac
