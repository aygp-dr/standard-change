#!/bin/sh
# uat.sh [url] -- the browser journey, as-is, against an estate.
#
# The fourth gate, and the one that says what "deployed" means to a person:
# a real browser walks home -> plp -> pdp -> add to cart -> checkout and every
# assertion is the storefront AS ACCEPTED, unfinished parts included. A change
# that alters the flow is refused here on entry to staging until its author
# updates gates/uat/journey.spec.mjs to say what the new flow is.
#
# Exit codes follow the other gates: 0 accepted, 1 refused, 2 could not run.
set -eu
cd "$(dirname "$0")/uat"
export ROUTER_URL="${1:-${ROUTER_URL:-http://127.0.0.1:9000}}"
[ -d node_modules/@playwright ] || {
  echo "uat: installing @playwright/test (once)" >&2
  npm install --no-audit --no-fund --silent || exit 2
}
if [ -z "${PLAYWRIGHT_CHROME:-}" ] && ! npx --no-install playwright install --dry-run chromium >/dev/null 2>&1; then
  echo "uat: installing chromium for playwright (once)" >&2
  npx --no-install playwright install chromium >/dev/null 2>&1 || exit 2
fi
curl -s -o /dev/null --max-time 5 "$ROUTER_URL/" || { echo "uat: nothing answers at $ROUTER_URL" >&2; exit 2; }
echo "uat: $ROUTER_URL"
if npx --no-install playwright test; then
  echo "  uat accepted (as-is journey held)"
else
  echo "  uat REFUSED: the journey is not what was accepted" >&2; exit 1
fi
