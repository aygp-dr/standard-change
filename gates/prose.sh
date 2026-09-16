#!/bin/sh
# prose.sh [file...] -- vale over the org files at the ROOT of the repo.
#
# `gmake prose` already covers research/. This covers everything else: the
# documents that govern (spec.org), orient (README.org), plan (scenarios.org)
# and record (docs/*.org, experiments/*/notes.org). The writing is the product
# here, so it is gated like one.
#
# CI RAN THIS ONCE AND IT WAS REVERTED (90b8b87, reverted by e372869). That is
# recorded rather than glossed: the style has 500+ findings at suggestion level
# across the root corpus, and a gate nobody can get green is a gate that gets
# turned off. This runs at ERROR level only -- the level the WalSh rules
# themselves declare for EmDash, LLMSpeak and LoadBearing -- and it is a LOCAL
# gate, owned by whoever is writing, not a required CI check.
#
# THE DENOMINATOR. Every gate in this repo that counts findings without also
# counting SUBJECTS can pass by examining nothing: change/guard4.sh:142 scores
# an empty check-run filter as green. So this refuses when the file list is
# empty, and it prints how many files it read on every path, including the
# clean one. "0 findings" and "0 files" must never print the same way.
#
# Exit: 0 clean, 1 findings, 4 vale is not installed (docs/exit-codes.org --
# 4 is "I could not check", and it is not 0).
set -eu
cd "$(dirname "$0")/.."

if ! command -v vale >/dev/null 2>&1; then
  echo "prose: vale is not installed -- nothing was checked" >&2
  echo "       4 is not 0 (docs/exit-codes.org)" >&2
  exit 4
fi
# `command -v` is not a liveness test. node is installed on this host and exits
# 1 with a missing shared object; a gate that trusts `command -v` reports a
# broken toolchain as a FAILING REPOSITORY. Ask the tool to speak first.
if ! vale --version >/dev/null 2>&1; then
  echo "prose: vale is present but does not run -- nothing was checked" >&2
  exit 4
fi
[ -f .vale.ini ] || { echo "prose: no .vale.ini -- the oracle is missing" >&2; exit 4; }

if [ $# -gt 0 ]; then
  set -- "$@"
else
  # The root corpus. research/ is gmake prose; apps/ and node_modules carry no org.
  set -- $(ls ./*.org 2>/dev/null) \
         $(ls ./docs/*.org 2>/dev/null) \
         $(ls ./docs/adr/*.org 2>/dev/null) \
         $(ls ./experiments/*/notes.org 2>/dev/null)
fi

n=0
for f in "$@"; do [ -f "$f" ] && n=$((n+1)); done
if [ "$n" -eq 0 ]; then
  echo "prose: no org files matched -- refusing to report a clean run" >&2
  echo "       a gate that examined nothing has no verdict" >&2
  exit 4
fi

out=$(vale --no-exit --minAlertLevel=error --output=line "$@" 2>/dev/null || true)
if [ -n "$out" ]; then
  echo "$out"
  c=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  echo "prose: $n files, $c finding(s) at error level"
  exit 1
fi
echo "prose: $n files, 0 findings at error level"
