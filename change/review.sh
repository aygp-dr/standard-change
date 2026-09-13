#!/bin/sh
# review.sh <pr> [--approve|--check] -- guard 4's first rung, posted or inspected.
#
# Guard 4 wants a review by someone who is not the author. This is the only
# place a credential other than the operator's is used, so everything about it
# is written to be visible at the call site.
#
# WHAT IT REFUSES TO DO. It will not post an approval it cannot attribute to a
# distinct identity. An approval whose actor is the author is not a weaker
# approval, it is a false one -- and `review:proxy` records already carry that
# exact defect today: every record on this repo names `aygp-dr`, the author of
# the PR it approves. The record is honest only because its NAME says proxy.
set -eu
cd "$(dirname "$0")/.."
PR="${1:?usage: review.sh <pr> [--approve|--check]}"
MODE="${2:---check}"
R="${GH_REPO:-${GITHUB_REPOSITORY:-aygp-dr/standard-change}}"

# Load the reviewer credential WITHOUT exporting it. gh reads GH_TOKEN from the
# environment and it beats `gh auth`, so exporting this would silently replace
# the operator for every later gh call in this process -- including merges and
# deploys. It is read into a shell variable and handed to exactly one command.
REVIEWER_GH_TOKEN=''
REVIEWER_LOGIN=''
if [ -f .env ]; then
  REVIEWER_GH_TOKEN=$(sed -n 's/^REVIEWER_GH_TOKEN=//p' .env | head -1)
  REVIEWER_LOGIN=$(sed -n 's/^REVIEWER_LOGIN=//p' .env | head -1)
fi

HEAD=$(gh pr view "$PR" --repo "$R" --json headRefOid -q .headRefOid)
SHORT=$(echo "$HEAD" | cut -c1-7)
AUTHOR=$(gh pr view "$PR" --repo "$R" --json author -q .author.login)
OPERATOR=$(gh api user -q .login 2>/dev/null || echo '?')
DECISION=$(gh pr view "$PR" --repo "$R" --json reviewDecision -q '.reviewDecision // ""')
NREV=$(gh api "repos/$R/pulls/$PR/reviews" --jq 'length' 2>/dev/null || echo 0)
# NOTE: `gh api` has no --arg; that is a jq flag and gh rejects it. Passing it
# here made this fall back to 0 silently, and made the verification below exit 1
# AFTER the approval had already posted -- reporting failure for a successful
# approval. Values are interpolated by the shell into the jq program instead.
NAPP=$(gh api "repos/$R/pulls/$PR/reviews" \
  --jq '[.[]|select(.state=="APPROVED")]|length' 2>/dev/null || echo 0)

echo "review state for #$PR @ $SHORT"
printf '  %-22s %s\n' "pr author"          "$AUTHOR"
printf '  %-22s %s\n' "operator (gh auth)" "$OPERATOR"
printf '  %-22s %s\n' "reviewDecision"     "${DECISION:-<empty>}"
printf '  %-22s %s\n' "reviews on the pr"  "$NREV (approved: $NAPP)"
printf '  %-22s %s\n' "REVIEWER_LOGIN"     "${REVIEWER_LOGIN:-<unset>}"
printf '  %-22s %s\n' "REVIEWER_GH_TOKEN"  "$([ -n "$REVIEWER_GH_TOKEN" ] && echo '<set>' || echo '<empty>')"

# THE IDENTITY IS ASKED OF THE FORGE, NEVER READ OFF THE CONFIG. REVIEWER_LOGIN
# is what someone typed; `gh api user` under the token is who the token IS.
# Prefer a fact the system reports about itself over one the caller supplies.
ACTUAL=''
if [ -n "$REVIEWER_GH_TOKEN" ]; then
  ACTUAL=$(GH_TOKEN="$REVIEWER_GH_TOKEN" gh api user -q .login 2>/dev/null || echo '')
  printf '  %-22s %s\n' "token resolves to" "${ACTUAL:-<invalid token>}"
  if [ -n "$REVIEWER_LOGIN" ] && [ "$ACTUAL" != "$REVIEWER_LOGIN" ]; then
    echo "refused: REVIEWER_LOGIN says '$REVIEWER_LOGIN', the token is '$ACTUAL'." >&2
    exit 5
  fi
fi

CALL="gh api repos/$R/pulls/$PR/reviews -X POST -f commit_id=$HEAD -f event=APPROVE"

if [ "$MODE" != "--approve" ]; then
  echo
  echo "  the call an approval would make (commit_id pins it to THIS build):"
  echo "    GH_TOKEN=\$REVIEWER_GH_TOKEN $CALL"
  exit 0
fi

if [ -z "$REVIEWER_GH_TOKEN" ]; then
  echo "refused: no REVIEWER_GH_TOKEN. Nothing here can post a review that is" >&2
  echo "  attributable to anyone but the author, and an approval nobody can be" >&2
  echo "  held to is worse than none. Use change/observe.sh to write a" >&2
  echo "  review:proxy RECORD instead -- it says proxy, and a reader can tell." >&2
  exit 3
fi
if [ "$ACTUAL" = "$AUTHOR" ]; then
  echo "refused: the reviewer token IS the author ($AUTHOR)." >&2
  echo "  GitHub would reject this call anyway; refusing here so the reason is" >&2
  echo "  a stated rule rather than an error message we got lucky with." >&2
  exit 6
fi

GH_TOKEN="$REVIEWER_GH_TOKEN" $CALL -f body="Approved by $ACTUAL against $SHORT." >/dev/null

# VERIFY BY ASKING THE FORGE, not by trusting the exit code of the call above.
OK=$(gh api "repos/$R/pulls/$PR/reviews" \
  --jq "[.[]|select(.state==\"APPROVED\")|select(.commit_id==\"$HEAD\")|select(.user.login!=\"$AUTHOR\")]|length")
[ "$OK" -ge 1 ] || { echo "refused: posted, but the forge reports no such approval." >&2; exit 7; }
echo "  approved: $ACTUAL on $SHORT, confirmed by re-reading the forge"
