#!/bin/sh
# health.sh <base-url> <expected-sha> [samples] -- guard 5. Exit 0, or 7.
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

for app in $(jq -r '.[].app' router/routes.json); do
  path=$(jq -r --arg a "$app" '.[] | select(.app==$a) | .health' router/routes.json)
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
  "$(dirname "$0")/../change/evidence.sh" record "$PR" "$ENV_" healthy "$verdict" "$want" "$base" \
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
