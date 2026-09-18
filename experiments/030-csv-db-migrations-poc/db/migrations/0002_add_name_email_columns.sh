#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

# expand step, structure only: add the three columns, blank for every row.
# No data opinions here -- that's db/seeds.sh's job, same split Rails makes
# between a migration (shape) and db/seeds.rb (reference data).

TABLE=db/tables/users.csv
TMP=$(mktemp)

awk -F, 'BEGIN{OFS=","}
NR==1 { print $0,"first_name","last_name","email"; next }
{ print $0,"","","" }
' "$TABLE" > "$TMP"
mv "$TMP" "$TABLE"

echo "expanded $TABLE: added first_name,last_name,email (blank for every row)"
