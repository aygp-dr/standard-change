#!/bin/sh
# abort-test.sh -- does the failure path say what it observed, or what it assumed?
#
# Issue #37 asked for an abort verb that would, among other things, "state what
# the estate is now serving". change/abort.sh was written and it ended with
#
#   the change is CLOSED failed. It is not merged and not deployed.
#
# printed on every path, having measured neither. That is defect class 3 --
# observation is not intent -- in the script added to close the issue about the
# failure path never having been walked.
#
# It is the D13 sentence from the other side. There, settle.sh reported a merge
# that had not happened while production served the build; here, abort reports
# "not deployed" over a replica currently serving it, and then clears the labels
# that were the only remaining evidence.
#
# Runs offline. `gh` answers from pr.json and `curl` from headers.txt, both put
# first on PATH, so abort.sh runs unmodified. Every case that would WRITE runs
# under --dry-run: the point of a failure-path test is not to have to cause a
# failure, and change/schedule.sh close is a real mutation of a real calendar.
set -eu
cd "$(dirname "$0")/.."
FX="$PWD/gates/fixtures/abort"
STUB="$PWD/gates/fixtures"
HEAD_SHORT=43646f9

fails=0; n=0
ok()   { n=$((n + 1)); printf '  ok    %-20s %s\n' "$1" "$2"; }
bad()  { n=$((n + 1)); printf '  FAIL  %-20s %s\n' "$1" "$2"; fails=$((fails + 1)); }

abort() { # abort <fixture> <args...>
  _f="$1"; shift
  FIXTURE="$FX/$_f" PATH="$STUB:$PATH" GH_REPO=o/r \
    PRODUCTION_FRONT_URL=http://front.invalid \
    GUARD4_WRITES="$WRITES" \
    ./change/abort.sh "$@" 2>&1 || true
}
status() { # status <fixture> <args...>
  _f="$1"; shift
  FIXTURE="$FX/$_f" PATH="$STUB:$PATH" GH_REPO=o/r \
    PRODUCTION_FRONT_URL=http://front.invalid \
    GUARD4_WRITES="$WRITES" \
    ./change/abort.sh "$@" >/dev/null 2>&1 && echo 0 || echo $?
}

WRITES=$(mktemp)
trap 'rm -f "$WRITES"' EXIT

# -- 1. THE REFUSAL ----------------------------------------------------------
# Production is serving this change's own build. `failed` says production never
# took it; `backed-out` says it was returned. Both are false right now, so
# there is no closure code that fits and the estate has to move first.
: > "$WRITES"
rc=$(status serving-this 42 "deploy fell over")
[ "$rc" = 1 ] && ok refuse-serving-this "exit 1" \
               || bad refuse-serving-this "want exit 1, got $rc"

# AND IT MUST HAVE WRITTEN NOTHING. A refusal that has already posted the
# closure record and cleared the labels is not a refusal; it is the D13 shape
# again, where every downstream step destroyed the evidence of the defect.
if [ -s "$WRITES" ]; then
  bad refuse-writes-nothing "abort wrote: $(tr '\n' ';' < "$WRITES")"
else
  ok refuse-writes-nothing "no gh writes"
fi

# The refusal has to be actionable: it must name the build out there and the
# way out, or it is a wall rather than a guard.
msg=$(abort serving-this 42 "deploy fell over")
case "$msg" in
  *"$HEAD_SHORT"*"switch.sh"*) ok refuse-message "names the build and the way out" ;;
  *) bad refuse-message "refusal does not name the served build and switch.sh" ;;
esac

# --backed-out is not a way past it either: production has not been returned
# anywhere while it is still serving this build.
rc=$(status serving-this 42 "rolled back" --backed-out --to 9583730)
[ "$rc" = 1 ] && ok refuse-backed-out "exit 1" \
               || bad refuse-backed-out "want exit 1, got $rc"

# -- 2. THE ORDINARY CLOSURE -------------------------------------------------
# Production is serving something else. The closure is correct, and the record
# has to SAY what was seen rather than assert the estate is empty.
: > "$WRITES"
msg=$(abort serving-other 42 "e2e failed against the slot" --dry-run)
case "$msg" in
  *"serving 9583730, which is not this change"*)
      ok observes-other "names the build production is serving" ;;
  *)  bad observes-other "did not report what production is serving" ;;
esac
case "$msg" in
  *"not merged and not deployed"*)
      bad no-blind-assertion "still asserts 'not merged and not deployed'" ;;
  *)  ok no-blind-assertion "the unmeasured sentence is gone" ;;
esac

