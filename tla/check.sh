#!/bin/sh
# Model-check the promotion pipeline, BOTH directions.
# A model that can only pass proves nothing, so the negative run is required:
# with Guard4b disabled TLC must reproduce scenario D4 (regressed = TRUE).
set -eu
JAR="${TLA2TOOLS:-$HOME/ghq/github.com/aygp-dr/tla-plus-tutorial/tla2tools.jar}"
[ -f "$JAR" ] || { echo "tla2tools.jar not found; set TLA2TOOLS"; exit 1; }
cd "$(dirname "$0")"
# Bounded heap: the fourteen-rule label model has 25M states, and an unbounded
# JVM under a loaded desktop got the whole gate killed for memory (2026-09-14).
run() { java -Xmx${TLC_HEAP:-3g} -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers auto -cleanup "$1" 2>&1; }

# Guard4b's negative run must ALSO disable ProdFirst. The two guards are not
# independent: MainMoved withdraws inProd when main outruns a change, so with
# ProdFirst on, the D4 regression path is unreachable for a second reason and
# the negative test passes for the wrong one. Found when ProdFirst was added --
# the Guard4b negative silently stopped failing.
sed -e 's/Guard4b = TRUE/Guard4b = FALSE/' -e 's/ProdFirst = TRUE/ProdFirst = FALSE/' \
    StandardChange.cfg > Neg.cfg
sed 's/MODULE StandardChange/MODULE Neg/' StandardChange.tla > Neg.tla

printf '== negative: Guard4b=FALSE must violate NoRegression ... '
if run Neg | grep -q 'Error: Invariant Safety is violated'; then echo 'FAIL as required'
else echo 'BAD: model cannot fail; it verifies nothing'; exit 1; fi

# The PR #12 trace: merge without production. ProdFirst off, everything else on.
sed 's/ProdFirst = TRUE/ProdFirst = FALSE/' StandardChange.cfg > NoProdFirst.cfg
sed 's/MODULE StandardChange/MODULE NoProdFirst/' StandardChange.tla > NoProdFirst.tla

printf '== negative: ProdFirst=FALSE must violate NoMergeBeforeProduction ... '
if run NoProdFirst | grep -q 'Error: Invariant Safety is violated'; then echo 'FAIL as required'
else echo 'BAD: merging without production is not caught; #12 could recur'; exit 1; fi

printf '== positive: Guard4b=TRUE must pass ......................... '
if run StandardChange | grep -q 'Model checking completed. No error has been found'; then echo 'PASS'
else echo 'FAIL'; run StandardChange | grep -E 'Error' | head -5; exit 1; fi

# The concurrent model: berths > 1, deploy and merge as separate steps, and
# divergence classes. StandardChange.tla remains valid for what it models
# (one berth, atomic deploy+merge) -- it is a special case, not a rival.
sed 's/MergeGuard4b = TRUE/MergeGuard4b = FALSE/' Concurrent.cfg > NoMergeGuard.cfg
sed 's/MODULE Concurrent/MODULE NoMergeGuard/' Concurrent.tla > NoMergeGuard.tla
sed 's/Berths = 2/Berths = 1/' Concurrent.cfg > One.cfg
sed 's/MODULE Concurrent/MODULE One/' Concurrent.tla > One.tla

printf '== concurrent negative: no merge guard must regress ....... '
if run NoMergeGuard | grep -q 'Invariant Safety is violated'; then echo 'FAIL as required'
else echo 'BAD: berths>1 cannot reach the defect; the model verifies nothing'; exit 1; fi

printf '== concurrent positive: berths=2, both guards ............... '
if run Concurrent | grep -q 'No error has been found'; then echo 'PASS'
else echo 'FAIL'; exit 1; fi

sed 's/LabellerOwns = TRUE/LabellerOwns = FALSE/' Concurrent.cfg > NoOwn.cfg
sed 's/MODULE Concurrent/MODULE NoOwn/' Concurrent.tla > NoOwn.tla
printf '== bypass negative: undeclared manifest must violate ...... '
if run NoOwn | grep -q 'Invariant Safety is violated'; then echo 'FAIL as required'
else echo 'BAD: a silently asserted manifest is not caught'; exit 1; fi

printf '== concurrent positive: berths=1 (the atomic model case) .... '
if run One | grep -q 'No error has been found'; then echo 'PASS'
else echo 'FAIL'; exit 1; fi

# The LABEL NAMESPACE (Labels.tla): three axes plus the estate, transcribed
# from the scripts. Sixteen constants, one per rule; each negative run flips one
# and TLC must name the invariant that rule protects. sim/cross_check.py runs
# the same questions against sim/label_sim.py and requires agreement.
#
# Three constants name NoUnbookedDeploy on purpose: a claim with no window
# (WindowGuard), a berth left behind by a lapsed window (ReapFreesBerth) and a
# window reaped while its change is deploying (ReapSparesInFlight) all reach
# the same state -- a deployment with no reservation -- by three roads.
labels_negative() {  # labels_negative <Constant> <Invariant>
  sed "s/$1 = TRUE/$1 = FALSE/" Labels.cfg > "No$1.cfg"
  sed "s/MODULE Labels/MODULE No$1/" Labels.tla > "No$1.tla"
  printf '== labels negative: %-18s must violate %-18s ' "$1=FALSE" "$2"
  if run "No$1" | grep -q "Invariant $2 is violated"; then echo 'FAIL as required'
  else echo "BAD: rule $1 protects nothing the model can see"; exit 1; fi
  rm -f "No$1.cfg" "No$1.tla"
}
labels_negative DraftGuard         NoDraftDeployed
labels_negative WindowGuard        NoUnbookedDeploy
labels_negative FreezeGuard        NoRefusedClaim
labels_negative EstateGuard        NoRefusedClaim
labels_negative BerthGuard         AtMostOneHolder
labels_negative ClassGuard         NoDeployWithTwoClasses
labels_negative LifecycleExclusive OneLifecycle
labels_negative ReapFreesBerth     NoUnbookedDeploy
labels_negative SettleClears       CleanIsClean
labels_negative ReapSparesInFlight NoUnbookedDeploy
labels_negative RecordOnMerge      MergedHasRecord
labels_negative EmergencyPreempts  EmergencyNeverWaits
labels_negative HoldGuard          NoPromoteUnderHold
labels_negative HealthyBeforeVerdict VerdictOnHealthy
labels_negative LockResets         LockRefusalResets
labels_negative MergeIsTheTombstone NoTombstoneOnMerged

printf '== labels positive: all sixteen rules on .................... '
if run Labels | grep -q 'No error has been found'; then echo 'PASS'
else echo 'FAIL'; run Labels | grep -E 'Error' | head -5; exit 1; fi

rm -rf Neg.tla Neg.cfg NoProdFirst.tla NoProdFirst.cfg NoMergeGuard.tla NoMergeGuard.cfg One.tla One.cfg \
       NoOwn.tla NoOwn.cfg No*.tla No*.cfg \
       *_TTrace_*.tla *_TTrace_*.bin states
echo "== both directions confirmed"
