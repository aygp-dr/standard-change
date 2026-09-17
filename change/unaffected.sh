#!/bin/sh
# unaffected.sh <pr> -- release:skip: nothing to release, so merge.
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
j=$(gh pr view "$PR" --repo "$R" --json state,isDraft,headRefOid,headRefName,labels)
[ "$(printf '%s' "$j" | jq -r .state)" = OPEN ] || { echo "#$PR is not open"; exit 2; }
labels=$(printf '%s' "$j" | jq -r '[.labels[].name]|join(" ")')
full_sha=$(printf '%s' "$j" | jq -r '.headRefOid')
sha=$(printf '%s' "$full_sha" | cut -c1-7)
case " $labels " in *" release:skip "*) ;; *) echo "no release:skip on #$PR"; exit 2 ;; esac
if [ "$(printf '%s' "$j" | jq -r .isDraft)" = true ]; then echo "#$PR is a draft"; exit 3; fi
units=$(printf '%s\n' $labels | grep '^app:' | tr '\n' ' ' || true)
if [ -n "$units" ]; then
  say "Refused: \`release:skip\` says the estate is untouched, and the labeller attached \`${units% }\` from the diff. Both cannot be true. A person removes the label that is wrong: withdraw \`release:skip\` and say \`release:start\`, or explain in the PR why the labeller is wrong and fix the labeller."
  echo "refused: unaffected with $units"; exit 3
fi
# gates/report.sh refuses unless the working tree it runs in is ALREADY at the
# PR's head -- deliberately: "this script does not check anything out --
# moving the caller's tree under them is worse." The caller here is the
# scheduler's own long-running checkout, mid-edit more often than not, so
# unaffected.sh keeps ITS OWN worktree, one per PR, and checks THAT out,
# never the scheduler's. One shared worktree raced two PRs against each
# other the first time this ran (2026-09-16); per-PR is the fix.
WT="${SKIP_CHECK_WT:-worktrees/skip-check-$PR}"
if [ ! -d "$WT" ]; then git worktree add -q "$WT" --detach >/dev/null 2>&1 || true; fi
git fetch -q origin "$full_sha" 2>/dev/null || git fetch -q origin >/dev/null 2>&1
if ! git -C "$WT" checkout -q --detach "$full_sha" 2>/dev/null; then
  say "Not merged yet: could not check out \`$sha\` to run the gates on it."
  echo "checkout of $full_sha failed"; exit 4
fi
# the non-deployment gates, on that head, in that worktree
if ! ( cd "$WT" && GH_REPO="$R" ./gates/report.sh "$PR" ) >/dev/null 2>&1; then
  say "Not merged yet: the gates are not green on \`$sha\`. \`release:skip\` waives the estate, never the gates."
  echo "gates not green on $sha"; exit 4
fi
GH_TOKEN="$(gh auth token --user aygp-dr)" gh pr review "$PR" --repo "$R" --approve \
  --body "Approved by the second identity under its standing delegation: \`release:skip\`, no \`app:*\` from the labeller, gates green on \`$sha\`. No deployment is owed." >/dev/null 2>&1 || true
gh pr merge "$PR" --repo "$R" --squash --delete-branch >/dev/null
say "## Post-implementation review -- unaffected

| | |
|---|---|
| build | \`$sha\` |
| deployment | none, by declaration (\`release:skip\`) |
| the labeller agreed | no \`app:*\` on the head |
| gates | green on \`$sha\` |
| window, berth, observations | none: nothing to observe |

The merge is the record. \`release:skip\` stays: it is the reason no deployment exists for this change."
echo "merged #$PR ($sha) as unaffected"
