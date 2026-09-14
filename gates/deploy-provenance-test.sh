#!/bin/sh
# deploy-provenance-test.sh -- can a commit that is not a change reach production?
#
# Issue #26 in one sentence: targets/node/deploy.sh refused a FABRICATED sha and
# had no opinion about which REAL one it was handed, so main's HEAD deployed to
# production-blue exactly as readily as a branch head. gates/production-first.sh
# stops main running ahead of production; nothing stopped production running
# behind a merge.
#
# Runs offline. `gh` is answered from gates/fixtures/provenance/<case> by the
# same recorded-JSON stub gates/observation-test.sh uses, so the guard runs
# unmodified.
#
# THE SUITE IS NEGATIVE-TESTED BY MUTATION, not by a frozen copy of the old
# guard: deleting the gh call from gates/deploy-provenance.sh, or turning its
# exit 4 into an exit 0, must make cases here fail. A suite that passes against
# the guard with its refusals removed has established nothing.
set -eu
cd "$(dirname "$0")/.."
FX="$PWD/gates/fixtures/provenance"
STUB="$PWD/gates/fixtures"
G="./gates/deploy-provenance.sh"

OPEN_HEAD=aaaaaaa000000000000000000000000000000001
ORPHAN=dddddddd00000000000000000000000000000004
DEPLOYED=cccccccc00000000000000000000000000000003

run() { # run <fixture> <env> <sha> [extra...]
  _f="$1"; shift
  FIXTURE="$FX/$_f" PATH="$STUB:$PATH" GH_REPO=o/r MAIN_REF="$MAIN_REF" \
    "$G" "$@" >/dev/null 2>&1 && echo 0 || echo $?
}

# CASES: name : fixture : env : sha : extra : expected exit
#   0 proceed   1 refused   4 could not determine
MAIN_REF=refs/heads/no-such-ref-for-tests
fails=0; n=0
check() { # check <name> <want> <got>
  n=$((n + 1))
  if [ "$2" = "$3" ]; then printf '  ok    %-22s exit %s\n' "$1" "$3"
  else printf '  FAIL  %-22s want exit %s, got %s\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
}

# 1. The legitimate deploy: the head of an open pull request.
check open-pr-head 0 "$(run open-pr-head production-blue "$OPEN_HEAD")"

# 2. A real, resolvable commit that is not any open PR's head. This is the
#    defect: deploy.sh's existing check passes it, because it only asks whether
#    the commit EXISTS.
check merged 1 "$(run merged production-green "$ORPHAN")"

# 3. Same, and the message must say WHICH commit it is. "Not an open PR head"
#    sends somebody looking for a typo when the answer is "you typed main".
MAIN_REF=HEAD
mainsha=$(git rev-parse HEAD)
check main-head 1 "$(run main-head production-blue "$mainsha")"
msg=$(FIXTURE="$FX/main-head" PATH="$STUB:$PATH" GH_REPO=o/r MAIN_REF=HEAD \
        "$G" production-blue "$mainsha" 2>&1 || true)
n=$((n + 1))
case "$msg" in
  *"HEAD, not an open PR"*) printf '  ok    %-22s names main in the refusal\n' main-head-msg ;;
  *) printf '  FAIL  %-22s refusal does not identify the commit as main\n' main-head-msg
     fails=$((fails + 1)) ;;
esac
MAIN_REF=refs/heads/no-such-ref-for-tests

# 4. UNREACHABLE IS NOT AUTHORIZED. The fixture has no open-prs.json, so the
#    stub exits 1 -- "I could not answer", not "there are no open PRs". 4 blocks.
check prs-unreachable 4 "$(run prs-unreachable production-blue "$OPEN_HEAD")"

# 5. Rollback is a MODE, not an exception, and not a free pass: the target must
#    be a build this estate served before.
check rollback-known     0 "$(run rollback-known production-blue "$DEPLOYED" --rollback)"
check rollback-unknown   1 "$(run rollback-unknown production-blue "$ORPHAN" --rollback)"
check rollback-unreach   4 "$(run rollback-unreachable production-blue "$DEPLOYED" --rollback)"

# 6. NOT STAGING, NOT DEV. Both are deployed from whatever somebody wants to
#    look at -- that is what they are for -- and neither fixture can answer a
#    gh call, so a guard that ran here at all would exit 4 and block them.
check staging-waved-through 0 "$(run prs-unreachable staging "$ORPHAN")"
check dev-waved-through     0 "$(run prs-unreachable dev-3 "$ORPHAN")"

# ---- the WIRING, which no fixture can observe --------------------------------
#
# Everything above tests the guard. None of it notices if targets/node/deploy.sh
# stops calling it, which is the shape the guard would actually die in -- the
# same class as the labeller's withdrawal step, present and green while the
# behaviour it asserted had gone (issue #16). So assert the call site, and
# assert its POSITION: the next thing deploy.sh does after resolving the SHA is
# kill every process on the block, and a refusal that arrives after that has
# already taken the environment down to say no.
D=targets/node/deploy.sh
n=$((n + 1))
if grep -q 'deploy-provenance\.sh" "\$env" "\$full"' "$D"; then
  printf '  ok    %-22s deploy.sh calls the guard with the resolved sha
' wiring-call
else
  printf '  FAIL  %-22s deploy.sh does not call gates/deploy-provenance.sh
' wiring-call
  fails=$((fails + 1))
fi

n=$((n + 1))
guard_line=$(grep -n 'deploy-provenance\.sh' "$D" | head -1 | cut -d: -f1)
kill_line=$(grep -n 'kill "\$pid"' "$D" | head -1 | cut -d: -f1)
if [ -n "$guard_line" ] && [ -n "$kill_line" ] && [ "$guard_line" -lt "$kill_line" ]; then
  printf '  ok    %-22s guard at line %s, first estate action at line %s
' \
         wiring-order "$guard_line" "$kill_line"
else
  printf '  FAIL  %-22s the guard does not run before the block is torn down
' wiring-order
  fails=$((fails + 1))
fi

echo "  deploy-provenance-test: $((n - fails))/$n cases, $fails failure(s)"
[ "$fails" = 0 ] || exit 1
