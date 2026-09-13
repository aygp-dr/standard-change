#!/bin/sh
# marker.sh <event> [options] -- put a deployment marker on a telemetry timeline.
#
# WHAT THIS IS FOR. Somebody, six weeks from now, is looking at a latency graph
# with a step in it and wants to know what changed. A deployment marker is the
# annotation that answers that. Every APM does this -- New Relic deployments,
# Datadog version tags, Grafana annotations, Honeycomb markers, Sentry deploys
# -- and docs/deployment-markers.org compares their shapes.
#
# WHAT MAKES IT DANGEROUS. The marker outlives everything around it. The logs
# rotate, the labels are cleared at settlement, the PR is archived; the marker
# stays on the timeline and is read years later by someone who cannot check it.
# So a marker that says "deployed" when it means "began deploying" is not a
# rounding error -- it is a false statement placed exactly where a person will
# trust it during an incident.
#
# That is this repository's recurring defect, in its most durable form:
#
#   docs/changing-the-pipeline.org  guard 5 passed on `deadbee` because the
#                                   deployer wrote the manifest the guard read
#                                   back. The subject supplied its own evidence.
#   docs/label-ownership.org        rule 1: an observation may be recorded only
#                                   by the instrument that took it.
#                                   rule 2: unreachable is not falsified.
#   docs/interfaces.org             "THE ORACLE IS INDEPENDENT OF THE CALLER",
#                                   which names THIS SCRIPT as the defect: v1
#                                   took --observed-by and --samples as strings
#                                   and rendered them as an observation. A
#                                   script that accepts "I saw 5/5 healthy" as
#                                   input is a logging API, not an oracle.
#
# THE FOUR RULES THIS FILE ENFORCES, mechanically, not by convention:
#
#   1. THE VERDICT IS DERIVED FROM THE MEASUREMENT, NOT FROM THE ARGUMENT.
#      An observation marker requires --measurement <file>: the SAMPLE LEDGER
#      the instrument wrote as it took each sample, one row per sample,
#
#          <app>TAB<route>TAB<http-code>TAB<build-served-or-empty>
#
#      This script counts the rows itself, classifies each one itself, and
#      computes the verdict itself. The event name on the command line is then
#      a CROSS-CHECK: if the caller's event and the derived verdict disagree,
#      the marker is REFUSED and both are printed. Two independent derivations
#      have to agree before anything reaches a timeline. `--samples 7` is gone;
#      there is nothing left for a caller to assert a count with.
#
#   2. UNREACHABLE IS NOT FALSIFIED, AND THERE ARE THREE VERDICTS.
#      v1 had `unconverged`, which collapsed "I looked and saw a different
#      build" into "I could not look at all". That is exactly the collapse
#      docs/label-ownership.org rule 2 exists to forbid, promoted onto the most
#      durable artefact in the pipeline. `unconverged` is now a REFUSED event
#      name. The three are:
#
#          converged    every sample served the marked build
#          diverged     a sample POSITIVELY served a different build
#          unreachable  samples returned no usable build observation
#
#      Precedence, when a run is mixed: positive evidence outranks absence. One
#      sample that actually saw build X is a fact; a sample that saw nothing is
#      not a fact about the estate. So diverged wins over unreachable.
#      `unreachable` carries kind=abstention, not kind=observation, so a reader
#      cannot mistake it for a claim about what the estate was serving.
#
#   3. THE REVISION MUST BE A COMMIT THAT EXISTS. targets/node/deploy.sh refuses
#      a SHA that does not resolve, for the deadbee reason. A marker naming a
#      fabricated build is the same lie with a longer half-life, so it refuses
#      too. --no-verify-sha exists for marking a build from a ref this checkout
#      does not have, and it STAMPS THAT IN THE PAYLOAD (revision_verified:false)
#      rather than quietly lowering the standard.
#
#   4. WHAT THE CALLER MERELY ASSERTED IS NAMED AS SUCH, IN THE RECORD.
#      Some fields genuinely cannot be measured here: the environment's name,
#      the service, the note, the link. Those are listed by name in the payload
#      under `caller_supplied`, so a reader six weeks out can tell a measurement
#      from an assertion without having this file in front of them.
#      --observed-by is checked as far as it can be -- it must name a file that
#      exists in this repository, which refuses `--observed-by my-own-fingers`
#      -- and it is STILL listed as caller-supplied, because "that path exists"
#      is not "that program took this measurement".
#
# DRY RUN IS THE DEFAULT. A marker is an outward-facing write to a live third
# party. Nothing leaves this host unless MARKER_SEND=1 or --send is given.
#
# A SINK IS NOT A GUARD. If the beacon is unreachable the deployment must not
# fail -- telemetry does not get a veto over the estate. But `|| true` on a
# marker is how you get a timeline with holes nobody knows about, which is
# strictly worse than no timeline, because the holes are invisible. So on
# non-delivery this prints MARKER UNDELIVERED loudly, appends the payload to
# .run/markers-undelivered.jsonl so the hole is recoverable, and exits 75
# (EX_TEMPFAIL). ONLY exit 75 spools. Every other refusal happens before any
# payload exists, and the call sites say "refused, nothing spooled" for those
# rather than pointing an operator at a file that was never written.
#
# THE BEACON. Separately from the sink, recording a marker fires a one-pixel
# NOTIFICATION -- see "The beacon" below. It is a ping about the record; the
# record is the evidence. Its response is never read as evidence about the
# deployment and it can never change this script's exit code.
#
# WHAT IS NOT SENT. This is a simulation estate and the sink is public: SHA,
# environment name, port, timestamp, PR number, app list, this host's short
# name. No tokens, no user identity, no addresses. The base URL a gate probed
# is reduced to its PORT (--base http://192.168.86.30:9070 sends {"port":9070}),
# because the port tier is the fact worth having and the address is not.
#
# EXIT CODES -- registered in docs/exit-codes.org, no code of its own invented:
#   0   the marker was rendered (dry run) or delivered
#   1   refused: the evidence does not support the marker asked for
#   2   usage: unknown event, unknown flag, or a marker with no place to go
#   3   the revision is not a commit in this repository
#   4   I could not check: the measurement ledger could not be read
#   75  EX_TEMPFAIL, the sink is unreachable; payload spooled, caller tolerates
set -eu

