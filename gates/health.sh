#!/bin/sh
# health.sh <base-url> <expected-sha> [samples] -- guard 5.
#
# Exit 0 converged, 7 not converged, 4 I COULD NOT CHECK. The third is not a
# nicety: 0 and 7 are both verdicts about the estate, and a run that could not
# read its own route table has no standing to return either (issue #24).
#
# Asserts CONVERGENCE, not liveness. Two defects the single-sample version had:
#
#   1. It made TWO requests per route -- one for the status code, one for the
#      header -- so during a rolling deploy the first could hit an old replica
#      and the second a new one, and the pair would pass while the estate was
#      mixed. Both facts must come from ONE response.
#   2. One sample cannot distinguish "converged" from "I happened to reach a
#      new replica". A fleet that is 10% migrated passes one sample 10% of the
#      time, which is not a bug you find by re-running.
#
# So: N samples per route, every one must report the expected build. This is
# still only evidence, not proof -- see spec.org, What completes a deployment.
#
# --pr <n> [--env <name>] records the verdict as <env>:healthy. The gate records
# its own result because the gate is the instrument. Without this flag the label
# had to be typed by hand, which is asserting a measurement you did not take --
# and it is exactly what happened on PR #9 (docs/label-ownership.org).
#
# It matters more here than for e2e or smoke: no GitHub runner can reach any
# environment in this repository, so this label is the ONLY evidence the forge
# will ever have that production converged. It is a proxy for the check run a
# reachable environment would have reported.
set -eu
PR=''; ENV_=''
while [ $# -gt 0 ]; do
  case "$1" in
    --pr)  PR="${2:?--pr needs a number}"; shift 2 ;;
    --env) ENV_="${2:?--env needs a name}"; shift 2 ;;
    *)     break ;;
  esac
done
base="$1"; want="$2"; samples="${3:-${HEALTH_SAMPLES:-5}}"; rc=0
MODE="${HEALTH_MODE:-header}"   # header | manifest (static targets)

# THE ROUTE TABLE COMES FROM THIS SCRIPT'S TREE, NOT FROM THE CALLER'S CWD.
#
# This file read `router/routes.json` as a bare relative path, so guard 5 --
# the guard documented as having no bypass, ever, and the only evidence the
# forge gets that production converged -- answered a different question
# depending on the directory it was invoked from (issue #24). Confirmed live
# on staging at e7b0e7d: UNHEALTHY from the main checkout, ok 5/5 from #19's
# worktree, same estate, same build, same command.
#
# The rest of the file already resolved change/evidence.sh from $0. Only the
# thing the verdict depends on was left to the caller.
root=$(cd "$(dirname "$0")/.." && pwd)
ROUTES="$root/router/routes.json"

# AND IT FAILS CLOSED, because the cwd bug's worst outcome was not the wrong
# verdict -- it was a PASS.
#
#   $ cd /anywhere-without-a-checkout
#   $ sh gates/health.sh http://127.0.0.1:1 deadbeef 3
#   jq: error: Could not open file router/routes.json
#   $ echo $?
#   0
#
# `for app in $(jq ...)` does not abort under `set -e` when the command
# substitution fails: the list is empty, the loop body never runs, rc stays 0,
# and the script falls through to the recorder. With --pr that writes the
# evidence record `pass` and adds <env>:healthy -- for a URL nothing was
# listening on, at a SHA that does not exist, having taken zero samples.
#
# That is class 7 exactly: a check that cannot fail produces no verdict, and
# this one produced a verdict anyway. Being unable to read the oracle is "I
# could not determine", which is exit 4, and 4 blocks (docs/exit-codes.org).
refuse() {
  echo "REFUSED: guard 5 cannot establish what to probe." >&2
  echo "  $*" >&2
  echo "  This is not UNHEALTHY and it is not healthy: nothing was sampled." >&2
  echo "  No observation is recorded and no label is touched." >&2
  exit 4
}
[ -f "$ROUTES" ] || refuse "no route table at $ROUTES"
apps=$(jq -r '.[].app' "$ROUTES" 2>/dev/null) \
  || refuse "$ROUTES is not a readable route table"
[ -n "$apps" ] || refuse "$ROUTES declares no apps; there is nothing to converge"

# Name the oracle in the output. `production:healthy` says the estate
# converged and could not say on what; it still cannot say against WHICH route
# table, and that is the variable #24 turned out to hinge on.
echo "guard 5: $(printf '%s\n' "$apps" | grep -c .) apps from $ROUTES, $samples samples each"

