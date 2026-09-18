#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# post-migration app code: knows about first_name/last_name/email and
# tolerates a row that hasn't been backfilled yet (id 3, until a later round
# fills it in). This is the "new code" half of the old-code/new-code window
# that expand/contract exists to cover.

TABLE=db/tables/users.csv
echo "== read_users_v2 (post-migration: knows id, first_name, last_name, email) =="
awk -F, 'NR==1{for(i=1;i<=NF;i++) h[$i]=i; next} {
  fn=$h["first_name"]; ln=$h["last_name"]; em=$h["email"];
  if (fn=="") fn="(unbackfilled)";
  printf "user id=%s name=%s %s email=%s\n", $h["id"], fn, ln, em
}' "$TABLE"
