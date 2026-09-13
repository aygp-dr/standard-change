#!/bin/sh
# mutate.sh -- neuter one guard, run the whole suite, see if anything notices.
#
# Hypothesis: the suite does not test the control plane at all, so every
# mutation survives. Falsifiable: any mutant that turns something red refutes it.
set -eu
cd "$(dirname "$0")/../.."
WORK=experiments/012-guard-mutation/work
RESULTS=experiments/012-guard-mutation/results.tsv

# Each row: name <TAB> file <TAB> sed expression that removes the guard.
mutations() {
cat <<'ROWS'
guard0-behind	change/queue.sh	s/if \[ "\$state" = "BEHIND" \]/if false/
guard1-berth	change/queue.sh	s/if \[ -n "\$holder" \]/if false/
guard2-gates	change/activate.sh	s/\[ "\$BAD" -eq 0 \]/true/
guard2-selftest	change/activate.sh	s/\[ "\$SELF" -ge 1 \]/true/
guard3-window	change/activate.sh	s/if ! EVENT=\$(.\/change\/schedule.sh current "\$PR" staging); then/if false; then/
guard4b-merge	change/release.sh	s/if \[ "\$state" = "BEHIND" \] || \[ "\$state" = "DIRTY" \]/if false/
guard4c-hold	change/activate.sh	s/if \[ -n "\$HELD" \]; then/if false; then/
guard5-converge	change/activate.sh	s/|| die "production did not converge on \$SHA"//
sched-clash	change/schedule.sh	s/\[ -z "\$clash" \] ||/[ -z "$clash" ] ||  true \&\& false \&\&/
sched-slot	change/schedule.sh	s/slots = math.ceil((elapsed + mins) \/ q)/slots = 1/
ROWS
}

run_suite() {  # 0 = everything green (mutant SURVIVED), 1 = something went red
  ( gmake -s test >/dev/null 2>&1 \
    && ./gates/labeller-test.py >/dev/null 2>&1 \
    && ./gates/docs-lint.py >/dev/null 2>&1 \
    && python3 gates/pbt-pipeline.py >/dev/null 2>&1 \
    && python3 sim/test_scenarios.py >/dev/null 2>&1 \
    && ./tla/check.sh >/dev/null 2>&1 \
    && ROUTER_URL=http://127.0.0.1:9000 ./gates/e2e.sh >/dev/null 2>&1 ) \
  && echo survived || echo killed
}

rm -rf "$WORK"; mkdir -p "$WORK"
printf 'mutation\tfile\tverdict\n' > "$RESULTS"

echo "baseline (no mutation):"
base=$(run_suite)
echo "  suite is $([ "$base" = survived ] && echo GREEN || echo "RED — fix before trusting any result below")"
[ "$base" = survived ] || exit 1

mutations | while IFS="$(printf '\t')" read -r name file expr; do
  cp "$file" "$WORK/$(basename "$file").orig"
  sed -i.bak "$expr" "$file" && rm -f "$file.bak"
  if cmp -s "$file" "$WORK/$(basename "$file").orig"; then
    verdict="NOT-APPLIED"
  else
    verdict=$(run_suite)
  fi
  cp "$WORK/$(basename "$file").orig" "$file"
  printf '%s\t%s\t%s\n' "$name" "$file" "$verdict" >> "$RESULTS"
  printf '  %-18s %-20s %s\n' "$name" "$file" "$verdict"
done

echo
awk -F'\t' 'NR>1{c[$3]++} END{for(k in c) printf "  %-12s %d\n", k, c[k]}' "$RESULTS"
