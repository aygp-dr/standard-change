#!/bin/sh
# preflight.sh <pr> [env] -- say out loud what a person would check before deploying.
#
# Referenced by .github/workflows/deploy-staging.yml since the spec was written
# and never existed until now. Exit codes are the ones the spec assigned:
#   0 proceed   2 lock held   3 freeze   4 calendar unreachable   5 queue busy
# 4 BLOCKS. "I could not read the calendar" is not "the calendar is clear" --
# the same rule as docs/label-ownership.org: unreachable is not falsified.
#
# It is deliberately VERBOSE. ADR 0001 Option 0 says a person still confirms the
# things a machine cannot judge, and a person cannot confirm a list they have
# not been shown. Each line is phrased as the thing you would actually say to
# yourself, so that reading it is the check rather than a receipt for one.
set -eu
cd "$(dirname "$0")/.."
pr="${1:?usage: preflight.sh <pr> [env]}"
env="${2:-staging}"
R="${GH_REPO:-${GITHUB_REPOSITORY:-aygp-dr/standard-change}}"
rc=0
yes()  { printf '  \033[32m yes \033[0m %s\n' "$1"; }
no()   { printf '  \033[31m NO  \033[0m %s\n' "$1"; rc=${2:-1}; }
note() { printf '        %s\n' "$1"; }

head=$(gh pr view "$pr" --repo "$R" --json headRefOid -q .headRefOid)
short=$(echo "$head" | cut -c1-7)
labels=$(gh pr view "$pr" --repo "$R" --json labels -q '[.labels[].name]|join(" ")')
groups=$(./change/groups.sh "$pr" 2>/dev/null || true)

printf '\npreflight for #%s -> %s, at build %s\n\n' "$pr" "$env" "$short"

# --- am I on the calendar? -----------------------------------------------
if win=$(./change/schedule.sh current "$pr" "$env" 2>/dev/null); then
  yes "I'm on the calendar — window $win is open and covers right now"
else
  if ./change/schedule.sh list >/dev/null 2>&1; then
    no "I am NOT on the calendar. No open window for #$pr on $env covers now." 4
    note "book one:  ./change/schedule.sh block $pr \"$groups\" 30"
  else
    no "I could not READ the calendar, which is not the same as it being clear." 4
    note "exit 4 blocks. An unreadable schedule is an unknown, not a yes."
  fi
fi

# --- do the gates pass for this exact build? -----------------------------
# LOCAL GATE REPORTS. gates/report.sh runs the suite on a host that can reach
# the estate and posts the result as commit statuses under `local/`. Guard 2
# counts them, because they are a real measurement of this SHA -- the gates
# actually ran and every status was gated on an exit code.
#
# They are prefixed `local/` so a reader can always tell a host run from a CI
# run, and when CI returns its contexts sit beside these rather than replacing
# them. This is the same reachability answer as the observation labels: the
# measurement happens where it can, and is carried to the forge in the forge's
# own vocabulary.
locals=$(gh api "repos/$R/commits/$head/status" \
  --jq '[.statuses[]|select(.context|startswith("local/"))]' 2>/dev/null || echo '[]')
lok=$(printf '%s' "$locals" | jq '[.[]|select(.state=="success")]|length' 2>/dev/null || echo 0)
lbad=$(printf '%s' "$locals" | jq '[.[]|select(.state!="success")]|length' 2>/dev/null || echo 0)
lself=$(printf '%s' "$locals" | jq '[.[]|select(.context=="local/gate-selftest" and .state=="success")]|length' 2>/dev/null || echo 0)

bad=$(gh api "repos/$R/commits/$head/check-runs" \
       --jq '[.check_runs[]|select(.name|test("^(gate-selftest|lint|test|e2e)$"))|select(.conclusion!="success")]|length' 2>/dev/null || echo 99)
self=$(gh api "repos/$R/commits/$head/check-runs" \
       --jq '[.check_runs[]|select(.name=="gate-selftest")|select(.conclusion=="success")]|length' 2>/dev/null || echo 0)

