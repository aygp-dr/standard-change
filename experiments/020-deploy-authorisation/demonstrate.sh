#!/bin/sh
# demonstrate.sh -- nothing may reach a protected environment unauthorised. (#32)
#
# HYPOTHESIS. Every guard in this repository sits on the DECISION to deploy --
# a label, a checklist, a merge. Nothing guarded the ACT, so calling the deploy
# target directly reached a protected environment past all of them, and did:
# staging served 766a522 for four minutes before a PR for it existed, and the
# gates that later passed ran against something nobody had authorised.
#
# Falsifiable form: /if the deploy target must name its authorisation, then a
# SHA that is the head of no open PR cannot reach staging or production, a
# forge that cannot be reached refuses rather than proceeds, and a dev block is
# unaffected./
#
# SUCCESS CRITERION. Twelve assertions. The load-bearing ones:
#   C2  the #32 incident itself: a SHA with no open PR is refused
#   C3  the forge unreachable is exit 4, NOT 0 and NOT 1  (fail closed)
#   C9  the guard runs BEFORE the deploy touches anything
#   C1  a dev block asks the forge nothing at all
#
# NO SERVER, NO PORTS, NO DEPLOY. `gh` is stubbed; gates/preflight.sh is
# stubbed to a chosen exit code because what is under test is whether
# authorize.sh RECEIVES a verdict, not whether preflight produces the right
# one -- preflight is tested where it lives. Nothing here runs a deploy target
# to completion; C9 is a static ordering assertion and says so.
#
# RUN:
#   ./experiments/020-deploy-authorisation/demonstrate.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
here="$root/experiments/020-deploy-authorisation"
work=$(mktemp -d "${TMPDIR:-/tmp}/depauth.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok    %-4s %s\n' "$1" "$2"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %-4s %s\n' "$1" "$2"; }
check(){ if [ "$3" = "$4" ]; then ok "$1" "$2"; else bad "$1" "$2 -- expected [$3] got [$4]"; fi; }

# A forge: the open PRs it knows about, and whether it is reachable.
forge() { # forge <name> <prs-json|-> [down]
  _d="$work/f-$1"; mkdir -p "$_d"; : > "$_d/calls"
  [ "$2" = - ] || printf '%s' "$2" > "$_d/prs"
  [ "${3:-}" = down ] && : > "$_d/down"
  echo "$_d"
}

# Run change/authorize.sh in a tree whose gates/preflight.sh is a stub exiting
# a chosen code. authorize.sh, change/schedule.sh and the rest are the real
# files, copied so the stub cannot escape into the working tree.
authorize() { # authorize <forge-dir> <preflight-rc> <env> <sha>
  _f="$1"; _prc="$2"; shift 2
  _t="$work/tree"; rm -rf "$_t"; mkdir -p "$_t/change" "$_t/gates"
  cp "$root/change/authorize.sh" "$_t/change/"
  printf '#!/bin/sh\necho "  (stub preflight for #$1 -> $2)"\nexit %s\n' "$_prc" \
    > "$_t/gates/preflight.sh"
  printf '#!/bin/sh\necho CHG-STUB-WINDOW\n' > "$_t/change/schedule.sh"
  chmod +x "$_t/gates/preflight.sh" "$_t/change/schedule.sh"
  set +e
  A_OUT=$(PATH="$here/stub:$PATH" STUB_DIR="$_f" GH_REPO=aygp-dr/standard-change \
            sh "$_t/change/authorize.sh" "$@" 2>"$work/err"); A_RC=$?
  set -e
  A_ERR=$(cat "$work/err")
}

open_pr='[{"number":31,"headRefOid":"766a5220000000000000000000000000000000aa"}]'

echo "== C1 -- a dev block is unrestricted, and asks nothing"

f=$(forge dev "$open_pr")
authorize "$f" 0 dev-3 deadbee1
check C1  "dev block authorised without a forge" "0" "$A_RC"
check C1b "and the forge was never asked" "0" "$(wc -l < "$f/calls" | tr -d ' ')"

echo ""
echo "== C2/C3 -- the two ways a protected deploy must stop"

# C2. THE INCIDENT. 766a522 was pushed, deployed to staging, and only then did
# a PR exist for it. With no open PR at its head it must not reach staging.
f=$(forge nopr '[]')
authorize "$f" 0 staging 766a522
check C2  "a SHA that heads no open PR is refused" "1" "$A_RC"
check C2b "and says so in those words" "yes" \
  "$(printf '%s' "$A_ERR" | grep -q 'not the head of any open pull request' && echo yes || echo no)"

# C3. FAIL CLOSED. The forge is the new dependency this fix introduces, and
# the honest cost of it. Deploying anyway and stamping the record "could not
# verify" produces an authorised-LOOKING estate, which is worse.
f=$(forge down "$open_pr" down)
authorize "$f" 0 staging 766a522
check C3  "forge unreachable -> exit 4, not 0 and not 1" "4" "$A_RC"
check C3b "and names it as could-not-check, not as absence" "yes" \
  "$(printf '%s' "$A_ERR" | grep -q "not 'there is no PR'" && echo yes || echo no)"

echo ""
echo "== C4-C6 -- the authorised path, and preflight's verdict"

# C4. The head of an open PR, everything else clear.
f=$(forge good "$open_pr")
authorize "$f" 0 staging 766a522
check C4  "SHA heads an open PR and preflight agrees -> authorised" "0" "$A_RC"
check C4b "the record names the PR and the window" "yes" \
  "$(printf '%s' "$A_OUT" | grep -q 'pr=31 window=CHG-STUB-WINDOW' && echo yes || echo no)"

# C5. preflight's exit code is PASSED THROUGH, not flattened to 1. A freeze and
# a refusal are different facts and docs/exit-codes.org keeps them apart.
f=$(forge frozen "$open_pr")
authorize "$f" 3 staging 766a522
check C5 "preflight exit 3 (freeze) is passed through, not flattened" "3" "$A_RC"

# C6. And 4 in particular is not turned into a refusal or a pass.
f=$(forge unknown "$open_pr")
authorize "$f" 4 staging 766a522
check C6 "preflight exit 4 (could not check) is passed through" "4" "$A_RC"

echo ""
echo "== C7/C8 -- the break glass, and environments nobody classified"

# C7. The issue asked for a break-glass "visible in the record rather than an
# unlogged env var". It must authorise, and it must appear on stdout, which is
# what the deploy target writes into version.json.
f=$(forge glass '[]')
set +e
A_OUT=$(PATH="$here/stub:$PATH" STUB_DIR="$f" DEPLOY_BREAK_GLASS='estate down, restoring prod' \
          sh "$root/change/authorize.sh" staging 766a522 2>"$work/err"); A_RC=$?
set -e
check C7  "break glass authorises" "0" "$A_RC"
check C7b "and the reason is on stdout, for the deployment record" "yes" \
  "$(printf '%s' "$A_OUT" | grep -q 'break-glass: estate down, restoring prod' && echo yes || echo no)"

# C8. An environment this script has never been taught is not "probably a dev
# block". Deciding an unclassified environment is unprotected is the same
# assumption that created the issue.
f=$(forge weird "$open_pr")
authorize "$f" 0 team-alpha 766a522
check C8 "an unclassified environment is refused, not assumed open" "1" "$A_RC"

echo ""
echo "== C9 -- the guard runs before the deploy touches anything"

# STATIC. Running a deploy target to its refusal on this host would put the
# real staging block's ports and deployment worktree one bug away from being
# touched, so this asserts the ORDER in the file instead: the authorisation
# call must precede the first destructive operation (the port-kill loop). A
# guard that runs after the estate has been stopped is not a guard.
# COMMENTS ARE STRIPPED, AND THAT IS THE WHOLE ASSERTION.
#
# The first cut of C9/C9b grepped the raw file. Both targets carry comments
# that NAME authorize.sh and quote `authorize.sh | sed` as the thing never to
# write, so the greps matched the documentation and passed no matter what the
# code did. Mutation proved it: deleting the call outright (P1, P2) and piping
# it (P3) all SURVIVED -- three assertions that could not fail, guarding the
# three things that matter most here. Found exactly the way spec.org says these
# are found, and not by reading.
#
# codeline prints the number of the first line whose CODE, comment stripped,
# matches -- and nothing if there is none.
codeline() { awk -v re="$2" '{ l=$0; sub(/#.*/,"",l); if (l ~ re) { print NR; exit } }' "$1"; }
codeof()   { awk -v re="$2" '{ l=$0; sub(/#.*/,"",l); if (l ~ re) { print l; exit } }' "$1"; }

for t in targets/node/deploy.sh targets/bastille/deploy.sh; do
  a=$(codeline "$root/$t" 'authorize\.sh')
  case "$t" in
    *node*) d=$(codeline "$root/$t" 'sockstat') ;;
    *)      d=$(codeline "$root/$t" 'sudo install -d') ;;
  esac
  if [ -z "$a" ]; then r="NOT CALLED AT ALL"
  elif [ -z "$d" ]; then r="no destructive step found"
  elif [ "$a" -lt "$d" ]; then r=before
  else r="after (line $a vs $d)"; fi
  check "C9" "$t: authorisation precedes the first destructive step" "before" "$r"

  # C9c. The call must propagate the exit code. Without `|| exit`, a refusal
  # sets a variable and the deploy carries on.
  code=$(codeof "$root/$t" 'authorize\.sh')
  check "C9c" "$t: the refusal is propagated (|| exit)" \
    "yes" "$(printf '%s' "$code" | grep -q '|| *exit' && echo yes || echo no)"
done

# C9b. And it must be unpipeable. `authorize.sh | sed` makes $? sed's, which is
# how the driver walked past guard 4 into production (D16). Tested on the
# invocation's own code line: strip `||`, and any `|` left is a pipe.
piped=0
for t in targets/node/deploy.sh targets/bastille/deploy.sh; do
  code=$(codeof "$root/$t" 'authorize\.sh')
  rest=$(printf '%s' "$code" | sed 's/||//g')
  case "$rest" in *'|'*) piped=$((piped+1)) ;; esac
done
check C9b "the authorisation call is never piped" "0" "$piped"

echo ""
echo "  $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
