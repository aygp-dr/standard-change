#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

rm -f db/indexes/users_by_email.csv db/views/users_public.csv
echo "removed derived index and view"