# DID NOT RUN IS NOT RED. A check run reports conclusion=failure both when a
# gate genuinely failed and when the job was never started -- and on
# 2026-09-13 every workflow on this repo reported failure for over an hour
# because GitHub stopped scheduling jobs (billing, issue #34). That looked
# exactly like a real gate-selftest failure, and cost half an hour of chasing a
# CI/local divergence that did not exist.
#
# The distinction is the same rule as docs/label-ownership.org rule 2 --
# UNREACHABLE IS NOT FALSIFIED -- applied to the forge rather than the estate.
# merge-on-healthy.yml was fixed so "I could not reach production" stops being
# recorded as "production is unhealthy"; this is that collapse one level up.
#
# The only place the real cause appears is the check run's ANNOTATIONS. Nothing
# in `gh run view` says it: the log is BlobNotFound and the job has zero steps.
# A check run that never ran reports `skipped` or a null conclusion, and a
# gate that genuinely failed reports `failure`. Counting both as "not green"
# is what made an hour of dead CI look like a real gate-selftest failure on
# 2026-09-13 (issue #34) -- the annotations say "the job was not started", but
# nothing in `gh run view` does and the log is BlobNotFound.
notrun=$(gh api "repos/$R/commits/$head/check-runs" \
  --jq '[.check_runs[]|select(.name|test("^(gate-selftest|lint|test|e2e)$"))
        |select(.conclusion=="skipped" or .conclusion==null)]|length' 2>/dev/null || echo 0)
failed=$(gh api "repos/$R/commits/$head/check-runs" \
  --jq '[.check_runs[]|select(.name|test("^(gate-selftest|lint|test|e2e)$"))
        |select(.conclusion=="failure")]|length' 2>/dev/null || echo 0)

if [ "$bad" = 99 ]; then
  no "I could not reach the forge to read the check runs." 4
elif [ "$lbad" -eq 0 ] && [ "$lok" -ge 3 ] && [ "$lself" -ge 1 ]; then
  yes "gates green on THIS head, $short — reported by gates/report.sh"
  note "$lok local/ contexts, gate-selftest among them, none failing."
  note "measured on a host, not by CI, and the contexts say so. The gates ran;"
  note "each status was gated on the exit code of the command that produced it."
elif [ "$bad" -gt 0 ] && [ "$failed" -eq 0 ] && [ "$notrun" -gt 0 ]; then
  no "the gates DID NOT RUN ($notrun skipped, 0 failed). Not red -- absent." 4
  note "a check run reports conclusion=failure both for a real failure and for"
  note "a job that was never started. The annotation says the job was not"
  note "started; nothing in \`gh run view\` does -- the log is BlobNotFound."
  note "exit 4 blocks, because 'I could not check' is not 'it passed' and is"
  note "not 'it failed' either. Verifying on this host instead and calling it"
  note "guard 2 would be substituting a measurement nobody asked for."
elif [ "$bad" -eq 0 ] && [ "$self" -ge 1 ]; then
  yes "lint and the tests pass — on THIS head, $short, not on an earlier one"
  note "gate-selftest passed too, so those results are worth something:"
  note "a gate that cannot reject its own fail fixture produces no verdict."
else
  no "the gates are not green on $short ($bad not passing, self-test $self)"
fi

# --- is anyone else in staging? ------------------------------------------
holder=$(gh pr list --repo "$R" --state open --label deploy:staging \
          --json number -q "[.[].number]|map(select(. != $pr))|first // empty" 2>/dev/null || echo "?")
if [ "$holder" = "?" ]; then
  no "I could not check who holds the berth." 4
elif [ -z "$holder" ]; then
  yes "nobody else is in staging — the berth is free"
else
  no "someone else IS in staging: #$holder holds the berth" 5
  note "one path to production, one change at a time. Wait, or ask them."
fi

