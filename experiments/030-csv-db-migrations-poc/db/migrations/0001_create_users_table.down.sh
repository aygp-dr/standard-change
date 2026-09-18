#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

TABLE=db/tables/users.csv
rm -f "$TABLE"
echo "dropped $TABLE"
