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
#
# --pr <n> --env <name> records the verdict as <env>:uat, the way e2e.sh and
# smoke.sh record theirs. Until 2026-09-15 the driver recorded this run through
# change/observe.sh, whose text says "a person used ... and accepted it"; two
# owners in experiments/023 read that and asked who the person was. Nobody
# was. What ran is the journey a person once accepted, replayed by Playwright,
# and the record now says exactly that.
set -eu
PR=''; ENV_=''
while [ $# -gt 0 ]; do
  case "$1" in
    --pr)  PR="${2:?--pr needs a number}"; shift 2 ;;
    --env) ENV_="${2:?--env needs a name}"; shift 2 ;;
    *)     break ;;
  esac
done
ROOT=$(cd "$(dirname "$0")/.." && pwd)
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
rc=0; npx --no-install playwright test || rc=$?
if [ -n "$PR" ]; then
  repo="${GH_REPO:-${GITHUB_REPOSITORY:-aygp-dr/standard-change}}"
  ENV_="${ENV_:-staging}"
  sha=$(curl -sI --max-time 5 "$ROUTER_URL/" | tr -d '\r' | awk 'tolower($1)=="x-build-sha:"{print $2}')
  verdict=$([ "$rc" = 0 ] && echo pass || echo fail)
  ( cd "$ROOT" && ./change/evidence.sh record "$PR" "$ENV_" uat "$verdict" "${sha:-unknown}" "$ROUTER_URL" ) || true
  if [ "$rc" = 0 ]; then
    gh pr edit "$PR" --repo "$repo" --add-label "$ENV_:uat" >/dev/null 2>&1 || true
    gh pr comment "$PR" --repo "$repo" --body "\`$ENV_:uat\` — the journey **as accepted** (gates/uat/journey.spec.mjs) held on \`${sha:-unknown}\` at $ROUTER_URL, replayed by Playwright. No person looked at this build; the acceptance is the one a person gave the journey, and a change that alters the flow is refused here until its author updates it." >/dev/null 2>&1 || true
  else
    gh pr edit "$PR" --repo "$repo" --remove-label "$ENV_:uat" >/dev/null 2>&1 || true
  fi
fi
if [ "$rc" = 0 ]; then
  echo "  uat accepted (as-is journey held)"
else
  echo "  uat REFUSED: the journey is not what was accepted" >&2; exit 1
fi
