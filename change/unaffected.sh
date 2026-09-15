#!/bin/sh
# unaffected.sh <pr> -- release:unaffected: nothing to release, so merge.
#
# A person's claim that the deployable estate is not touched by this change.
# The claim is checked against the labeller's finding: a change carrying any
# app:* while claiming unaffected is the two-classes defect in another
# namespace and is refused until a person removes the label that is wrong.
# No berth, no window, no observation. The non-deployment gates must be green
# on the head and the second identity approves under its standing delegation;
# the merge is then the forge's act and the PIR says: no deployment, by
# declaration, and the labeller agreed. Rule UnaffectedMerges (2026-09-15).
#
# Exit: 0 merged; 3 refused (app:* present, or draft); 4 gates not green; 2 usage.
set -eu
PR="${1:?usage: unaffected.sh <pr>}"
R="${GH_REPO:-${GITHUB_REPOSITORY:-aygp-dr/standard-change}}"; export GH_REPO="$R"
cd "$(dirname "$0")/.."
say() { gh pr comment "$PR" --repo "$R" --body "$1" >/dev/null 2>&1 || true; }
j=$(gh pr view "$PR" --repo "$R" --json state,isDraft,headRefOid,labels)
[ "$(printf '%s' "$j" | jq -r .state)" = OPEN ] || { echo "#$PR is not open"; exit 2; }
labels=$(printf '%s' "$j" | jq -r '[.labels[].name]|join(" ")')
sha=$(printf '%s' "$j" | jq -r '.headRefOid[0:7]')
case " $labels " in *" release:unaffected "*) ;; *) echo "no release:unaffected on #$PR"; exit 2 ;; esac
if [ "$(printf '%s' "$j" | jq -r .isDraft)" = true ]; then echo "#$PR is a draft"; exit 3; fi
units=$(printf '%s\n' $labels | grep '^app:' | tr '\n' ' ' || true)
if [ -n "$units" ]; then
  say "Refused: \`release:unaffected\` says the estate is untouched, and the labeller attached \`${units% }\` from the diff. Both cannot be true. A person removes the label that is wrong: withdraw \`release:unaffected\` and say \`change:start\`, or explain in the PR why the labeller is wrong and fix the labeller."
  echo "refused: unaffected with $units"; exit 3
fi
# the non-deployment gates, on the head
if ! ./gates/report.sh "$PR" >/dev/null 2>&1; then
  say "Not merged yet: the gates are not green on \`$sha\`. \`release:unaffected\` waives the estate, never the gates."
  echo "gates not green on $sha"; exit 4
fi
GH_TOKEN="$(gh auth token --user aygp-dr)" gh pr review "$PR" --repo "$R" --approve \
  --body "Approved by the second identity under its standing delegation: \`release:unaffected\`, no \`app:*\` from the labeller, gates green on \`$sha\`. No deployment is owed." >/dev/null 2>&1 || true
gh pr merge "$PR" --repo "$R" --squash --delete-branch >/dev/null
say "## Post-implementation review -- unaffected

| | |
|---|---|
| build | \`$sha\` |
| deployment | none, by declaration (\`release:unaffected\`) |
| the labeller agreed | no \`app:*\` on the head |
| gates | green on \`$sha\` |
| window, berth, observations | none: nothing to observe |

The merge is the record. \`release:unaffected\` stays: it is the reason no deployment exists for this change."
echo "merged #$PR ($sha) as unaffected"
