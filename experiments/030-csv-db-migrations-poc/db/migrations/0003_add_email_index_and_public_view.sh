#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

# an "index" and a "view" are both just derived CSVs, rebuilt in full every
# time this migration runs -- no incremental maintenance, on purpose.

TABLE=db/tables/users.csv
INDEX=db/indexes/users_by_email.csv
VIEW=db/views/users_public.csv

echo "email,row" > "$INDEX"
awk -F, 'NR==1{for(i=1;i<=NF;i++) h[$i]=i; next} {email=$h["email"]; if(email!="") print email","(NR-1)}' "$TABLE" >> "$INDEX"

awk -F, 'BEGIN{OFS=","} NR==1{for(i=1;i<=NF;i++) h[$i]=i; print "id","first_name","last_name"; next} {print $h["id"],$h["first_name"],$h["last_name"]}' "$TABLE" > "$VIEW"

echo "built $INDEX and $VIEW"
