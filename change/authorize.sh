#!/bin/sh
# authorize.sh <env> <sha> -- may this build be installed in THAT environment?
#
# THE HOLE THIS CLOSES (issue #32). Every guard in this repository is on the
# decision to deploy. Nothing guarded the ACT of deploying, so a person or an
# agent with a shell reached a protected environment by calling the target
# directly, and did:
#
#   1. commit + push feat/error-page-red                   766a522
#   2. ./targets/node/deploy.sh staging 766a522            <- no PR
#   3. gh pr create                                        -> #31
#   4. gates run, pass
#
# Staging served an unreviewed, unscheduled, unguarded build for ~4 minutes and
# the gates that later passed ran against something nobody had authorised. They
# passed. That is luck, not process.
#
# WHY THIS IS NOT A SECOND IMPLEMENTATION OF GUARD 3. scenarios.org D9 deferred
# exactly this fix, and the reason it gave was good: "enforcing the window a
# second time inside every target would be a second implementation of guard 3,
# which is the defect this repo has already hit twice". So this script does not
# re-implement the window, the freeze, the lock, the queue or the gates. It
# calls gates/preflight.sh -- the one existing implementation of that checklist
# -- and honours its exit code. Guard 3 stays implemented once; what changes is
# that a machine now RECEIVES the answer instead of a person reading it.
#
# The only new logic here is the question preflight cannot ask, because
# preflight is given a PR and the deploy target is given a SHA: IS THIS SHA THE
# HEAD OF AN OPEN PULL REQUEST AT ALL? Nothing else in the repo asks that, and
# it is the question that would have refused 766a522.
#
# WHY IT IS DUE NOW, not deferred. D9's own revisit trigger is "the first
# deployment initiated by automation rather than by a person ... a workflow
# that calls a target directly, a scheduled job, an agent driving deploy.sh
# unattended". Both have happened: #32 was an agent driving deploy.sh, and
# .github/workflows/deploy-staging.yml calls the target directly today. At that
# moment, in D9's words, "there is no checklist, and preflight's exit code is
# advice nobody receives".
#
# CONTRACT
#   stdout   ONE line, the authorisation, for the deployment record
#   stderr   everything a person needs to read
#   exit 0   authorised
#        1   refused -- this SHA heads no open PR, or the env is unclassified
#        4   I COULD NOT CHECK (forge unreachable) -- blocks
#        *   ANY OTHER non-zero is gates/preflight.sh's own code, passed
#            through unchanged: 2 lock, 3 freeze, 5 queue busy, 6 behind main
#            or draft, and whatever it grows next.
#
#   The pass-through is deliberately open-ended. Enumerating preflight's codes
#   here would be a second copy of its contract, drifting the moment it gains
#   one -- and it already had: a real run against #75 returned 6 (draft PR),
#   which this header's first cut did not list. Codes mean what
#   docs/exit-codes.org says they mean; this script does not reinterpret them.
#
# Dev blocks are unrestricted. That is what makes them dev blocks.
#
#   ./change/authorize.sh staging 766a522
#   ./change/authorize.sh dev-3 $(git rev-parse HEAD)
set -eu
env="${1:?usage: authorize.sh <env> <sha>}"
sha="${2:?usage: authorize.sh <env> <sha>}"
root=$(cd "$(dirname "$0")/.." && pwd)
R="${GH_REPO:-${GITHUB_REPOSITORY:-aygp-dr/standard-change}}"

say() { echo "$@" >&2; }

# Which environments are protected, and which schedule env covers them. The
# calendar books `staging` and `production`; blue and green are replicas of
# production, not environments the calendar knows about.
case "$env" in
  dev-[0-9])
    say "authorize: $env is a dev block -- unrestricted by design."
    echo "dev-block: no authorisation required"
    exit 0 ;;
  staging)                          penv=staging ;;
  production|production-blue|production-green) penv=production ;;
  *)
    # An environment nobody has classified is not "probably fine". The team
    # tier (9100) is declared in environments.tsv and cannot promote; anything
    # else is a name this script has never been taught. Refuse either way:
    # deciding that an unknown environment is unprotected is the assumption
    # that created this issue one level up.
    say "REFUSED: authorize.sh does not know whether '$env' is protected."
    say "  It is neither a dev block (dev-0..dev-9) nor a protected environment"
    say "  (staging, production, production-blue, production-green)."
    say "  An environment nobody has classified is not one to deploy to."
    exit 1 ;;
