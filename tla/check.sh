#!/bin/sh
# Model-check the promotion pipeline, BOTH directions.
# A model that can only pass proves nothing, so the negative run is required:
# with Guard4b disabled TLC must reproduce scenario D4 (regressed = TRUE).
set -eu
JAR="${TLA2TOOLS:-$HOME/ghq/github.com/aygp-dr/tla-plus-tutorial/tla2tools.jar}"
[ -f "$JAR" ] || { echo "tla2tools.jar not found; set TLA2TOOLS"; exit 1; }
cd "$(dirname "$0")"
run() { java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -cleanup "$1" 2>&1; }

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


# ---------------------------------------------------------------------------
# Labels.tla -- THE NAMESPACE. Three independent axes plus the estate, none of
# which StandardChange.tla or Concurrent.tla can express: both carry a single
# boolean called `emergency` used as a break-glass bypass, and neither has any
# variable that is not indexed by a PR, so neither can say the estate is closed.
#
# EVERY constant here is switchable and every one gets a negative run, because
# every one of them is FALSE in the repository today. The positive run is
# therefore not a statement about the repo -- it is the statement that these
# invariants are the ones the repairs have to establish.
#
# sim/label_sim.py checks the same properties against a transition relation
# transcribed from the shell scripts. Where the two disagreed, both were wrong
# about something: see docs/label-state-machine.org.
# ---------------------------------------------------------------------------
neg() {   # neg <name> <sed-expr>... -- last arg is the invariant that must fail
  name=$1; shift
  inv=$1; shift
  cp Labels.cfg "$name.cfg"
  for e in "$@"; do sed -i.bak "$e" "$name.cfg"; done
  rm -f "$name.cfg.bak"
  sed "s/MODULE Labels/MODULE $name/" Labels.tla > "$name.tla"
  printf '== labels negative: %-34s must violate ... ' "$name"
  if run "$name" | grep -q 'Error: Invariant Safety is violated'; then
    echo 'FAIL as required'
  else
    echo "BAD: $inv cannot be violated; it verifies nothing"; exit 1
  fi
  rm -f "$name.tla" "$name.cfg"
}

printf '== labels positive: every repair in force ................... '
if run Labels | grep -q 'Model checking completed. No error has been found'; then
  echo 'PASS'
else echo 'FAIL'; run Labels | grep -E 'Error|violated' | head -5; exit 1; fi

# THE ONE THE OWNER ASKED ABOUT. With one label, the write that closes the
# estate is the write that exempts its own carrier. Violated in ONE step.
neg NoSplitEmergency DeclaringABlockDoesNotExempt \
    's/SeparateEmergency   = TRUE/SeparateEmergency   = FALSE/'

# #2: itil:standard and itil:emergency on one PR. The class group's cardinality
# is declared and not enforced.
neg NoClassExclusive ClassAtMostOne \
    's/ClassExclusive      = TRUE/ClassExclusive      = FALSE/'

# The mitigation, and it needs ClassExclusive off as well -- the same coupling
# as Guard4b and ProdFirst above. With the group enforced, no PR can ever hold
# two classes, so preflight's refusal has nothing to refuse and the negative
# passes for the wrong reason.
neg NoConflictRefusal NoUndefinedClassMoves \
    's/ClassExclusive      = TRUE/ClassExclusive      = FALSE/' \
    's/ClassConflictRefused = TRUE/ClassConflictRefused = FALSE/'

# The group says <=1, which permits ZERO, and every rule in preflight branches
# on the class -- so an unclassified change satisfies all of them by falling
# through. An inert diff gets no class: the labeller's classify step matches
# neither branch and leaves the class alone.
neg NoClassRequired ClassifiedBeforeDeploy \
    's/ClassRequired       = TRUE/ClassRequired       = FALSE/'

# Nothing clears change:requested until settle.sh's final cleanup, so the
# lifecycle states accumulate while the group says at most one may be active.
neg NoLifecycleReplace LifecycleAtMostOneActive \
    's/LifecycleReplaces   = TRUE/LifecycleReplaces   = FALSE/'

# docs/changing-the-pipeline.org: a control-plane change is proven by USE, over
# N subsequent deployments, not by its own merge. Not built.
neg NoSoak ControlPlaneSoaks 's/Soak                = TRUE/Soak                = FALSE/'

# preflight checks the BERTH before the estate and exempts nobody there, so an
# emergency waits on an ordinary change's berth while that change waits on the
# emergency. Found by sim/label_sim.py; reproduced here.
neg NoPreempt EmergencyNeverWaits \
    's/EmergencyPreempts   = TRUE/EmergencyPreempts   = FALSE/'

# Guard 1, and ADR 0001 S8.
neg NoBerthMutex BerthSingleton \
    's/BerthMutex          = TRUE/BerthMutex          = FALSE/'
neg NoEstateBlock OrdinaryChangeWaits \
    's/EstateBlocks        = TRUE/EstateBlocks        = FALSE/'

rm -rf Neg.tla Neg.cfg NoProdFirst.tla NoProdFirst.cfg NoMergeGuard.tla NoMergeGuard.cfg One.tla One.cfg \
       NoOwn.tla NoOwn.cfg *_TTrace_*.json \
       *_TTrace_*.tla *_TTrace_*.bin states
echo "== both directions confirmed"
