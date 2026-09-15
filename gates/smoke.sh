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
    --selftest) SELFTEST=1; shift ;;
    *)    break ;;
  esac
done
base="${1:-${ROUTER_URL:-http://127.0.0.1:9200}}"
cd "$(dirname "$0")/.."
rc=0; pass=0
say()  { printf '  %-34s %s\n' "$1" "$2"; }
fail() { printf '  FAIL %s\n' "$*"; rc=1; }

# The verdict on one wget spider log, as a function so it can be driven offline
# against fixtures. A gate with no negative test is how the defect below
# survived here: `make gate-selftest` proves every other gate can fail, and
# smoke was never in that list.
crawl_verdict() {
  _sp=$1
  _broken=$(grep -E "^ERROR [0-9]+|Found [0-9]+ broken link" "$_sp" | head -20 || true)
  # `|| echo 0` was wrong twice over: grep -c ALREADY prints 0 when it matches
  # nothing, and it exits 1 while doing so, so the fallback fired on top of a
  # value already captured and urls became the two-line string "0\n0".
  # Measured -- which is how we know nobody had ever run this path.
  _urls=$(grep -c "URL:" "$_sp" 2>/dev/null) || _urls=0

  # THE CRAWL MUST PROVE IT RAN. wget prints "Found no broken links." when it
  # crawled nothing whatsoever. Measured against a dead port 9077, the spider
  # log is exactly:
  #
  #     failed: Connection refused.
  #     Found no broken links.
  #
  # -- and this gate scored that a PASS. Zero broken links out of zero URLs is
  # a vacuous truth: spec.org defect class 7, a check that cannot fail produces
  # no verdict. The reachability precheck below does NOT cover it, because that
  # probes "$base/" with curl while the crawl is a separate wget over the whole
  # estate; every app behind a live router can be down between the two.
  #
  # `_urls` is the term that MUST appear if the crawl happened, so its absence
  # is a refusal rather than a pass. Peer standard-change-002 reached the same
  # rule from a FreeBSD `ss` that was never installed: read total silence as
  # "the command failed", never as "the set is empty".
  if [ "$_urls" -eq 0 ]; then
    fail "the crawl visited 0 urls -- 'no broken links' here is vacuous, not a pass"
    sed 's/^/       /' "$_sp" | head -5
  elif [ -n "$_broken" ]; then
    echo "$_broken" | sed 's/^/  FAIL /'
    rc=1
  else
    say "no broken links" "$_urls urls crawled"
    pass=$((pass + 1))
  fi
}

# --selftest: prove the crawl verdict can fail, in BOTH of its failing
# directions, before any run of it is allowed to count.
if [ "${SELFTEST:-0}" = 1 ]; then
  st=0
  _log=$(mktemp -t smoke-selftest)
  for _case in pass:0 fail:1 broken:1; do
    _dir=${_case%:*}; _want=${_case#*:}
    rc=0; pass=0
    # NOT $( ): a command substitution is a subshell, so the rc=1 the verdict
    # sets would never reach this loop and every case would score 0. The first
    # run of this selftest did exactly that -- printing the right FAIL lines
    # while reporting them as passes. Redirect to a file instead; that stays in
    # this shell.
    crawl_verdict "gates/fixtures/smoke/$_dir/spider.txt" > "$_log" 2>&1
    if [ "$rc" = "$_want" ]; then
      printf '  ok    %-8s rc=%s\n' "$_dir" "$rc"
    else
      printf '  FAIL  %-8s rc=%s want=%s\n' "$_dir" "$rc" "$_want"
      sed 's/^/          /' "$_log"
      st=1
    fi
  done
  rm -f "$_log"
  [ "$st" = 0 ] && echo "  smoke crawl: both directions confirmed"
  exit "$st"
fi

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
# NOT `|| echo 0` -- the same defect fixed in the crawl verdict below, and
# this site is worse. grep -c prints 0 AND exits 1 when it matches nothing, so
# the fallback appended a second 0 and pass became "0\n0". That happens exactly
# when EVERY journey step failed, and the next `pass=$((pass + 1))` then dies
# with "arithmetic expression: variable conversion error" under set -e.
# Measured: the gate exits 2, not 1, when the estate is at its most broken --
# and 2 is a code this project has already spent on "lock held" (preflight.sh,
# docs/exit-codes.org). A gate that crashes instead of refusing hands its
# caller an exit code that means something else somewhere else.
pass=$(grep -c '^  [^F]' .smoke.journey) || pass=0
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
crawl_verdict "$spider"
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
  if [ "$rc" = 0 ]; then add="$ENV_:smoke"; rm_="$ENV_:smoke-failed"; verdict=pass
  else                   add="$ENV_:smoke-failed"; rm_="$ENV_:smoke"; verdict=fail; fi

  # THE RECORD, and it names the build -- see gates/e2e.sh and change/evidence.sh.
  # The label says smoke passed; only this says on what. Not swallowed: a
  # measurement nobody could record is not a measurement.
  ./change/evidence.sh record "$PR" "$ENV_" smoke "$verdict" "${sha:-unknown}" "$base" \
    || { echo "  FAIL could not record the $ENV_:smoke observation for #$PR"; rc=1; }

  gh pr edit "$PR" --repo "$repo" --add-label "$add" --remove-label "$rm_" >/dev/null 2>&1 \
    || gh pr edit "$PR" --repo "$repo" --add-label "$add" >/dev/null 2>&1 \
    || echo "  WARNING could not set $add on #$PR -- the record above still stands"
  echo "  #$PR <- $add  (observed on $base at build ${sha:-unknown})"
fi
exit "$rc"