esac

# --- the break glass, which is RECORDED ---------------------------------------
#
# The issue asked for "a documented break-glass that is visible in the record
# rather than an unlogged env var". So it is an env var that CANNOT be silent:
# it must carry a reason, it is shouted on stderr, and the reason is returned
# on stdout to be written into the deployment record. An estate deployed this
# way says so about itself, which is the difference between a break-glass and
# a bypass.
if [ -n "${DEPLOY_BREAK_GLASS:-}" ]; then
  say "*** BREAK GLASS -- $env <- $sha authorised by a human override ***"
  say "    reason: $DEPLOY_BREAK_GLASS"
  say "    No PR, window, berth or gate was checked. This is recorded in the"
  say "    deployment record and the estate will report it about itself."
  echo "break-glass: $DEPLOY_BREAK_GLASS"
  exit 0
fi

# --- 1. is this SHA the head of an OPEN pull request? -------------------------
#
# FAIL CLOSED. This needs the forge, so a protected deploy now depends on the
# forge being reachable. That is a real cost and it is the right one: the
# alternative is to deploy and stamp the record "could not verify", which
# produces an authorised-LOOKING estate. Unreachable is not falsified, and it
# is not authorised either.
if ! prs=$(gh pr list --repo "$R" --state open --limit 200 \
             --json number,headRefOid 2>/dev/null); then
  say "REFUSED (exit 4): could not ask $R which pull requests are open."
  say "  This is 'I could not check', not 'there is no PR' and not 'it is fine'."
  say "  A protected environment deploys changes under review; with no forge"
  say "  there is no way to know whether this is one. dev-N needs none of this."
  say "  If the forge is down and this deploy cannot wait, break the glass:"
  say "    DEPLOY_BREAK_GLASS='<why>' ./targets/node/deploy.sh $env $sha"
  exit 4
fi

pr=$(printf '%s' "$prs" | jq -r --arg s "$sha" \
  '[.[] | select(.headRefOid | startswith($s)) | .number] | first // empty')

if [ -z "$pr" ]; then
  say "REFUSED: $sha is not the head of any open pull request."
  say "  Protected environments deploy changes under review. dev-N does not."
  say "  This is the check that would have refused 766a522 (issue #32):"
  say "  staging served it for four minutes before a PR existed for it."
  say "  Open a PR for this commit, or deploy it to a dev block instead:"
  say "    ./targets/node/deploy.sh dev-3 $sha"
  exit 1
fi
say "authorize: $sha is the head of open PR #$pr"

# --- 2. everything else, asked of the ONE thing that implements it ------------
#
# UNPIPEABLE. Capture, test, then format -- never `preflight | sed`. That is
# class 6 of the taxonomy, and it is how change/activate.sh walked past guard
# 4's refusal into production (D16). The whole value of this script is that it
# receives an exit code somebody else's checklist produced, so losing it here
# would be the joke writing itself.
set +e
out=$("$root/gates/preflight.sh" "$pr" "$penv" 2>&1)
prc=$?
set -e
printf '%s\n' "$out" | sed 's/^/    /' >&2

if [ "$prc" -ne 0 ]; then
  say ""
  say "REFUSED (exit $prc): gates/preflight.sh says #$pr may not deploy to $penv now."
  say "  Nothing above was re-implemented here -- that is guard 3 and its"
  say "  neighbours answering, in the one place they are implemented. What is"
  say "  new is that the deploy target asked, and stopped."
  exit "$prc"
fi

# The window is named in the record because a deployment that cannot say which
# entitlement it used is one nobody can audit afterwards. `current` is re-read
# HERE, at the moment of reliance, not trusted from when it was booked.
win=$("$root/change/schedule.sh" current "$pr" "$penv" 2>/dev/null || echo none)
say "authorize: #$pr is clear for $penv (window $win)"
echo "pr=$pr window=$win env=$penv verified=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
