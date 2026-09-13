#!/bin/sh
# Model-check the promotion pipeline, BOTH directions.
# A model that can only pass proves nothing, so the negative run is required:
# with Guard4b disabled TLC must reproduce scenario D4 (regressed = TRUE).
set -eu
JAR="${TLA2TOOLS:-$HOME/ghq/github.com/aygp-dr/tla-plus-tutorial/tla2tools.jar}"
[ -f "$JAR" ] || { echo "tla2tools.jar not found; set TLA2TOOLS"; exit 1; }
cd "$(dirname "$0")"
run() { java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -cleanup "$1" 2>&1; }

sed 's/Guard4b = TRUE/Guard4b = FALSE/' StandardChange.cfg > Neg.cfg
sed 's/MODULE StandardChange/MODULE Neg/' StandardChange.tla > Neg.tla

printf '== negative: Guard4b=FALSE must violate NoRegression ... '
if run Neg | grep -q 'Error: Invariant Safety is violated'; then echo 'FAIL as required'
else echo 'BAD: model cannot fail; it verifies nothing'; exit 1; fi

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

printf '== concurrent positive: berths=1 (the atomic model case) .... '
if run One | grep -q 'No error has been found'; then echo 'PASS'
else echo 'FAIL'; exit 1; fi

rm -rf Neg.tla Neg.cfg NoMergeGuard.tla NoMergeGuard.cfg One.tla One.cfg \
       NoOwn.tla NoOwn.cfg \
       *_TTrace_*.tla *_TTrace_*.bin states
echo "== both directions confirmed"
