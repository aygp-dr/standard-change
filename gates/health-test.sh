#!/bin/sh
# health-test.sh -- guard 5's THREE-VALUED classification, offline.
#
# WHAT THIS IS FOR. gates/health.sh used to answer a two-valued question: did
# every sample serve the wanted build, yes or no. Both halves of "no" were one
# counter:
#
#   if [ "$code" != "200" ] || [ "$sha" != "$want" ]; then bad=$((bad+1)); fi
#
# so a curl that could not open a socket (code=000) and a front that answered
# with the PREVIOUS build were the same number, and the same sentence -- "N/N
# samples not serving <sha>", said of a route that had said nothing at all.
# That is docs/label-ownership.org rule 2, and once a deployment marker is
# emitted from here it is that rule broken on a permanent, unre-checkable
# timeline. .github/workflows/deploy-production.yml runs this gate on
# ubuntu-latest, which cannot open a socket to any environment in this
# repository, so it is the first thing that would have written one.
#
# HOW IT RUNS WITHOUT AN ESTATE. There is no nginx on this host and no live
# protected tier, so the estate is replaced rather than the gate: a `curl` on
# PATH that prints a canned `-w` line. The gate is unmodified and does not know.
# That is the only honest way to test the UNREACHABLE branch, because an
# unreachable estate is exactly what a test host has.
#
# It asserts the gate's EXIT CODE as well as its words, because the point of
# the change is that the verdict did NOT move: converged is still 0, everything
# else is still 7. A test that let the exit code drift would be checking prose.
#
# Exit 0 clean, 1 findings. Runs in `gmake gate-selftest`.
set -eu
cd "$(dirname "$0")/.."
root=$(pwd)

[ -f router/routes.json ] || ./router/generate.sh >/dev/null

want=$(git rev-parse --short HEAD)
other=0000000
work=$(mktemp -d "${TMPDIR:-/tmp}/health-test.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM
fails=0

# The estate. $FAKE_RESP is what every probe returns, in curl's own -w format:
# "<http-code> <x-build-sha>". Everything else curl is asked for in this repo
# (the witness read in marker.sh) is never reached, because these runs are all
# dry.
cat > "$work/curl" <<'SHIM'
#!/bin/sh
printf '%s' "${FAKE_RESP:-000 -}"
exit 0
SHIM
# And the forge. Used by ONE case: a gh that fails makes change/evidence.sh
# fail, which makes the gate's rc 7 while the estate was perfectly converged.
cat > "$work/gh" <<'SHIM'
#!/bin/sh
[ "${FAKE_GH_FAILS:-0}" = 1 ] && exit 1
exit 0
SHIM
chmod +x "$work/curl" "$work/gh"

# BASE is a string, never an address: the curl on PATH answers every probe from
# $FAKE_RESP without opening a socket, so no packet reaches any port in any of
# these runs. It is here only because health.sh derives the environment NAME
# from the port tier.
BASE=http://127.0.0.1:9141
run() { # run <fake-resp> [extra args...]  -> writes $out, sets $rc
  resp="$1"; shift
  rc=0
  out=$(PATH="$work:$PATH" FAKE_RESP="$resp" MARKERS=1 HEALTH_SAMPLES=2 \
        DEPLOYMENT_MARKER_BASE='' \
        sh "$root/gates/health.sh" "$@" "$BASE" "$want" 2>&1) || rc=$?
}

check() { # check <description> <expected-rc> <pattern>...
  d="$1"; want_rc="$2"; shift 2
  why=''
  [ "$rc" = "$want_rc" ] || why="gate exit $rc, wanted $want_rc"
  for pat in "$@"; do
    case "$pat" in
      !*) echo "$out" | grep -q -- "${pat#!}" && why="${why:+$why; }matched '${pat#!}' and must not" ;;
      *)  echo "$out" | grep -q -- "$pat" || why="${why:+$why; }did not match '$pat'" ;;
    esac
  done
  if [ -z "$why" ]; then printf '  ok   %s\n' "$d"
  else printf '  FAIL %s (%s)\n' "$d" "$why"; fails=$((fails+1)); fi
}

echo "health-test: the three values, and the verdict that must not move"

run "200 $want"
check "a converged estate is converged, and the gate still exits 0" 0 \
  "ok checkout" '"verdict": "converged"' '"samples_matched": 10' \
  '"samples_unobserved": 0'

run "000 -"
check "an estate that answered nothing is UNREACHABLE, not wrong" 7 \
  "UNREACHABLE checkout" "could NOT observe" \
  '"kind": "abstention"' '"verdict": "unreachable"' \
  '!"verdict": "diverged"' '"samples_unobserved": 10'

run "200 $other"
check "an estate serving another build is DIVERGED, and says which" 7 \
  "DIVERGED checkout" '"verdict": "diverged"' '"samples_diverged": 10' \
  "$other"

# The subtle one. A 200 with no x-build-sha header is a front that answered and
# did not say what it is serving. v1 counted that as "not serving $want", which
# is a claim about the estate from a response that contained no build at all.
run "200 "
check "a 200 that named no build is an ABSENCE, not a divergence" 7 \
  "UNREACHABLE checkout" '"verdict": "unreachable"' \
  '!"verdict": "diverged"' '"samples_diverged": 0'

echo "health-test: and the paperwork, which is not the estate"

rc=0
out=$(PATH="$work:$PATH" FAKE_RESP="200 $want" FAKE_GH_FAILS=1 MARKERS=1 \
      HEALTH_SAMPLES=2 DEPLOYMENT_MARKER_BASE='' \
      sh "$root/gates/health.sh" --pr 27 --env staging \
         "$BASE" "$want" 2>&1) || rc=$?
check "a failed evidence write reddens the gate but CANNOT redden the estate" 7 \
  "could not record" '"verdict": "converged"' '"samples_matched": 10'

echo "health-test: and the labels it must not invent"

# The marker needs a name for a dev block; the LABEL must not have one. An
# earlier draft hoisted one `case` out and shared it, which quietly sent
# `dev-4:healthy` to `gh pr edit --add-label` -- a label name nothing in this
# repository declares. It was invisible because `|| true` swallows the failure,
# which is exactly the shape that makes an undeclared write worth a test.
# --pr is required here or the label path never runs at all: without it this
# case asserted nothing, and the mutation that re-hoists the case SURVIVED.
BASE=http://127.0.0.1:9040
rc=0
out=$(PATH="$work:$PATH" FAKE_RESP="200 $want" MARKERS=1 HEALTH_SAMPLES=2 \
      DEPLOYMENT_MARKER_BASE='' \
      sh "$root/gates/health.sh" --pr 27 "$BASE" "$want" 2>&1) || rc=$?
check "a dev block gets a marker environment and an UNDECLARED label never" 0 \
  '"environment": "dev-4"' 'unknown:healthy' '!dev-4:healthy' '!dev-9:healthy'

[ "$fails" = 0 ] && { echo "  health.sh: three values, both directions confirmed"; exit 0; }
echo "  health.sh: $fails finding(s) -- guard 5's classification verifies nothing"; exit 1
