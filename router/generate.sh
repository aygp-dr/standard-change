#!/bin/sh
# Generate router/routes.json: our deployables PLUS the external services the
# router must front. apps/ means things WE deploy; external/ means stand-ins for
# services we do not own (in production these point at the real thing).
# Derived artifact: never hand-edit (spec.org, the artifacts table).
set -eu
cd "$(dirname "$0")/.."
jq -s '.' apps/*/routes.json external/*/routes.json > router/routes.json
echo "router/routes.json <- $(ls apps/*/routes.json | wc -l | tr -d ' ') apps + $(ls external/*/routes.json | wc -l | tr -d ' ') external"