SINK="${MARKER_SINK:-https://beacon.termbox.org/webhook}"
HEALTH="${MARKER_HEALTH:-https://beacon.termbox.org/health.json}"
SOURCE="${MARKER_SOURCE:-standard-change}"
REPO="${GH_REPO:-${GITHUB_REPOSITORY:-aygp-dr/standard-change}}"
# THE BEACON'S BASE IS CONFIGURATION, NOT A CONSTANT, and no host is named in
# this file. Unset is the default and means MOCK: nothing leaves the machine.
# An example value lives in .env.template, commented out. A v2 that points at
# an internal collector is then a config change, not a patch to this script --
# which is also why the variable names the FACT (a deployment marker) and not
# the MECHANISM (a 1x1 gif); the mechanism is the part most likely to change.
BEACON_BASE="${DEPLOYMENT_MARKER_BASE:-}"
root=$(cd "$(dirname "$0")/.." && pwd)

usage() {
  cat >&2 <<'USAGE'
usage:
  marker.sh started     --env <name> --sha <sha> [--pr n] [--apps "a b"] [--link url] [--link-is kind]
  marker.sh converged   --env <name> --sha <sha> --observed-by <path> --measurement <file> [--base url] ...
  marker.sh diverged    --env <name> --sha <sha> --observed-by <path> --measurement <file> [--base url] ...
  marker.sh unreachable --env <name> --sha <sha> --observed-by <path> --measurement <file> [--base url] ...
  marker.sh --selftest

  --send            actually POST. Default is dry run: print the payload, send nothing.
                    MARKER_SEND=1 does the same.
  --no-verify-sha   mark a revision this checkout cannot resolve; stamped as
                    revision_verified:false in the payload.
  --measurement <f> the sample ledger the instrument wrote WHILE MEASURING, one
                    row per sample:  app TAB route TAB http-code TAB build.
                    The verdict is computed from this file. The event name above
                    must agree with what it computes, or the marker is refused.

events:
  started       kind=intent.      "a deploy of this build began." Never a success claim.
  converged     kind=observation. every sample served the marked build.
  diverged      kind=observation. a sample POSITIVELY served a different build.
  unreachable   kind=abstention.  no usable build observation was obtained.
                                  This is NOT a claim that the estate is wrong.
USAGE
  exit 2
}

[ $# -gt 0 ] || usage
case "$1" in
  --selftest) selftest=1; shift ;;
  -h|--help)  usage ;;
  *)          selftest=0 ;;
esac