# --- is the estate open to ordinary changes? ------------------------------
#
# ONE RULE, TWO CAUSES. A standard or normal change may not progress while
# either is true:
#
#   a FREEZE is declared    -- `freeze` on any open PR, or a scheduled freeze
#                              overlapping this window
#   an EMERGENCY is in flight -- itil:emergency on any other open PR
#
# They block for the same reason and it is not "two risky things at once". A
# freeze says the estate is in a state where normal change is unsafe. An
# emergency says someone is actively changing production outside the normal
# path -- so the estate is moving under you, your staging pass describes a
# world that no longer exists, and guard 4b will invalidate you anyway. Better
# to stop here than to spend a berth and a window finding that out.
#
# THE ONLY EXEMPTION IS BEING AN EMERGENCY YOURSELF. An emergency is what a
# freeze is for; blocking it would mean the freeze prevents its own remedy.
# itil:emergency is a person's declaration (change/label-owners.tsv) and
# never inferred.
is_emg=$(echo "$labels" | tr ' ' '\n' | grep -cx 'itil:emergency' || true)

# A change is ONE class. itil:standard is derived by the labeller from the
# diff; itil:emergency is declared by a person. Nothing reconciles them, so a
# PR can carry both -- observed on #2. That is not a nuance, it is a change
# whose class is undefined, and every rule below branches on the class.
# Refuse rather than pick one: picking would mean the pipeline deciding whether
# something is an emergency, which is a person's call by declaration.
_std=$(echo "$labels" | tr ' ' '\n' | grep -cx 'itil:standard' || true)
_nrm=$(echo "$labels" | tr ' ' '\n' | grep -cx 'itil:normal' || true)
if [ "$is_emg" -gt 0 ] && [ $((_std + _nrm)) -gt 0 ]; then
  no "this change has TWO classes: itil:emergency and $([ "$_std" -gt 0 ] && echo itil:standard || echo itil:normal)" 2
  note "the labeller derives the class from the diff; a person declares an"
  note "emergency. Nothing reconciles them, so both are sitting here and every"
  note "rule below branches on which one is true."
  note "recovery: a person removes the class that is wrong. Not the pipeline --"
  note "deciding whether something is an emergency is a declaration, not a"
  note "derivation."
fi

# THE HOLDER IS AN ISSUE (#1), NOT A PULL REQUEST.
#
# This read `gh pr list --label freeze`, so declaring a freeze meant hanging the
# label on some open PR -- and PR #48 showed what that costs for `emergency`:
# the write that closes the estate to everyone is the write that exempts its own
# carrier. `freeze` escaped the worst of it only because nothing reads it as a
# classification. It still had the smaller problems: the state vanished when its
# carrier merged, and an estate with no open PRs could not be frozen at all.
#
# An issue cannot be deployed, so there is no exemption it could be handed.
#
# Open PRs are STILL read, because labels linger from before the holder existed
# and a freeze nobody can see is worse than a duplicated one. Either source
# closes the estate; the holder is named first so a reader knows which spoke.
ESTATE_ISSUE="${ESTATE_ISSUE:-1}"
_held=$(gh issue view "$ESTATE_ISSUE" --repo "$R" --json labels \
          -q '[.labels[].name]|join(" ")' 2>/dev/null || echo "?")
_stray=$(gh pr list --repo "$R" --state open --label freeze \
          --json number,title -q '[.[]|"#\(.number) \(.title)"]|join("; ")' 2>/dev/null || echo "?")
if [ "$_held" = "?" ] || [ "$_stray" = "?" ]; then
  frozen="?"
elif echo "$_held" | tr ' ' '\n' | grep -qx freeze; then
  frozen="declared on the estate holder, issue #$ESTATE_ISSUE${_stray:+; also on $_stray}"
else
  frozen="$_stray"
