#!/bin/sh
# port.sh -- port the change:* labels to the release:* grammar, on the forge and in the tree, with the audits.
#
#   ./experiments/025-label-port/port.sh plan     print the map and what each step would touch; write nothing
#   ./experiments/025-label-port/port.sh forge    rename the labels on the forge (gh label edit keeps every PR's labels)
#   ./experiments/025-label-port/port.sh tree     rewrite the label strings in the tree (current-status files only)
#   ./experiments/025-label-port/port.sh audit    the gates that must hold afterwards, with counts
#   ./experiments/025-label-port/port.sh all      forge, tree, audit
#
# The map is the tense-pair grammar decided 2026-09-15 (research/findings/release-grammar.org):
# the person says the verb, the runner answers the participle, one namespace. Renaming on the
# forge rather than deleting keeps the record on every closed change.
set -eu
cd "$(dirname "$0")/../.."
R="${GH_REPO:-aygp-dr/standard-change}"
MAP='change:scheduled release:scheduled
change:complete release:completed
change:end release:ended
change:failed release:failed
change:backed-out release:backed-out
change:abandoned release:abandoned
change:superseded release:superseded
change:backfill-owed release:backfill-owed
change:requested release:started
release release:start'
# files the port never touches: history, the spec of record, older experiments, the sealed docs
SKIP='^(gates/fixtures/|research/history/|research/substrates/|research/build/|experiments/(0[0-2][0-9]|mermaid)|docs/|scenarios\.org|spec\.org|WALKTHROUGH\.org|adopt/)'
files() { git ls-files | grep -E '\.(org|md|sh|py|yml|yaml|tsv|el|mjs|tla|cfg|json)$|^deploy-run$' | grep -vE "$SKIP"; }
plan() {
  echo "map:"; printf '%s\n' "$MAP" | awk '{printf "  %-22s -> %s\n", $1, $2}'
  echo "forge labels present:"; gh label list --repo "$R" --limit 200 --json name -q '.[].name' | grep -E '^(change:|release$)' | sed 's/^/  /' || true
  echo "tree files with a change:* or bare release string:"; files | xargs grep -lE 'change:(scheduled|complete|end|failed|backed-out|abandoned|superseded|backfill-owed|requested)|[^a-z:-]release[^a-z:-]' 2>/dev/null | sed 's/^/  /'
}
forge() {
  printf '%s\n' "$MAP" | while read -r old new; do
    if gh label list --repo "$R" --limit 200 --json name -q '.[].name' | grep -qx "$old"; then
      if gh label list --repo "$R" --limit 200 --json name -q '.[].name' | grep -qx "$new"; then
        # both exist: move the PRs, then delete the old
        for pr in $(gh pr list --repo "$R" --state all --limit 300 --label "$old" --json number -q '.[].number'); do
          gh pr edit "$pr" --repo "$R" --add-label "$new" --remove-label "$old" >/dev/null && echo "  #$pr: $old -> $new"
        done
        gh label delete "$old" --repo "$R" --yes >/dev/null && echo "  deleted $old (merged into $new)"
      else
        gh label edit "$old" --repo "$R" --name "$new" >/dev/null && echo "  renamed $old -> $new"
      fi
    fi
  done
}
tree() {
  files | while read -r f; do
    before=$(md5 -q "$f" 2>/dev/null || md5sum "$f" | cut -c1-32)
    printf '%s\n' "$MAP" | while read -r old new; do
      case "$old" in
        release) sed -i '' -E "s/([^a-z:-])=release=([^a-z:-])/\1=release:start=\2/g; s/'release'/'release:start'/g; s/\"release\"/\"release:start\"/g; s/--label release([^:a-z-])/--label release:start\1/g" "$f" ;;
        *) sed -i '' "s/$old/$new/g" "$f" ;;
      esac
    done
    after=$(md5 -q "$f" 2>/dev/null || md5sum "$f" | cut -c1-32)
    [ "$before" = "$after" ] || echo "  rewrote $f"
  done
}
audit() {
  echo "docs gate:      $(gmake -s docs 2>&1 | tail -1)"
  echo "label audit:    $(python3 gates/label-audit.py 2>&1 | tail -1)"
  echo "model coverage: $(python3 gates/label-model-coverage.py 2>&1 | tail -1)"
  echo "frames:         $(python3 tla/frames.py --check && echo ok || echo STALE)"
  echo "simulator:      $(python3 sim/label_sim.py --bound 6 --walks 0 --disable Interfere 2>&1 | tail -1)"
  echo "shell syntax:   $(for s in change/*.sh; do sh -n "$s" || echo "$s"; done; echo ok)"
  echo "forge labels still change:* : $(gh label list --repo "$R" --limit 200 --json name -q '.[].name' | grep -c '^change:' || true)"
  echo "tree strings still change:* : $(files | xargs grep -cE 'change:(scheduled|complete|end|failed|backed-out|abandoned|superseded|backfill-owed|requested)' 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')"
}
case "${1:-plan}" in
  plan) plan ;; forge) forge ;; tree) tree ;; audit) audit ;;
  all) forge; tree; audit ;;
  *) echo "usage: port.sh plan|forge|tree|audit|all" >&2; exit 2 ;;
esac
