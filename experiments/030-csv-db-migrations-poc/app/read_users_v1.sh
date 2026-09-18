#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# pre-migration app code: knows only that a "users" table has an id column.
# never touched again after migration 0002 ships -- that's the point.

TABLE=db/tables/users.csv
echo "== read_users_v1 (pre-migration: knows only 'id') =="
awk -F, 'NR==1{for(i=1;i<=NF;i++) h[$i]=i; next} {print "user id=" $h["id"]}' "$TABLE"