if [ "${selftest:-0}" = 1 ]; then
  # THE NEGATIVE TEST. Repo invariant: a check that cannot reject its own bad
  # input produces no verdict. Everything here fails BEFORE any network call,
  # and DEPLOYMENT_MARKER_BASE is unset for every case that does not set it, so
  # this runs offline, in CI, on a host that has never heard of the beacon.
  fails=0
  work=$(mktemp -d "${TMPDIR:-/tmp}/marker-selftest.XXXXXX")
  trap 'rm -rf "$work"' EXIT INT TERM
  real=$(git -C "$root" rev-parse --short HEAD)

  # Ledgers. These are the artefact an instrument writes WHILE measuring; the
  # whole point of the redesign is that these, not an argument, decide.
  printf '%s\t/a/health\t200\t%s\n' core "$real" >  "$work/all-matched.tsv"
  printf '%s\t/b/health\t200\t%s\n' plp  "$real" >> "$work/all-matched.tsv"
  printf '%s\t/a/health\t200\t%s\n' core 0000000 >  "$work/other-build.tsv"
  printf '%s\t/a/health\t000\t\n'   core         >  "$work/no-response.tsv"
  printf '%s\t/a/health\t200\t\n'   core         >> "$work/no-response.tsv"
  # Mixed on purpose: one matched, one that POSITIVELY saw another build, one
  # that saw nothing. The precedence rule says this is `diverged`.
  printf '%s\t/a/health\t200\t%s\n' core "$real" >  "$work/mixed.tsv"
  printf '%s\t/b/health\t200\t%s\n' plp  0000000 >> "$work/mixed.tsv"
  printf '%s\t/c/health\t000\t\n'   pdp          >> "$work/mixed.tsv"
  : > "$work/empty.tsv"
  printf 'core\t/a/health\n'                     >  "$work/malformed.tsv"

  t() { # t <description> <expected-rc> <pattern|!pattern|-> <args...>
    d="$1"; want="$2"; pat="$3"; shift 3
    rc=0; out=$(DEPLOYMENT_MARKER_BASE="${SELFTEST_BEACON_BASE:-}" sh "$0" "$@" 2>&1) || rc=$?
    why=''
    [ "$rc" = "$want" ] || why="rc $rc, wanted $want"
    case "$pat" in
      -)  : ;;
      !*) echo "$out" | grep -q -- "${pat#!}" && why="${why:+$why; }output matched '${pat#!}' and must not" ;;
      *)  echo "$out" | grep -q -- "$pat" || why="${why:+$why; }output did not match '$pat'" ;;
    esac
    if [ -z "$why" ]; then printf '  ok   %s\n' "$d"
    else printf '  FAIL %s (%s)\n' "$d" "$why"; fails=$((fails+1)); fi
  }

  echo "marker-selftest: the refusals"
  t "rejects a revision that is not a commit"  3 "not a commit" \
      started --env dev-7 --sha deadbee
  t "rejects an unknown event name"            2 "is not a marker event" \
      deployed --env dev-7 --sha "$real"
  t "rejects 'unconverged', which collapsed two verdicts into one" 2 "could not look" \
      unconverged --env dev-7 --sha "$real"
  t "rejects a marker with no environment"     2 "not placeable" \
      started --sha "$real"
  t "rejects an observation with no instrument named" 1 "must name the instrument" \
      converged --env dev-7 --sha "$real" --measurement "$work/all-matched.tsv"
  t "rejects an instrument that is not a file in this repository" 1 "does not exist here" \
      converged --env dev-7 --sha "$real" --observed-by my-own-fingers \
      --measurement "$work/all-matched.tsv"
  t "rejects an observation with no measurement at all" 1 "must carry the measurement" \
      converged --env dev-7 --sha "$real" --observed-by gates/health.sh
  t "rejects a measurement file it cannot read"  4 "could not read" \
      converged --env dev-7 --sha "$real" --observed-by gates/health.sh \
      --measurement "$work/does-not-exist.tsv"
  t "rejects a measurement with zero samples in it" 1 "zero samples" \
      converged --env dev-7 --sha "$real" --observed-by gates/health.sh \
      --measurement "$work/empty.tsv"
  t "rejects a malformed measurement row"      1 "malformed" \
      converged --env dev-7 --sha "$real" --observed-by gates/health.sh \
      --measurement "$work/malformed.tsv"
  t "rejects 'converged' over a measurement that saw another build" 1 "measurement says diverged" \
      converged --env dev-7 --sha "$real" --observed-by gates/health.sh \
      --measurement "$work/other-build.tsv"
  t "rejects 'converged' over a measurement that saw nothing" 1 "measurement says unreachable" \
      converged --env dev-7 --sha "$real" --observed-by gates/health.sh \
      --measurement "$work/no-response.tsv"
  t "rejects 'diverged' over a measurement that fully matched" 1 "measurement says converged" \
      diverged --env dev-7 --sha "$real" --observed-by gates/health.sh \
      --measurement "$work/all-matched.tsv"
  t "rejects 'unreachable' when a sample positively saw another build" 1 "measurement says diverged" \
      unreachable --env dev-7 --sha "$real" --observed-by gates/health.sh \
      --measurement "$work/other-build.tsv"
  t "rejects evidence attached to an intent marker" 1 "may not carry evidence" \
      started --env dev-7 --sha "$real" --measurement "$work/all-matched.tsv"

  echo "marker-selftest: and the passes"
  t "renders a well-formed intent marker"      0 '"kind": "intent"' \
      started --env dev-7 --sha "$real"
  t "renders converged from a measurement that converged" 0 '"samples_matched": 2' \
      converged --env dev-7 --sha "$real" --observed-by gates/health.sh \
      --measurement "$work/all-matched.tsv"
  t "renders diverged, naming the build it actually saw" 0 '"0000000"' \
      diverged --env dev-7 --sha "$real" --observed-by gates/health.sh \
      --measurement "$work/other-build.tsv"
  t "renders unreachable as an ABSTENTION, not an observation" 0 '"kind": "abstention"' \
      unreachable --env dev-7 --sha "$real" --observed-by gates/health.sh \
      --measurement "$work/no-response.tsv"
  t "a mixed run marks diverged: positive evidence outranks absence" 0 '"samples_unobserved": 1' \
      diverged --env dev-7 --sha "$real" --observed-by gates/health.sh \
      --measurement "$work/mixed.tsv"
  t "accepts an unverifiable revision when told"  0 '"revision_verified": false' \
      started --env dev-7 --sha deadbee --no-verify-sha
  t "names in the record which fields the caller merely asserted" 0 'caller_supplied' \
      started --env dev-7 --sha "$real"

  echo "marker-selftest: the beacon, which is a notification and never an oracle"
  t "MOCK by default: no request, and the log SAYS a beacon would have gone" \
      0 "beacon: MOCK" started --env dev-7 --sha "$real"
  t "the mock still shows the exact query string that would be sent" \
      0 "would GET .*?marker=deploy.started" started --env dev-7 --sha "$real"
  t "the marker token is percent-encoded, not concatenated raw" \
      0 "marker=deploy.started%3Adev%207%26x%3A" started --env "dev 7&x" --sha "$real"
  t "and no raw separator survives into the query string" \
      0 '!marker=deploy.started:' started --env "dev 7&x" --sha "$real"
  SELFTEST_BEACON_BASE=https://example.invalid/static/pixel.gif \
    t "a configured base is shown in full on the dry-run path" \
      0 "would GET https://example.invalid/static/pixel.gif?marker=" \
      started --env dev-7 --sha "$real"
  SELFTEST_BEACON_BASE=wal.sh/static/pixel.gif \
    t "a base that is not an absolute http(s) URL is a CONFIG ERROR, reported" \
      0 "BEACON MISCONFIGURED" started --env dev-7 --sha "$real"
  SELFTEST_BEACON_BASE='https://example.invalid/p.gif?x=1' \
    t "a base that already carries a query string is refused, not mangled" \
      0 "BEACON MISCONFIGURED" started --env dev-7 --sha "$real"
  SELFTEST_BEACON_BASE=https://example.invalid/p.gif \
    t "a misconfigured or unreachable beacon cannot change the exit code" \
      0 "!MARKER UNDELIVERED" started --env dev-7 --sha "$real"

  # Dry run must not touch the network. Point BOTH the sink and the beacon at a
  # black hole and require success: if either tried, it would fail or hang.
  rc=0
  out=$(MARKER_SINK=http://127.0.0.1:1/webhook \
        DEPLOYMENT_MARKER_BASE=http://127.0.0.1:1/pixel.gif \
        sh "$0" started --env dev-7 --sha "$real" 2>&1) || rc=$?
  if [ "$rc" = 0 ] && echo "$out" | grep -q "DRY RUN"; then
    printf '  ok   dry run sends nothing -- unreachable sink AND beacon, still exits 0\n'
  else
    printf '  FAIL dry run attempted delivery (rc %s)\n' "$rc"; fails=$((fails+1))
  fi

  [ "$fails" = 0 ] && { echo "  marker.sh: both directions confirmed"; exit 0; }
  echo "  marker.sh: $fails finding(s) -- this script's guards verify nothing"; exit 1
