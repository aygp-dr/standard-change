#!/bin/sh
# mutate.sh -- break each guard the marker suites claim to test, one at a time,
# and count how many CASES notice.
#
# HYPOTHESIS. `./change/marker.sh --selftest` (31 cases) and
# `./gates/health-test.sh` (6 cases) test what they say they test. Falsifiable,
# and the falsification is cheap: any mutation that survives -- zero cases fail
# -- is a guard with no test behind it, and the suite's PASS is void for it.
#
# WHY IT IS NOT ENOUGH TO RUN THE SUITE AND SEE GREEN. Three tests in this
# repository this week passed while asserting nothing. A suite's own green is
# evidence about the code; it is not evidence about the suite. The only thing
# that is, is watching it go red on demand -- the same rule the repo already
# applies to its gates (spec.org, Verification contract) applied to the tests.
#
# The kill COUNT matters, not just the kill. A mutation killed by exactly one
# case is one edit away from being killed by none.
#
# 012-guard-mutation is the same instrument pointed at the control plane, and
# found that every mutation survived. That is the result this exists to avoid
# repeating.
#
#   run:     ./experiments/015-marker-mutation/mutate.sh
#   output:  experiments/015-marker-mutation/results.tsv
set -eu
cd "$(dirname "$0")/../.."
OUT=experiments/015-marker-mutation/results.tsv

# name <TAB> suite <TAB> file <TAB> sed expression that breaks the guard.
# `suite` is marker | health.
mutations() {
cat <<'ROWS'
verdict-not-derived	marker	change/marker.sh	s/^  if \[ "\$DERIVED" != "\$EVENT" \]; then$/  if false; then/
zero-samples-ok	marker	change/marker.sh	s/\[ "\$TAKEN" -gt 0 \]/[ "$TAKEN" -ge 0 ]/
instrument-unchecked	marker	change/marker.sh	s/^  \[ -f "\$root\/\$OBS" \] || \[ -f "\$OBS" \] || {$/  [ -f "$root\/$OBS" ] || [ -f "$OBS" ] || true || {/
unreachable-is-observation	marker	change/marker.sh	s/unreachable) KIND=abstention;  VERDICT=.\"unreachable\".*$/unreachable) KIND=observation; VERDICT='"unreachable"' ;;/
absence-outranks-evidence	marker	change/marker.sh	s/^  if   \[ "\$DIVERGED" -gt 0 \]; then DERIVED=diverged$/  if   [ "$UNOBS" -gt 0 ]; then DERIVED=unreachable/
malformed-ledger-ok	marker	change/marker.sh	s/^    MALFORMED\*)$/    MALFORMED-NEVER*)/
intent-may-carry-evidence	marker	change/marker.sh	s/^if \[ "\$KIND" = intent \] \&\& { \[ -n "\$OBS" \] || \[ -n "\$MEASUREMENT" \]; }; then$/if false; then/
beacon-unencoded	marker	change/marker.sh	s/jq -rn --arg s "deploy.\$EVENT:\$ENV_:\$SHA:\$TS" ..s|@uri./printf '%s' "deploy.$EVENT:$ENV_:$SHA:$TS"/
beacon-base-unvalidated	marker	change/marker.sh	s/^    http:\/\/\*|https:\/\/\*) : ;;$/    *) : ;;/
beacon-fires-on-dry-run	marker	change/marker.sh	s/^  beacon would$/  beacon now/
unreachable-is-falsified	health	gates/health.sh	s/^    if \[ "\$code" != "200" \] || \[ -z "\$sha" \] || \[ "\$sha" = "-" \]; then$/    if false; then/
event-derived-from-rc	health	gates/health.sh	s/^  if   \[ "\$est_diverged" -gt 0 \]; then ev=diverged$/  if   [ "$rc" != 0 ]; then ev=diverged/
dev-label-reaches-the-forge	health	gates/health.sh	s/^      \*)       ENV_=unknown ;;$/      *:90[0-9]0*) ENV_="dev-$(printf '%s' "$base" | sed -n 's@.*:90\\([0-9]\\)0.*@\\1@p')" ;; *) ENV_=unknown ;;/
ROWS
}

suite_fails() {  # suite_fails <suite> -> number of FAIL lines
  case "$1" in
    marker) ./change/marker.sh --selftest 2>&1 || true ;;
    health) ./gates/health-test.sh       2>&1 || true ;;
  esac | grep -c '^  FAIL' || true
}

printf 'mutation\tsuite\tcases_failed\tverdict\n' > "$OUT"
mutations | while IFS="$(printf '\t')" read -r name suite file expr; do
  [ -n "$name" ] || continue
  cp "$file" "$file.orig"
  sed "$expr" "$file.orig" > "$file"
  chmod +x "$file"
  if cmp -s "$file" "$file.orig"; then
    printf '%s\t%s\t-\tNOT-APPLIED (the sed matched nothing -- fix the expression)\n' \
      "$name" "$suite" | tee -a "$OUT"
    mv "$file.orig" "$file"; chmod +x "$file"; continue
  fi
  n=$(suite_fails "$suite")
  mv "$file.orig" "$file"; chmod +x "$file"
  if [ "$n" -gt 0 ]; then verdict=killed; else verdict='SURVIVED -- untested'; fi
  printf '%s\t%s\t%s\t%s\n' "$name" "$suite" "$n" "$verdict" | tee -a "$OUT"
done

echo
echo "results in $OUT"
echo "A row with cases_failed 0 is a guard nothing tests. A row with 1 is one"
echo "edit away from being that."
