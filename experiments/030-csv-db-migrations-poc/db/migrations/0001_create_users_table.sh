#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

TABLE=db/tables/users.csv
if [ -f "$TABLE" ]; then
  echo "users.csv already exists, nothing to do"
  exit 0
fi

cat > "$TABLE" <<'EOF'
id
1
2
3
4
EOF

echo "created $TABLE"