fi

EVENT="$1"; shift
ENV_=''; SHA=''; PR=''; APPS=''; LINK=''; LINK_IS=''; OBS=''; MEASUREMENT=''
BASE=''; COLOUR=''; SEND="${MARKER_SEND:-0}"; VERIFY=1; NOTE=''
while [ $# -gt 0 ]; do
  case "$1" in
    --env)         ENV_="${2:?}";        shift 2 ;;
    --sha)         SHA="${2:?}";         shift 2 ;;
    --pr)          PR="${2:?}";          shift 2 ;;
    --apps)        APPS="${2:?}";        shift 2 ;;
    --link)        LINK="${2:?}";        shift 2 ;;
    --link-is)     LINK_IS="${2:?}";     shift 2 ;;
    --observed-by) OBS="${2:?}";         shift 2 ;;
    --measurement) MEASUREMENT="${2:?}"; shift 2 ;;
    --base)        BASE="${2:?}";        shift 2 ;;
    --colour)      COLOUR="${2:?}";      shift 2 ;;
    --note)        NOTE="${2:?}";        shift 2 ;;
    --send)        SEND=1;               shift ;;
    --no-verify-sha) VERIFY=0;           shift ;;
    *) echo "marker: unknown option $1" >&2; usage ;;
  esac
done