# -- 3. UNREACHABLE IS NOT EMPTY ---------------------------------------------
# The front does not answer. That must not become "nothing is deployed", and it
# must not block the closure either -- no runner can reach this estate, and a
# change that cannot be closed because the front is down holds the berth for
# nothing.
for f in front-down front-no-sha; do
  rc=$(status "$f" 42 "abandoned" --dry-run)
  [ "$rc" = 0 ] && ok "$f-proceeds" "exit 0" || bad "$f-proceeds" "want exit 0, got $rc"
  msg=$(abort "$f" 42 "abandoned" --dry-run)
  case "$msg" in
    *"NOT OBSERVED"*) ok "$f-says-unknown" "records the estate as not observed" ;;
    *) bad "$f-says-unknown" "does not distinguish unreachable from empty" ;;
  esac
done

# -- 4. MERGED IS NOT FAILED EITHER ------------------------------------------
# Trunk contains this change, so "the change did not complete" is false about
# the half that did. A warning rather than a refusal: a merged change whose
# DEPLOYMENT failed is ordinary, and the reason should say which.
msg=$(abort merged 42 "cutover failed after merge" --dry-run)
case "$msg" in
  *"is MERGED"*) ok merged-noted "says the PR is merged" ;;
  *) bad merged-noted "closes a merged PR 'failed' with no note" ;;
esac

# -- 5. --dry-run WRITES NOTHING ---------------------------------------------
: > "$WRITES"
status serving-other 42 "preview" --dry-run >/dev/null
if [ -s "$WRITES" ]; then
  bad dry-run-writes-nothing "abort wrote: $(tr '\n' ';' < "$WRITES")"
else
  ok dry-run-writes-nothing "no gh writes"
fi

# -- 6. THE INSTRUMENT, BOTH UNKNOWNS ----------------------------------------
# change/serving.sh must exit 4 for both, and must SAY WHICH. abort.sh treats
# them the same -- it only needs to know it does not know -- but the eight
# copies of the `curl -sI | tr | awk` idiom this replaces could not tell them
# apart at all: curl failing produced an empty string and a zero status, so
# "not answering" and "answered, named no build" were one value. An operator
# chasing a failed abort needs to know whether to restart the front or fix the
# server's headers.
for f in front-down front-no-sha; do
  rc=$(FIXTURE="$FX/$f" PATH="$STUB:$PATH" ./change/serving.sh http://front.invalid \
         >/dev/null 2>&1 && echo 0 || echo $?)
  [ "$rc" = 4 ] && ok "serving-$f" "exit 4" || bad "serving-$f" "want exit 4, got $rc"
done
down=$(FIXTURE="$FX/front-down"   PATH="$STUB:$PATH" ./change/serving.sh http://front.invalid 2>&1 || true)
nosha=$(FIXTURE="$FX/front-no-sha" PATH="$STUB:$PATH" ./change/serving.sh http://front.invalid 2>&1 || true)
case "$down$nosha" in
  *"is not answering"*) inner=1 ;;
  *) inner='' ;;
esac
if [ -n "$inner" ] && [ "$down" != "$nosha" ] \
   && { case "$nosha" in *"no x-build-sha"*) true ;; *) false ;; esac; }; then
  ok serving-distinguishes "unreachable and no-header report differently"
else
  bad serving-distinguishes "the two unknowns are indistinguishable"
fi

# -- 7. THE CLOSING SUMMARY, ASSERTED STATICALLY -----------------------------
# The last three lines of abort.sh are past the --dry-run exit, and every case
# above that runs to completion would post a change record and clear a real
# PR's labels. So this one is a read of the SOURCE, like the W-checks in
# gates/labeller-test.py, and for the same reason: the property is about what
# the script says, and no offline run can reach the line that says it.
#
# COMMENTS STRIPPED FIRST. The first version of this check grepped the whole
# file and flagged the COMMENT in abort.sh that quotes the sentence while
# explaining why it is gone -- the same shape as gates/label-audit.py flagging
# the prose that described the label it was about. A static auditor cannot tell
# prose from code, so do not hand it prose.
n=$((n + 1))
code=$(grep -v '^[[:space:]]*#' change/abort.sh)
if printf '%s\n' "$code" | grep -q 'not merged and not deployed'; then
  printf '  FAIL  %-20s %s\n' summary-observes \
    "abort.sh still asserts 'not merged and not deployed' unmeasured"
  fails=$((fails + 1))
elif printf '%s\n' "$code" | grep -q 'production    \$ESTATE'; then
  printf '  ok    %-20s %s\n' summary-observes "the summary prints what was observed"
else
  printf '  FAIL  %-20s %s\n' summary-observes \
    "the closing summary does not report the observed estate"
  fails=$((fails + 1))
fi

echo "  abort-test: $((n - fails))/$n cases, $fails failure(s)"
[ "$fails" = 0 ] || exit 1
