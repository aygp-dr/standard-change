#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

# an "index" and a "view" are both just derived CSVs, rebuilt in full every
# time this migration runs -- no incremental maintenance, on purpose.
#
# the view is a plain column projection, which is exactly what xsv's
# `select` is for, so it's used here when present. the index is not: it
# needs a row number attached to each non-blank email, and xsv has no
# select-with-computed-column verb, so that half stays hand-rolled awk
# either way. See notes.org, "Using xsv, with a note to upgrade."

TABLE=db/tables/users.csv
INDEX=db/indexes/users_by_email.csv
VIEW=db/views/users_public.csv

echo "email,row" > "$INDEX"
awk -F, 'NR==1{for(i=1;i<=NF;i++) h[$i]=i; next} {email=$h["email"]; if(email!="") print email","(NR-1)}' "$TABLE" >> "$INDEX"

if command -v xsv >/dev/null 2>&1; then
  xsv select id,first_name,last_name "$TABLE" > "$VIEW"
else
  awk -F, 'BEGIN{OFS=","} NR==1{for(i=1;i<=NF;i++) h[$i]=i; print "id","first_name","last_name"; next} {print $h["id"],$h["first_name"],$h["last_name"]}' "$TABLE" > "$VIEW"
fi

echo "built $INDEX and $VIEW"