# RULE 1/2. The event name decides the kind. This is a closed set on purpose:
# adding a marker type is a deliberate edit here, not something a caller can do
# by passing a string through. `unconverged` is named explicitly because it USED
# to be here and removing it silently would leave every old call site emitting a
# usage error with no explanation of what it did wrong.
case "$EVENT" in
  started)     KIND=intent;      VERDICT=null ;;
  converged)   KIND=observation; VERDICT='"converged"' ;;
  diverged)    KIND=observation; VERDICT='"diverged"' ;;
  unreachable) KIND=abstention;  VERDICT='"unreachable"' ;;
  unconverged)
    echo "marker: 'unconverged' no longer exists. It collapsed 'I looked and saw a different build' into 'I could not look at all', and a marker is the worst place in this pipeline for that collapse (docs/label-ownership.org rule 2). Say 'diverged' or 'unreachable' -- and you will not choose, the measurement will." >&2
    usage ;;
  *) echo "marker: '$EVENT' is not a marker event (started|converged|diverged|unreachable)" >&2; usage ;;
esac

[ -n "$ENV_" ] || { echo "marker: --env is required; a marker with no environment is not placeable" >&2; usage; }
[ -n "$SHA" ]  || { echo "marker: --sha is required" >&2; usage; }

# An intent marker that carries evidence is an observation wearing the wrong
# name, which is the one confusion that matters here.
if [ "$KIND" = intent ] && { [ -n "$OBS" ] || [ -n "$MEASUREMENT" ]; }; then
  echo "marker: '$EVENT' is INTENT. It may not carry evidence -- 'about to deploy X' and 'X is running' are different facts, and a marker that carries evidence for the first is asserting the second." >&2
  exit 1
fi

MEASURED='null'
CALLER_FIELDS='["environment","service","note","link","apps","colour","base_port"]'

if [ "$KIND" != intent ]; then
  # RULE 4, as far as it goes. --observed-by cannot be verified to have taken
  # the measurement -- nothing here can establish that -- but it CAN be required
  # to name something that exists. `--observed-by my-own-fingers` used to be
  # accepted, rendered, and put on a timeline (docs/interfaces.org, "THE ORACLE
  # IS INDEPENDENT OF THE CALLER"). It is still listed as caller-supplied below,
  # because "that path exists" is not "that program measured this".
  [ -n "$OBS" ] || { echo "marker: '$EVENT' must name the instrument that took the measurement (--observed-by). Nothing else may claim it." >&2; exit 1; }
  [ -f "$root/$OBS" ] || [ -f "$OBS" ] || {
    echo "marker: --observed-by '$OBS' does not exist here. An instrument is a program in this repository, not a name. A marker whose instrument cannot be opened is unauditable the moment anybody tries." >&2; exit 1; }

  # RULE 1. The measurement, and it is a FILE THE INSTRUMENT WROTE WHILE
  # MEASURING -- not a count the caller typed. Everything below is computed
  # here, from it.
  [ -n "$MEASUREMENT" ] || { echo "marker: '$EVENT' must carry the measurement it was derived from (--measurement <ledger>). A verdict with no measurement behind it is the defect this repo exists to refuse, and a verdict with a CALLER-SUPPLIED count behind it is the same defect wearing a number." >&2; exit 1; }
  [ -r "$MEASUREMENT" ] || { echo "marker: could not read the measurement ledger '$MEASUREMENT'. That is 'I could not check' (exit 4, docs/exit-codes.org), not 'the estate is fine' and not 'the estate is broken'." >&2; exit 4; }
fi

# RULE 3. The revision must exist. `deadbee` reached guard 5 and passed.
# Every form the SHA may legitimately appear in is kept, because the ledger
# records whatever the estate's header actually said and the comparison below
# must stay EXACT rather than being loosened into a prefix match.
VERIFIED=true
SHA_FORMS="$SHA"
if [ "$VERIFY" = 1 ]; then
  full=$(git -C "$root" rev-parse --verify "${SHA}^{commit}" 2>/dev/null) || {
    echo "marker: refused -- '$SHA' is not a commit in this repository. A marker naming a build that does not exist is a lie with a long half-life (docs/changing-the-pipeline.org, finding 9). --no-verify-sha if you mean it." >&2
    exit 3; }
  short=$(echo "$full" | cut -c1-7)
  SHA_FORMS="$SHA $short $full"
  SHA="$short"
