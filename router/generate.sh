#!/bin/sh
# Generate router/routes.json as the union of apps/*/routes.json.
# Derived artifact: never hand-edit (spec.org, the artifacts table).
set -eu
cd "$(dirname "$0")/.."
jq -s '.' apps/*/routes.json > router/routes.json
echo "router/routes.json <- $(ls apps/*/routes.json | wc -l | tr -d ' ') apps"
