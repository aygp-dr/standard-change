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

# THE SAMPLE LEDGER. Every sample this gate takes is written down as it is
# taken -- app, route, http code, and the build the response actually named --
# and change/marker.sh derives its verdict by reading THIS, not by being told a
# count. v1 of the marker took `--samples 5` as a string from here and rendered
# it as an observation; `--samples 0` produced a "converged" verdict with no
# measurement behind it at all (docs/interfaces.org, "THE ORACLE IS INDEPENDENT
# OF THE CALLER"). A file the instrument wrote while measuring is the smallest
# thing that is not the caller's word.
LEDGER=$(mktemp "${TMPDIR:-/tmp}/health-samples.XXXXXX")
trap 'rm -f "$LEDGER"' EXIT INT TERM
# Estate-wide totals, three-valued. `bad` below is still matched-vs-not and the
# gate's verdict is unchanged; these exist because "could not reach" and
# "serving something else" are different facts and only one of them is evidence.
est_matched=0; est_diverged=0; est_unobs=0

for app in $(jq -r '.[].app' router/routes.json); do
  path=$(jq -r --arg a "$app" '.[] | select(.app==$a) | .health' router/routes.json)
  seen=""; bad=0; a_matched=0; a_diverged=0; a_unobs=0
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
    # THREE-VALUED, and this is the whole point of the classification below.
    # A sample is a BUILD OBSERVATION only if the request succeeded and the
    # response named a build. Anything else is an ABSENCE: this instrument
    # could not look. Collapsing the two is docs/label-ownership.org rule 2,
    # and v1 of the marker published that collapse -- "could not observe" went
    # out on a permanent timeline as "observed to be false". `bad` above is
    # deliberately untouched, so the GATE's verdict is bit-for-bit what it was.
    if [ "$code" != "200" ] || [ -z "$sha" ] || [ "$sha" = "-" ]; then
      a_unobs=$((a_unobs+1))
    elif [ "$sha" = "$want" ]; then
      a_matched=$((a_matched+1))
    else
      a_diverged=$((a_diverged+1))
    fi
    printf '%s\t%s\t%s\t%s\n' "$app" "$path" "$code" "$sha" >> "$LEDGER"
    n=$((n+1))
  done
  est_matched=$((est_matched+a_matched))
  est_diverged=$((est_diverged+a_diverged))
  est_unobs=$((est_unobs+a_unobs))
  distinct=$(echo "$seen" | tr ' ' '\n' | grep -c . || true)
  if [ "$bad" -gt 0 ]; then
    # Same verdict, a truthful sentence. "not serving $want" was said of a route
    # that returned nothing at all, which is a claim about the estate this gate
    # was in no position to make.
    if [ "$a_diverged" = 0 ]; then
      echo "UNREACHABLE $app: $a_unobs/$samples samples returned no build at all" \
           "-- could NOT observe, not observed to be wrong (saw:$seen)"
    elif [ "$a_unobs" = 0 ]; then
      echo "DIVERGED $app: $a_diverged/$samples samples served another build, not $want (saw:$seen)"
    else
      echo "DIVERGED $app: $a_diverged served another build, $a_unobs returned no build," \
           "$a_matched on $want (saw:$seen)"
    fi
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
  # main's own derivation, restored verbatim. The marker's environment is
  # derived separately below: the marker needs a name for dev blocks, and the
  # PR label must NOT -- `dev-7:healthy` is a label name nothing in this repo
  # declares, and `gh pr edit --add-label` on an undeclared name is a write
  # this change has no standing to introduce.
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