else
  VERIFIED=false
fi

if [ "$KIND" != intent ]; then
  # THE DERIVATION. awk classifies every row three ways and this script -- not
  # the caller -- decides what the estate did. A row is a build observation only
  # if the request succeeded AND the response named a build; anything else is an
  # absence, and an absence is never evidence that the estate is wrong.
  line=$(awk -F'\t' -v wants="$SHA_FORMS" '
    NF != 4 { bad++; next }
    {
      taken++
      if (!($1 in route)) { route[$1] = 1; nroute++ }
      code = $3; build = $4
      if (code == "200" && build ~ /^[0-9a-fA-F]+$/ && length(build) >= 7) {
        if (!(build in bseen)) { bseen[build] = 1; blist = blist (blist == "" ? "" : " ") build }
        hit = 0
        n = split(wants, w, " ")
        for (i = 1; i <= n; i++) if (build == w[i]) hit = 1
        if (hit) matched++; else diverged++
      } else unobs++
    }
    END {
      if (bad > 0) { printf "MALFORMED %d\n", bad; exit 0 }
      printf "%d %d %d %d %d %s\n", taken+0, matched+0, diverged+0, unobs+0, nroute+0,
             (blist == "" ? "-" : blist)
    }' "$MEASUREMENT")

  case "$line" in
    MALFORMED*)
      echo "marker: the measurement ledger is malformed -- ${line#MALFORMED } row(s) are not <app>TAB<route>TAB<code>TAB<build>. A ledger this script cannot parse is not a measurement it may summarise." >&2
      exit 1 ;;
  esac
  read -r TAKEN MATCHED DIVERGED UNOBS NROUTE BUILDS <<EOF
$line
EOF
  [ "$BUILDS" = '-' ] && BUILDS=''

  [ "$TAKEN" -gt 0 ] || {
    echo "marker: the measurement ledger holds zero samples. '$EVENT' over zero samples is a verdict with nothing behind it -- the exact thing v1 of this script emitted when a caller passed --samples 0." >&2
    exit 1; }

  # Positive evidence outranks absence: one sample that actually saw a different
  # build is a fact about the estate; a sample that saw nothing is not.
  if   [ "$DIVERGED" -gt 0 ]; then DERIVED=diverged
  elif [ "$UNOBS"    -gt 0 ]; then DERIVED=unreachable
  else                             DERIVED=converged
  fi

  # THE CROSS-CHECK. The caller derived a verdict from its own counters; this
  # script derived one from the ledger. Both must agree or nothing is emitted.
  # This is also what stops a PAPERWORK failure from rendering as an estate
  # observation: health.sh setting rc=7 because a gh API call failed does not
  # change one row of the ledger, so the marker still says what was measured.
  if [ "$DERIVED" != "$EVENT" ]; then
    cat >&2 <<MSG
marker: REFUSED -- you asked for '$EVENT' and the measurement says $DERIVED.
  $MEASUREMENT: $TAKEN sample(s) over $NROUTE route(s) --
  $MATCHED served $SHA, $DIVERGED served another build, $UNOBS gave no build at all.
  The event name is a cross-check, not an input. Two derivations have to agree
  before anything reaches a timeline nobody can re-check.
MSG
    exit 1
  fi

  MEASURED=$(jq -nc --argjson taken "$TAKEN" --argjson matched "$MATCHED" \
    --argjson diverged "$DIVERGED" --argjson unobs "$UNOBS" --argjson routes "$NROUTE" \
    --arg builds "$BUILDS" --arg ledger "$(basename "$MEASUREMENT")" '
    { samples_taken: $taken, samples_matched: $matched,
      samples_diverged: $diverged, samples_unobserved: $unobs,
      routes: $routes,
      builds_seen: ($builds | split(" ") | map(select(length > 0))),
      derived_from: $ledger }')
  CALLER_FIELDS='["environment","service","note","link","apps","colour","base_port","observed_by"]'
fi

# The port tier IS the environment class in this repo (spec.org, Port tiers), so
# it is worth sending; the address is not, and is scrubbed.
PORT=$(printf '%s' "$BASE" | sed -n 's/.*:\([0-9][0-9]*\).*/\1/p')
case "$ENV_" in
  dev-*)             TIER=dev ;;
  staging|production*) TIER=protected ;;
  *)                 TIER=team ;;
