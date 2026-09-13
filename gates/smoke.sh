#!/bin/sh
# smoke.sh [url] -- the fourth gate. Does a person get a working site?
#
# e2e.sh asserts CONTRACTS: this path is owned by that app, this header is set,
# this status is returned. Everything can be contract-correct and the site can
# still be broken for a human -- a link to a page that does not exist, a page
# that returns 200 with no body, an <a href> pointing at an app that is down.
#
# This gate is the other question. It walks the estate the way a browser does:
# it asks for HTML, it follows the links it finds, and it complains about what
# a person would notice. Cheap stand-in for Playwright, which cannot run on
# FreeBSD at all (playwright-core throws Unsupported platform at module init,
# spec.org, refuted 2026-09-13).
#
# Exit 0 = the site works. Exit 1 = something a person would hit is broken.
#
# --pr <n> records the result on the pull request as an OBSERVATION label,
# staging:smoke or staging:smoke-failed. The gate labels its own result because
# the gate is the instrument: anyone else adding it is asserting a measurement
# they did not take.
set -eu
PR=''
ENV_=''
while [ $# -gt 0 ]; do
  case "$1" in
    --pr)  PR="${2:?--pr needs a number}"; shift 2 ;;
    --env) ENV_="${2:?--env needs a name}"; shift 2 ;;
    *)    break ;;
  esac
done
base="${1:-${ROUTER_URL:-http://127.0.0.1:9200}}"
cd "$(dirname "$0")/.."
rc=0; pass=0
say()  { printf '  %-34s %s\n' "$1" "$2"; }
fail() { printf '  FAIL %s\n' "$*"; rc=1; }

# Always ask as a browser. A JSON-only estate passes every contract test and is
# unusable, which is exactly what the bastille jails turned out to be.
H='Accept: text/html,application/xhtml+xml'
page()  { curl -s  --max-time 5 -H "$H" "$base$1"; }
whichapp() { curl -sI --max-time 5 -H "$H" "$base$1" | tr -d '\r' \
               | awk 'tolower($1)=="x-app:"{print $2}'; }
code()  { curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "$H" "$base$1"; }
ctype() { curl -sI --max-time 5 -H "$H" "$base$1" | tr -d '\r' \
            | awk 'tolower($1)=="content-type:"{print $2}'; }

# ---- 1. the journey, as a person walks it ------------------------------------
#
# Ten steps, in order, each depending on the last being a real page. Not ten
# independent probes: the point is that a session through the estate holds up.
journey() {
cat <<'STEPS'
/	home
/search?q=shoes	search results
/c/shoes	category
/p/SKU123	product
/cart	cart
/checkout	checkout
/checkout/payment	payment
/checkout/confirm	confirmation
/account	account
/about	about
STEPS
}

# Refuse to report on something that is not there. Without this the first
# curl fails, set -e kills the script mid-journey, and the caller gets curl's
# exit 7 with no line saying what went wrong.
if ! curl -s -o /dev/null --max-time 5 "$base/" 2>/dev/null; then
  echo "smoke: $base"
  fail "nothing is listening at $base -- no estate to smoke test"
  exit 1
fi

echo "smoke: $base"
journey | while IFS="$(printf '\t')" read -r path label; do
  c=$(code "$path"); m=$(ctype "$path"); body=$(page "$path")
  n=$(printf '%s' "$body" | wc -c | tr -d ' ')
  if [ "$c" != "200" ]; then
    fail "$label ($path) returned $c"
  elif [ "${m%%;*}" != "text/html" ]; then
    fail "$label ($path) returned ${m:-no content-type}, a person needs text/html"
  elif [ "$n" -lt 200 ]; then
    fail "$label ($path) returned 200 with only $n bytes -- an empty page is not a page"
  else
    say "$label" "200 html ${n}b"
  fi
done > .smoke.journey 2>&1
cat .smoke.journey
grep -q '^  FAIL' .smoke.journey && rc=1
pass=$(grep -c '^  [^F]' .smoke.journey || echo 0)
rm -f .smoke.journey