# THE DEPLOYMENT MARKER, and it is emitted HERE for one reason: this loop is
# the only place in the repository where "the estate is serving X" is a FACT
# rather than a plan. Every other candidate site knows an intention.
#
#   targets/node/deploy.sh   knows it started processes
#   switch.sh                knows it flipped a file and the front agreed
#   change/settle.sh         knows the paperwork closed
#   HERE                     sampled N times per route and wrote down each one
#
# Marking from any of the first three would put "deployed" on a timeline at a
# moment when nothing had checked, which is the deadbee shape with a longer
# half-life: docs/changing-the-pipeline.org finding 9 was caught in an hour
# because someone re-ran it, and a marker is never re-run.
#
# THREE VERDICTS, NOT TWO. v1 emitted `unconverged` whenever $rc was non-zero,
# which put "could not observe" on a permanent timeline as "observed to be
# false" -- docs/label-ownership.org rule 2, on the most durable artefact the
# pipeline produces. It is not hypothetical: deploy-production.yml runs this
# gate on ubuntu-latest, which cannot open a socket to any environment in this
# repository, so the FIRST marker enabled in a workflow would have been a
# permanent false negative. Now that run marks `unreachable`, which carries
# kind=abstention and claims nothing about the estate.
#
# Precedence when a run is mixed: positive evidence outranks absence. A sample
# that actually saw build X is a fact; a sample that saw nothing is not.
#
# AND THE VERDICT IS NOT $rc. It is derived from the sample counters, which no
# paperwork failure can touch. Below, a failed `evidence.sh record` or a 5xx
# from `gh` sets rc=7 -- and the estate may have been perfectly converged. v1
# read $rc and would have marked that estate `unconverged`: a ledger failure
# rendered as an estate observation. marker.sh then RE-DERIVES the same verdict
# from the ledger file itself and refuses to emit if the two disagree.
#
# OPT-IN, TWICE, and the beacon inside marker.sh is a third opt-in of its own.
# MARKERS=1 renders the marker; MARKER_SEND=1 delivers it. Rendering without
# sending is the default because a marker is an outward-facing write to a live
# third party and no gate should perform one by surprise.
# MARKERS is read first and alone: `MARKERS=0 MARKER_SEND=1` used to render
# nothing while looking like it had been asked to send, so MARKER_SEND=1 now
# implies rendering.
if [ "${MARKERS:-0}" != 0 ] || [ "${MARKER_SEND:-0}" != 0 ]; then
  if   [ "$est_diverged" -gt 0 ]; then ev=diverged
  elif [ "$est_unobs"    -gt 0 ]; then ev=unreachable
  else                                 ev=converged
  fi
  # The marker needs a name for a dev block; the PR label above must not have
  # one (dev-7:healthy is undeclared). Two derivations, on purpose.
  mark_env="$ENV_"
  if [ -z "$mark_env" ] || [ "$mark_env" = unknown ]; then
    case "$base" in
      *:9200*) mark_env=staging ;; *:9230*) mark_env=production ;;
      *:9210*) mark_env=production-blue ;; *:9220*) mark_env=production-green ;;
      *:90[0-9]0*) mark_env="dev-$(printf '%s' "$base" | sed -n 's/.*:90\([0-9]\)0.*/\1/p')" ;;
      *)       mark_env=unknown ;;
    esac
  fi
  # The link. In this estate the deploy does NOT run in GitHub Actions -- no
  # runner can reach hydra (docs/label-ownership.org, rule 2) -- so the best
  # available link is the GATE run for this SHA, not the deploy that produced
  # it. link_is says which, rather than letting a reader assume the stronger one.
  link="${MARKER_LINK:-}"; link_is="${MARKER_LINK_IS:-gate-run}"
  if [ -z "$link" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
    link="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-aygp-dr/standard-change}/actions/runs/$GITHUB_RUN_ID"
  fi
  # jq's status through a pipe is the PIPE's, i.e. tr's, which always succeeds;
  # a bad routes.json would yield an empty app list rather than a failure. Same
  # defect class as the `| sed` that shipped an UNHEALTHY estate as passed
  # (docs/interfaces.org, indent()).
  if apps=$(jq -r '.[].app' router/routes.json); then
    apps=$(printf '%s' "$apps" | tr '\n' ' ')
  else
    echo "  marker: could not read router/routes.json for the app list; sending none" >&2
    apps=''
  fi
  # A SINK IS NOT A GUARD. The deployment's verdict is $rc and nothing below may
  # change it. But `|| true` is how a timeline gets holes nobody knows about,
  # and a blanket "spooled, recoverable" message is worse than silence when
  # nothing was spooled: it points an operator at a file that was never written.
  # So the codes are split. ONLY 75 spools.
  mrc=0
  "$(dirname "$0")/../change/marker.sh" "$ev" --env "$mark_env" --sha "$want" \
      --base "$base" --observed-by gates/health.sh --measurement "$LEDGER" \
      --apps "$apps" ${PR:+--pr "$PR"} ${link:+--link "$link" --link-is "$link_is"} \
      --note "$MODE mode; every route sampled $samples times" || mrc=$?
  case "$mrc" in
    0) : ;;
    75) echo "  marker: NOT DELIVERED (75, sink unreachable). The deployment verdict is
  unchanged ($rc). The payload WAS spooled to .run/markers-undelivered.jsonl and
  the hole is recoverable from there. Not swallowed." >&2 ;;
    *)  echo "  marker: REFUSED (rc $mrc). The deployment verdict is unchanged ($rc).
  NOTHING WAS SPOOLED and nothing is recoverable -- this build has no point on
  the timeline at all. See docs/exit-codes.org for what $mrc means, and
  change/marker.sh --selftest to reproduce the refusal offline." >&2 ;;
  esac
fi
exit $rc
