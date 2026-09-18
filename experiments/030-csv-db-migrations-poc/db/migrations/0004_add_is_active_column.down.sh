#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

# a different contract technique than 0002's: drop the last column
# generically via NF--, rather than naming the columns to keep.

TABLE=db/tables/users.csv
TMP=$(mktemp)
awk -F, 'BEGIN{OFS=","} {NF--; print}' "$TABLE" > "$TMP"
mv "$TMP" "$TABLE"

echo "contracted $TABLE: dropped is_active"