# ---- 1b. is this an estate, or one app wearing it? ---------------------------
#
# Every app serves HTML for every path (OneUI's page() renders whatever it is
# handed), so pointing this gate at a SINGLE app passes the whole journey: ten
# green steps, all served by one process. Found while writing the negative test
# for this gate -- :9205 is the mock app alone and it sailed through.
#
# A journey that never crosses an app boundary has not exercised the estate.
# This does not duplicate e2e's ownership check; it asserts the weaker thing
# that makes the journey meaningful at all.
apps=$(for p in / /search /p/SKU123 /checkout; do whichapp "$p"; done | sort -u | tr '\n' ' ')
n_apps=$(printf '%s' "$apps" | wc -w | tr -d ' ')
if [ "$n_apps" -ge 3 ]; then
  say "journey crosses apps" "$n_apps distinct: $apps"
  pass=$((pass + 1))
else
  fail "the whole journey was served by $n_apps app(s) [$apps] -- this is one app, not an estate"
  rc=1
fi

# ---- 2. every link on every page must resolve --------------------------------
#
# The reason this gate exists. Apps link to each other (/about, /contact, /jobs
# live on core; product pages link back to category pages on plp), so a link is
# a cross-app dependency that no single app's tests can see. A 404 behind an
# <a href> is invisible to a contract test and obvious to a person.
echo "  -- following every link --"
spider=$(mktemp -t smoke)
wget --spider --recursive --level=3 --no-verbose --no-directories \
     --header="$H" --tries=1 --timeout=5 \
     --reject-regex '(logout|\?)' "$base/" 2>&1 > /dev/null | tee "$spider" >/dev/null || true

# wget prints "Found no broken links." on SUCCESS and "Found 3 broken links."
# on failure, so matching the substring "broken link" reports a pass as a
# failure -- which is what the first run of this gate did. Match the count.
broken=$(grep -E "^ERROR [0-9]+|Found [0-9]+ broken link" "$spider" | head -20 || true)
urls=$(grep -c "URL:" "$spider" 2>/dev/null || echo 0)
if [ -n "$broken" ]; then
  echo "$broken" | sed 's/^/  FAIL /'
  rc=1
else
  say "no broken links" "$urls urls crawled"
  pass=$((pass + 1))
fi
rm -f "$spider"

echo
if [ "$rc" = 0 ]; then echo "  smoke passed"; else echo "  SMOKE FAILED"; fi

# Record it. The label names WHAT was observed, not just that something passed:
# `staging:passed` cannot say whether the contract gate or the browser journey
# was the thing that ran, and that ambiguity was used once today to satisfy a
# guard with a measurement from a different estate.
if [ -n "$PR" ]; then
  repo="${GH_REPO:-${GITHUB_REPOSITORY:-aygp-dr/standard-change}}"
  sha=$(curl -sI --max-time 5 "$base/" | tr -d '\r' \
          | awk 'tolower($1)=="x-build-sha:"{print $2}')
  # The label must name the environment it observed. Hardcoding "staging" made
  # a run against the PRODUCTION front record staging:smoke -- the same
  # ambiguity that let one estate's pass overwrite another's failure, one level
  # up. Derived from --env, or from the port when it is one we know.
  if [ -z "$ENV_" ]; then
    case "$base" in
      *:9200*) ENV_=staging ;;
      *:9230*) ENV_=production ;;
      *:9210*) ENV_=production-blue ;;
      *:9220*) ENV_=production-green ;;
      *)       ENV_=unknown ;;
    esac
  fi
  if [ "$rc" = 0 ]; then add="$ENV_:smoke"; rm_="$ENV_:smoke-failed"
  else                   add="$ENV_:smoke-failed"; rm_="$ENV_:smoke"; fi
  gh pr edit "$PR" --repo "$repo" --add-label "$add" --remove-label "$rm_" >/dev/null 2>&1 \
    || gh pr edit "$PR" --repo "$repo" --add-label "$add" >/dev/null 2>&1 || true
  echo "  #$PR <- $add  (observed on $base at build ${sha:-unknown})"
fi
exit "$rc"