esac

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# Measured, not asserted. v1 hardcoded "hydra", which is a claim about the world
# that stops being true the first time anyone runs this anywhere else.
HOST=$(uname -n 2>/dev/null || echo unknown); HOST=${HOST%%.*}

payload=$(jq -nc \
  --arg source "$SOURCE" --arg event "deploy.$EVENT" --arg kind "$KIND" \
  --arg service storefront --arg revision "$SHA" --arg environment "$ENV_" \
  --arg tier "$TIER" --arg timestamp "$TS" --arg repo "$REPO" --arg host "$HOST" \
  --arg obs "$OBS" --arg base_port "$PORT" --arg colour "$COLOUR" \
  --arg apps "$APPS" --arg link "$LINK" --arg link_is "$LINK_IS" \
  --arg note "$NOTE" --arg pr "$PR" \
  --argjson verdict "$VERDICT" --argjson verified "$VERIFIED" \
  --argjson measured "$MEASURED" --argjson caller "$CALLER_FIELDS" '
  {
    source: $source,
    event:  $event,
    marker: ({
      schema:  "deployment-marker/2",
      kind:    $kind,
      verdict: $verdict,
      service: $service,
      revision: $revision,
      revision_verified: $verified,
      environment: $environment,
      tier: $tier,
      timestamp: $timestamp,
      repo: $repo,
      host: $host,
      caller_supplied: $caller
    }
    + (if $apps  == "" then {} else {apps: ($apps|split(" ")|map(select(length>0)))} end)
    + (if $pr    == "" then {} else {pr: ($pr|tonumber)} end)
    + (if $colour== "" then {} else {colour: $colour} end)
    + (if $note  == "" then {} else {note: $note} end)
    + (if $link  == "" then {} else {link: $link, link_is: (if $link_is=="" then "unspecified" else $link_is end)} end)
    + (if $measured == null then {} else
         {evidence: ({observed_by: $obs,
                      verdict_derived_from: "the measurement, recomputed here",
                      measured: $measured}
           + (if $base_port == "" then {} else {port: ($base_port|tonumber)} end))} end))
  }')

echo "marker: deploy.$EVENT  $ENV_ <- $SHA  ($KIND)"
echo "  POST $SINK"
printf '%s\n' "$payload" | jq . | sed 's/^/  /'

# ---------------------------------------------------------------------------
# THE BEACON
# ---------------------------------------------------------------------------
# A one-pixel GET that says "a marker was recorded". Three things it is not:
#
#   NOT AN ORACLE. Its response is discarded (-o /dev/null) and never read as
#   evidence about the deployment. A 200 from a pixel does not mean the deploy
#   was healthy; a failure to reach it does not mean the deploy failed. It
#   cannot: the pixel has never heard of this estate.
#   NOT A GUARD. It cannot change this script's exit code, and this script
#   cannot fail a deployment anyway.
#   NOT THE RECORD. It carries four fields -- event, environment, revision,
#   timestamp -- and every one of them is already in the payload above. A reader
#   must be able to re-derive the whole beacon from the marker record; if they
#   ever cannot, the beacon has become load-bearing, and that is a defect.
#
# But "I could not notify" is a fact, and a fact that only ever existed in a
# terminal nobody kept is not recorded. So a beacon that could not be sent
# lands in the same spool as an undelivered marker, tagged what:"beacon".
spool() {  # spool <why> <what>
  mkdir -p "$root/.run"
  printf '%s\n' "$payload" | jq -c --arg why "$1" --arg what "$2" --arg at "$TS" \
    '. + {undelivered:{what:$what, why:$why, at:$at}}' >> "$root/.run/markers-undelivered.jsonl"
}

# Four fields, each of them a field of the record above, percent-encoded by jq
# rather than by hand. @uri escapes everything a query string cares about, which
# matters because --env is caller-supplied text and reaches this line unchanged.
beacon_query=$(jq -rn --arg s "deploy.$EVENT:$ENV_:$SHA:$TS" '$s|@uri')

beacon() {  # beacon <would|now>
  if [ -z "$BEACON_BASE" ]; then
    # THE DEFAULT PATH. Mock, and LOUD about it: a mock that prints nothing is
    # indistinguishable from a beacon nobody ever wired up.
    echo "  beacon: MOCK -- DEPLOYMENT_MARKER_BASE is unset, so no request was made."
    printf '          would GET  ${DEPLOYMENT_MARKER_BASE}?marker=%s\n' "$beacon_query"
    echo "          Set it in .env to notify for real (.env.template has an example)."
    return 0
  fi
  case "$BEACON_BASE" in
    http://*|https://*) : ;;
    *) echo "  BEACON MISCONFIGURED: DEPLOYMENT_MARKER_BASE='$BEACON_BASE' is not an absolute http(s) URL." >&2
       echo "  Nothing was sent and nothing was guessed. The marker above is unaffected." >&2
       spool "DEPLOYMENT_MARKER_BASE is not an absolute http(s) URL" beacon
       return 0 ;;
  esac
  case "$BEACON_BASE" in
    *'?'*|*'#'*)
      echo "  BEACON MISCONFIGURED: DEPLOYMENT_MARKER_BASE='$BEACON_BASE' already carries a query string or fragment." >&2
      echo "  Appending ?marker= would produce a malformed URL, so nothing was sent." >&2
      spool "DEPLOYMENT_MARKER_BASE already carries a query string or fragment" beacon
      return 0 ;;
  esac
  url="$BEACON_BASE?marker=$beacon_query"
  if [ "$1" = would ]; then
    echo "  beacon: would GET $url"
    echo "          (dry run -- nothing was sent.)"
    return 0
  fi
  bcode=$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "$url" 2>/dev/null) || bcode=000
  case "${bcode:-000}" in
    2*) echo "  beacon: notified ($bcode) $url"
        echo "          A NOTIFICATION, not evidence. This response says nothing about the"
        echo "          deployment -- the marker record above is the evidence." ;;
    *)  echo "  BEACON NOT SENT (HTTP ${bcode:-000}) $url" >&2
        echo "  The deployment and the marker are both unaffected; this is a notification." >&2
        echo "  Recorded as a hole rather than dropped: $root/.run/markers-undelivered.jsonl" >&2
        spool "beacon GET returned ${bcode:-000}" beacon ;;
  esac
  return 0
}

