#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Rails' db/seeds.rb, run on demand (rails db:seed), not tracked in the
# migrations ledger -- seeding reference/demo data is a different kind of
# change from a schema migration, and this repo's own migration-vs-code
# research is exactly the argument for keeping the two apart even in a toy.
#
# Idempotent by construction: it always overwrites the same three rows with
# the same values, so running it twice is a no-op in effect even though
# nothing here checks first. It only knows about ids 1-3 on purpose -- id 4
# stays unbackfilled because this script was never taught about it, the same
# way a real seeds.rb quietly falls behind the rows a migration adds later.

TABLE=db/tables/users.csv

if ! head -1 "$TABLE" | grep -q first_name; then
  echo "run ./migrate.sh first -- users.csv has no first_name column yet" >&2
  exit 1
fi

TMP=$(mktemp)
awk -F, 'BEGIN{OFS=","}
NR==1 { print; next }
$1==1 { print $1,"Kurt","Godel","godel@example.com"; next }
$1==2 { print $1,"Hannah","Arendt","arendt@example.com"; next }
$1==3 { print $1,"Ada","Lovelace","lovelace@example.com"; next }
{ print }
' "$TABLE" > "$TMP"
mv "$TMP" "$TABLE"

echo "seeded ids 1-3 (math, philosophy, computing); id 4 left to whoever teaches this script about it"
