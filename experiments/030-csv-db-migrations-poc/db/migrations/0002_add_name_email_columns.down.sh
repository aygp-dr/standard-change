#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

# contract step: the down of an expand is a contract, literally. drop the
# three columns 0002 added, regardless of whether db/seeds.sh has run.

TABLE=db/tables/users.csv
TMP=$(mktemp)
awk -F, 'BEGIN{OFS=","} {print $1}' "$TABLE" > "$TMP"
mv "$TMP" "$TABLE"

echo "contracted $TABLE: dropped first_name,last_name,email"