probed=0
for app in $apps; do
  path=$(jq -r --arg a "$app" '.[] | select(.app==$a) | .health' "$ROUTES")
  # A declared app with no health path is not a healthy app and is not an
  # unhealthy one either -- it is one this instrument cannot ask about. Before
  # this, `path` became the string "null" and the probe of $base/null 404'd,
  # reporting UNHEALTHY for a defect in the route table.
  [ -n "$path" ] && [ "$path" != null ] \
    || refuse "app '$app' declares no health path in $ROUTES"
  probed=$((probed + 1))
  seen=""; bad=0
  n=1
  while [ "$n" -le "$samples" ]; do
    # Cache-bust. A CDN with max-age=600 serves the OLD build for ten
    # minutes after deploy, and a convergence check that trusts it is
    # measuring the CDN, not the estate (spec.org, Targets).
    bust="$(date +%s)-$n"
    if [ "$MODE" = "manifest" ]; then
      # Static targets (GitHub Pages) cannot set response headers, so the
      # served build is published as a generated file instead.
      body=$(curl -sS --max-time 10 -H "Cache-Control: no-cache" \
               "$base/version.json?_cb=$bust" 2>/dev/null || echo "{}")
      code=$(curl -sS -o /dev/null --max-time 10 -H "Cache-Control: no-cache" \
               -w "%{http_code}" "$base/version.json?_cb=$bust" 2>/dev/null || echo 000)
      sha=$(printf '%s' "$body" | jq -r '.sha // "-"' 2>/dev/null || echo "-")
    else
      # one request, both facts
      resp=$(curl -sS -o /dev/null --max-time 10 -H "Cache-Control: no-cache" \
               -w '%{http_code} %header{x-build-sha}' "$base$path?_cb=$bust" \
               2>/dev/null || echo "000 -")
      code=${resp%% *}; sha=${resp##* }
    fi
    case "$seen" in *" $sha "*) : ;; *) seen="$seen $sha " ;; esac
    if [ "$code" != "200" ] || [ "$sha" != "$want" ]; then bad=$((bad+1)); fi
    n=$((n+1))
  done
  distinct=$(echo "$seen" | tr ' ' '\n' | grep -c . || true)
  if [ "$bad" -gt 0 ]; then
    echo "UNHEALTHY $app: $bad/$samples samples not serving $want (saw:$seen)"
    rc=7
  elif [ "$distinct" -gt 1 ]; then
    echo "UNCONVERGED $app: still serving more than one build (saw:$seen)"
    rc=7
  else
    echo "ok $app $path ($samples/$samples on $want)"
  fi
done

# The loop ran. Belt and braces against the exact shape of the original bug:
# if anything ever makes the app list empty again, this is a refusal rather
# than a silent 0. A gate must not be able to pass by not looking.
[ "$probed" -gt 0 ] || refuse "zero apps were probed"

if [ -n "$PR" ]; then
  repo="${GH_REPO:-${GITHUB_REPOSITORY:-aygp-dr/standard-change}}"
  if [ -z "$ENV_" ]; then
    case "$base" in
      *:9200*) ENV_=staging ;; *:9230*) ENV_=production ;;
      *:9210*) ENV_=production-blue ;; *:9220*) ENV_=production-green ;;
      *)       ENV_=unknown ;;
    esac
  fi
  # "sampled", never "attested": we probed N times and saw one build. Nothing
  # enumerated the instances, because no platform runs this estate.
  # THE RECORD, and it names the build. `production:healthy` says the estate
  # converged and cannot say on what, so gates/production-first.sh had to trust
  # that the labeller withdrew it on every push -- soundness resting on another
  # workflow having fired (issue #16). This comment states the SHA that was
  # sampled, so a guard can check it against the head it is about to merge.
  [ "$rc" = 0 ] && verdict=pass || verdict=fail
  "$root/change/evidence.sh" record "$PR" "$ENV_" healthy "$verdict" "$want" "$base" \
    || { echo "  FAIL could not record the $ENV_:healthy observation for #$PR"; rc=7; }

  if [ "$rc" = 0 ]; then
    gh pr edit "$PR" --repo "$repo" --add-label "$ENV_:healthy" >/dev/null 2>&1 \
      || echo "  WARNING could not set $ENV_:healthy on #$PR -- the record above still stands"
    echo "  #$PR <- $ENV_:healthy  (sampled $samples/$samples on $want at $base)"
  else
    gh pr edit "$PR" --repo "$repo" --remove-label "$ENV_:healthy" >/dev/null 2>&1 || true
    echo "  #$PR: $ENV_:healthy withdrawn -- this instrument observed a failure"
  fi
fi
exit $rc
