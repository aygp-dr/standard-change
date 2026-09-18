#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

# a fourth expand, and a different shape: a column with a default value
# rather than a blank one -- no seed script needed for this one, since
# every row gets the same starting value at migration time.

TABLE=db/tables/users.csv
TMP=$(mktemp)
awk -F, 'BEGIN{OFS=","} NR==1{print $0,"is_active"; next} {print $0,"true"}' "$TABLE" > "$TMP"
mv "$TMP" "$TABLE"

echo "expanded $TABLE: added is_active (default true for every row)"
