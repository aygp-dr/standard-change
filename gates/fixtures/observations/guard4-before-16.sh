#!/bin/sh
# FROZEN COPY of change/guard4.sh as of 1a97312, before issue #16.
#
# Not a strawman and not maintained: it is the guard exactly as it was, kept
# so gates/observation-test.sh can be negative-tested. A suite that cannot fail
# verifies nothing (spec.org, Verification contract), and the thing this
# suite must be able to detect is a marker from build A authorizing build B.
# --selftest runs the whole suite against this file and requires the
# stale-marker case to be AUTHORIZED here -- if it is not, the case does not
# reproduce the defect and its pass against the current guard means nothing.

# guard4.sh <pr> -- is this change authorized to reach production?
#
# Guard 4 used to ask one question: is `staging:passed` present? That label
# names no measurement and no environment, so it could be satisfied by
# observing something else -- which happened on 2026-09-13, when a pass from
# the node estate was used to overwrite a failure from the bastille estate and
# authorized a production deploy.
#
# It now asks for a STACK of named observations. Each names what was measured,
# so none of them can stand in for another:
#
#   check runs on the head SHA   lint, test, e2e, gate-selftest   (guard 2)
#   staging:e2e                  contracts hold on staging
#   staging:smoke                a browser can actually use it
#   staging:uat                  a person used it and accepted it
#
# The stack is ANDed, and it is checked against THIS head SHA, because every
# one of these observations is about a build.
set -eu
pr="${1:?usage: guard4.sh <pr>}"
repo="${GH_REPO:-${GITHUB_REPOSITORY:-aygp-dr/standard-change}}"
REQUIRED="${REQUIRED_OBSERVATIONS:-staging:e2e staging:smoke staging:uat}"

labels=$(gh pr view "$pr" --repo "$repo" --json labels -q '[.labels[].name]|join(" ")')
head=$(gh pr view "$pr" --repo "$repo" --json headRefOid -q .headRefOid)
short=$(echo "$head" | cut -c1-7)
rc=0

echo "guard 4 — the authorization stack for #$pr @ $short"

# A human approved THIS change. Not an observation -- nobody measured anything
# -- and not a request either: it is consent, and it is the one thing in the
# stack that is about the change rather than about a build's behaviour.
review=$(gh pr view "$pr" --repo "$repo" --json reviewDecision -q '.reviewDecision // "NONE"')
if [ "$review" = "APPROVED" ]; then printf '  ok    %-16s %s\n' "review" "APPROVED"
else printf '  FAIL  %-16s %s\n' "review" "$review"; rc=1; fi

bad=$(gh api "repos/$repo/commits/$head/check-runs" \
  --jq '[.check_runs[]|select(.name|test("^(gate-selftest|lint|test|e2e)$"))|select(.conclusion!="success")]|length')
if [ "$bad" -eq 0 ]; then printf '  ok    %-16s %s\n' "check runs" "green on $short"
else printf '  FAIL  %-16s %s\n' "check runs" "$bad not green on $short"; rc=1; fi

for o in $REQUIRED; do
  case " $labels " in
    *" $o "*) printf '  ok    %-16s present\n' "$o" ;;
    *)        printf '  FAIL  %-16s missing\n' "$o"; rc=1 ;;
  esac
done

# A failure observation present alongside its pass is a contradiction, not a
# pass. Both can be on a PR at once because they are recorded by whichever
# instrument ran last, and last is not the same as authoritative.
for f in staging:e2e-failed staging:smoke-failed; do
  case " $labels " in
    *" $f "*) printf '  FAIL  %-16s present -- a recorded failure has not been withdrawn\n' "$f"; rc=1 ;;
  esac
done

case " $labels " in
  *" hold:staging "*) printf '  FAIL  %-16s a person is holding this change\n' "hold:staging"; rc=1 ;;
esac

echo
[ "$rc" = 0 ] && echo "  authorized: every required observation is present on $short" \
              || echo "  NOT authorized"
exit "$rc"