fi
# THE ESTATE'S EMERGENCY IS A DIFFERENT FACT FROM THIS CHANGE'S CLASS.
#
# This read used to be itil:emergency on other PRs -- the same label line 147
# reads on THIS PR to grant an exemption. One label, two subjects, and the
# collision is not cosmetic:
#
#   an emergency handled OUTSIDE the pipeline has no PR to classify. To make
#   the estate show it, you hang itil:emergency on some open PR -- and that
#   hands THAT PR a bypass of every blocker. The one change that must not
#   proceed becomes the only one that may.
#
# So the estate-level fact is its own bare label, symmetric with `freeze`:
# both are properties of the world, neither is a property of any change, and
# neither grants anything to whatever PR happens to carry it.
#
# itil:emergency still grants the exemption, because that is a claim about the
# CHANGE -- this one outranks the others. `emergency` never does.
#
# Found by sim/ and confirmed by TLC as NoSplitEmergency (PR #48).
# NO SELF-EXCLUSION. That was right for itil:emergency -- a change does not
# block itself -- and is wrong here. `emergency` is a property of the WORLD,
# so it blocks everyone, including whichever PR happens to be carrying the
# flag. Excluding self would mean the PR you hung the estate flag on is the
# one change the estate does not stop, which is the exact defect the split
# was made to remove, surviving one level down.
emg=$(gh pr list --repo "$R" --state open --label emergency \
       --json number -q "[.[].number]|join(\", #\")" 2>/dev/null || echo "?")

if [ "$frozen" = "?" ] || [ "$emg" = "?" ]; then
  no "I could not check whether the estate is open." 4
elif [ "$is_emg" -gt 0 ]; then
  yes "this is itil:emergency -- the freeze and queue rules do not apply to it"
  [ -n "$frozen" ] && note "freeze in force ($frozen); an emergency is what a freeze is FOR."
  [ -n "$emg" ]    && note "an emergency is in flight on the estate (#$emg)"
  note "this will be in the PIR, and guard 2 and guard 5 still have no bypass."
elif [ -n "$frozen" ]; then
  no "a DEPLOYMENT FREEZE is in force" 3
  note "declared on: $frozen"
  note "standard and normal changes do not progress during a freeze."
  note "recovery: wait for the label to come off, or have a person declare"
  note "this itil:emergency -- their call, never yours."
elif [ -n "$emg" ]; then
  no "an EMERGENCY is in flight on the estate (#$emg)" 2
  note "standard and normal changes do not progress while one is running."
  note "it will land under you and invalidate your staging pass (guard 4b),"
  note "so stopping now costs you a wait; proceeding costs you the berth,"
  note "the window and the revalidation as well."
  note "recovery: wait for #$emg to settle, then re-request."
else
  yes "the estate is open -- no freeze, no emergency in flight"
fi

# --- is a person holding this deliberately? ------------------------------
#
# REJECTED SEMANTICS (2026-09-13). hold:staging is superseded by `freeze` for
# the estate and by simply not approving for one change. The check stays so a
# label left over from before still stops a deploy rather than being silently
# ignored -- removing the check would be more dangerous than keeping it.
case " $labels " in
  *" hold:staging "*)
    no "a person put hold:staging on this — they want to look before it promotes" 2
    note "only a person may remove it. That is what makes it a hold." ;;
  *) yes "nobody has put a hold on this change" ;;
esac

# --- what am I actually about to move? -----------------------------------
printf '\n'
if [ -n "$groups" ]; then
  note "this deploys: $groups"
  n=$(printf '%s' "$groups" | wc -w | tr -d ' ')
  [ "$n" -gt 1 ] && note "$n apps at once — larger blast radius than a single-app change"
else
  note "this deploys NOTHING — no app:* label. Check that is what you meant."
fi
note "labels: $labels"

printf '\n'
if [ "$rc" = 0 ]; then printf '  \033[32mproceed\033[0m\n\n'
else printf '  \033[31mdo not proceed\033[0m (exit %s)\n\n' "$rc"; fi
exit "$rc"
