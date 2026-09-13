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

rm -rf Neg.tla Neg.cfg *_TTrace_*.tla *_TTrace_*.bin states
echo "== both directions confirmed"
