#!/bin/sh
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
#   staging e2e                  contracts hold on staging
#   staging smoke                a browser can actually use it
#   staging uat                  a person used it and accepted it
#
# WHAT CHANGED, AND WHY (issue #16). Naming the measurement fixed one hole and
# left the bigger one open: a label names the measurement but not the BUILD. It
# said "e2e passed on staging" and could not say on what. The stack was kept
# honest by a cleanup step -- the labeller withdraws every observation on
# `synchronize` -- and on #11 that step did not fire. `staging:e2e` and
# `staging:smoke`, taken on 9d85a33, sat on a PR whose head was baed821 and
# this guard read them as authorization. A guard whose soundness depends on
# some other workflow having fired is sound only as often as that workflow
# fires, and it fails OPEN when it does not.
#
# So the stack is now split by a property of the measurement itself:
#
#   REPEATABLE     e2e, smoke. A machine took it and a machine can take it
#                  again. Authorizing from a persisted label is never
#                  necessary, so it is never worth the risk. This guard reads
#                  the observation RECORD -- a PR comment naming the
#                  environment, the instrument, the verdict and the SHA -- and
#                  requires the most recent one to name THIS head. A record
#                  from an older build does not go stale: it stays true about
#                  the build it names and stops matching. Nothing has to fire.
#
#   NOT REPEATABLE uat. A person used the site. No script can re-run that, so
#                  the acceptance is durable and the label stays -- it is the
#                  human's own signal and a human may withdraw it. But it is
#                  still an observation about a BUILD, so it too must be backed
#                  by a record naming this head. A person who accepted 7cd3281
#                  has said nothing about 8370c74.
#
# The difference between the two is not how much they are trusted. It is that
# one of them can be re-taken and the other cannot.
#
# The labels have not gone away and they are not lying around unread: they are
# the CURRENT-RUN signal the deployment process sets as it goes. What they no
# longer are is the thing this guard authorizes on.
set -eu
pr="${1:?usage: guard4.sh <pr>}"
repo="${GH_REPO:-${GITHUB_REPOSITORY:-aygp-dr/standard-change}}"
EV="$(dirname "$0")/evidence.sh"
ENV_="${OBSERVATION_ENV:-staging}"
# Instruments whose measurement a machine can re-take. Authorized from the
# record only.
REPEATABLE="${REPEATABLE_OBSERVATIONS:-e2e smoke}"
# Instruments whose measurement a machine cannot re-take. Record AND label.
ATTESTED="${ATTESTED_OBSERVATIONS:-uat}"

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

# LOCAL GATE REPORTS, same as gates/preflight.sh. gates/report.sh runs the
# suite where it can run and posts commit statuses under local/. They are a real
# measurement of this SHA -- the gates ran and each status was gated on an exit
# code -- and they are prefixed so a reader can tell a host run from a CI run.
lok=$(gh api "repos/$repo/commits/$head/status" \
  --jq '[.statuses[]|select(.context|startswith("local/"))|select(.state=="success")]|length' 2>/dev/null || echo 0)
lbad=$(gh api "repos/$repo/commits/$head/status" \
  --jq '[.statuses[]|select(.context|startswith("local/"))|select(.state!="success")]|length' 2>/dev/null || echo 0)
lself=$(gh api "repos/$repo/commits/$head/status" \
  --jq '[.statuses[]|select(.context=="local/gate-selftest" and .state=="success")]|length' 2>/dev/null || echo 0)

bad=$(gh api "repos/$repo/commits/$head/check-runs" \
  --jq '[.check_runs[]|select(.name|test("^(gate-selftest|lint|test|e2e)$"))|select(.conclusion!="success")]|length')
if [ "$lbad" -eq 0 ] && [ "$lok" -ge 3 ] && [ "$lself" -ge 1 ]; then
  printf '  ok    %-16s %s\n' "gates" "$lok local/ contexts green on $short (host run, not CI)"
elif [ "$bad" -eq 0 ]; then printf '  ok    %-16s %s\n' "check runs" "green on $short"
else printf '  FAIL  %-16s %s\n' "check runs" "$bad not green on $short"; rc=1; fi

# Each instrument's most recent record must be a pass, and it must name the
# head being authorized. Three ways to fail, all closed:
#   no record        the instrument never ran, or its recording failed
#   verdict=fail     the last thing it saw was a failure
#   sha != head      it measured a different build
observed() {
  inst="$1"; need_label="$2"
  name="$ENV_:$inst"
  if ev=$("$EV" latest "$pr" "$ENV_" "$inst" 2>/dev/null); then
    verdict=${ev%% *}; rest=${ev#* }; evsha=${rest%% *}; who=${rest#* }
    if [ "$verdict" != pass ]; then
      printf '  FAIL  %-16s last observation is a FAILURE on %s (by %s)\n' "$name" "$evsha" "$who"
      rc=1
    elif [ "$evsha" != "$short" ]; then
      printf '  FAIL  %-16s observed %s, head is %s -- that measurement is about a different build\n' \
        "$name" "$evsha" "$short"
      rc=1
    else
      printf '  ok    %-16s observed %s by %s\n' "$name" "$evsha" "$who"
    fi
  else
    printf '  FAIL  %-16s no observation recorded -- nothing measured this build\n' "$name"
    rc=1
  fi
  # The durable half of a non-repeatable observation: the person's own signal,
  # which the person may withdraw. Required IN ADDITION to the record, never
  # instead of it.
  if [ "$need_label" = yes ]; then
    case " $labels " in
      *" $name "*) printf '  ok    %-16s label present (a person has not withdrawn it)\n' "$name" ;;
      *) printf '  FAIL  %-16s label absent -- acceptance withdrawn\n' "$name"; rc=1 ;;
    esac
  fi
}

for inst in $REPEATABLE; do observed "$inst" no;  done
for inst in $ATTESTED;   do observed "$inst" yes; done

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
[ "$rc" = 0 ] && echo "  authorized: every required observation was taken on $short" \
              || echo "  NOT authorized"
exit "$rc"