if [ "$SEND" != 1 ]; then
  echo "  DRY RUN -- nothing was sent. --send, or MARKER_SEND=1, to deliver."
  beacon would
  exit 0
fi

undelivered() {   # undelivered <why>
  spool "$1" marker
  cat >&2 <<MSG
  MARKER UNDELIVERED: $1
  The deployment is NOT affected -- a telemetry sink is not a guard, and this
  does not get a veto over the estate. But the timeline now has a HOLE at $TS,
  and a hole nobody knows about is worse than no timeline at all.
  Spooled to: $root/.run/markers-undelivered.jsonl
MSG
  exit 75
}

# THE INDEPENDENT WITNESS. Read the counter BEFORE. It lives on /health.json,
# which this script never writes, so it is not the sender's own assertion.
witness() { curl -s --max-time 10 "$HEALTH" 2>/dev/null \
              | jq -r '.stats.webhooks_today // empty' 2>/dev/null || true; }
before=$(witness); before=${before:-?}

# `code=$(curl ...) || code=000` and NOT `$(curl ... || echo 000)`: the second
# form concatenates curl's own "000" with the fallback and yields 000000, which
# then falls through the case below into the wrong diagnosis. Found by running
# the unreachable-sink path rather than by reading this line.
code=$(printf '%s' "$payload" | curl -s -o /dev/null --max-time 15 \
         -w '%{http_code}' -X POST -H 'content-type: application/json' \
         --data-binary @- "$SINK" 2>/dev/null) || code=000
code=${code:-000}

case "$code" in
  202|200) : ;;
  000) undelivered "sink unreachable ($SINK). Could not observe -- NOT observed to have failed (docs/label-ownership.org, rule 2)." ;;
  429) undelivered "rate limited (HTTP 429). The sink refused this marker; it did not lose it silently." ;;
  *)   undelivered "sink rejected the payload (HTTP $code). Reporting the rejection rather than reshaping the payload until something sticks." ;;
esac

after=$(witness); after=${after:-?}
echo "  HTTP $code   webhooks_today $before -> $after"
if [ "$before" = '?' ] || [ "$after" = '?' ]; then
  echo "  DELIVERY ACCEPTED, RECEIPT UNWITNESSED: the sink returned $code but /health.json"
  echo "  could not be read, so nothing independent of this request confirms it landed."
elif [ "$after" -gt "$before" ] 2>/dev/null; then
  echo "  DELIVERY ACCEPTED, AND THE COUNTER MOVED: webhooks_today is a GLOBAL counter on"
  echo "  a shared public sink, so another client's POST moves it too. This is consistent"
  echo "  with our marker landing; it is not proof that it did."
else
  echo "  DELIVERY ACCEPTED, RECEIPT NOT WITNESSED: $code, but webhooks_today did not move."
  echo "  Reported, not rounded up. A 202 is the sink's assertion about our own"
  echo "  request; treating it as proof of storage is the guard-5 shape."
fi

# The marker is recorded. Now, and only now, ping about it.
beacon now
