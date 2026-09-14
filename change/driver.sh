#!/bin/sh
# driver.sh <pr> -- one change, from change:start to change:end, on the node
# target. The process that "takes over" once a person has said start.
#
# WHAT IT IS. activate.sh ported to targets/node for the mini's estate: the
# shared staging block (worktrees/staging, :9010) and production block
# (worktrees/production, :9020), redeployed to the change's head. Every step
# is the pipeline's own script; this file only orders them and stops on the
# first refusal. It was written on 2026-09-14 after five agents ran the same
# sequence by hand (experiments/022) and the owner asked for the experiment
# again with the human doing one thing: say change:start.
#
# WHAT IT DOES NOT DO. Rebase. A machine rewriting a person's branch is a push
# on their behalf; a change behind main is refused with a comment and loses
# its markers (the lock-refusal rule), and the person rebases and says start
# again. Book a window: the bare-knuckle mode, recorded as a deviation in the
# PIR by settle.sh. Approve as a person: the approval is the second identity's
# standing delegation and the review says so.
#
# Exit: 0 landed and settled; 5 lock held; 6 behind main; 1 aborted (a step
# failed and abort.sh ended the release); 2 usage.
set -eu
PR="${1:?usage: driver.sh <pr>}"
R="${GH_REPO:-${GITHUB_REPOSITORY:-aygp-dr/standard-change}}"
export GH_REPO="$R"
cd "$(dirname "$0")/.."
STG=http://127.0.0.1:9010; PROD=http://127.0.0.1:9020
log() { printf '%s  driver #%s  %s\n' "$(date -u +%H:%M:%SZ)" "$PR" "$*"; }
say() { gh pr comment "$PR" --repo "$R" --body "$1" >/dev/null 2>&1 || true; }
fail() { # fail <step> <detail> -- end the release, every marker gone
  log "ABORT at $1: $2"
  ./change/abort.sh "$PR" "driver: $1 -- $2" >/dev/null 2>&1 || true
  exit 1
}
deploy() { # deploy <env> <sha>
  git -C "worktrees/$1" checkout -q --detach "$2"
  ( cd "worktrees/$1" && gmake -s stop >/dev/null 2>&1; nohup gmake dev >"/tmp/claude-501/driver-$1.log" 2>&1 & )
  port=$([ "$1" = staging ] && echo 9010 || echo 9020)
  i=0
  while [ $i -lt 60 ]; do
    got=$(curl -sI --max-time 2 "http://127.0.0.1:$port/" | tr -d '\r' | awk 'tolower($1)=="x-build-sha:"{print $2}')
    [ "$got" = "$2" ] && return 0
    sleep 1; i=$((i+1))
  done
  return 1
}

# --- 0. the change, and the intent -----------------------------------------
state=$(gh pr view "$PR" --repo "$R" --json state -q .state)
[ "$state" = OPEN ] || { log "#$PR is $state; nothing to drive"; exit 2; }
labels=$(gh pr view "$PR" --repo "$R" --json labels -q '[.labels[].name]|join(" ")')
case " $labels " in *" change:start "*) ;; *) log "no change:start on #$PR; a person has not said start"; exit 2 ;; esac
sha=$(gh pr view "$PR" --repo "$R" --json headRefOid -q '.headRefOid' | cut -c1-7)
git fetch -q origin

# --- 0b. a release begins clean -----------------------------------------------
# "But now all of the tickets are dirty" (the owner, 2026-09-14 23:39Z): five
# tickets carried verdicts from a release that never ended, and a retired
# label. A person saying start on such a ticket must not have to sweep it
# first -- the markers are a previous release's, and the release that left them
# owed a change:end it never wrote. So start pays that debt: every marker of a
# previous release goes, the person's own words (staging:hold, backfill-owed)
# stay, and the comment says what went so the sweep has an author (D21).
swept=''
for l in $labels; do
  case "$l" in
    change:start|staging:hold|change:backfill-owed|app:*|itil:*|control-plane) ;;
    staging:*|deploy:*|production:*|blocked:*|berth:*|release|release:start|change:*)
      gh pr edit "$PR" --repo "$R" --remove-label "$l" >/dev/null 2>&1 && swept="$swept \`$l\`" ;;
  esac
done
[ -z "$swept" ] || { say "Starting clean: markers of a previous release that never ended were cleared by the driver on \`change:start\`:$swept. Nothing they said is evidence about \`$sha\`."; log "swept:$swept"; }

# --- 1. the lock: deploy:staging, one holder ---------------------------------
holder=$(gh pr list --repo "$R" --state open --label deploy:staging --json number -q "[.[].number]|map(select(.!=$PR))|first // empty")
[ -z "$holder" ] || { log "lock held by #$holder"; exit 5; }
./change/lock.sh acquire "$PR" staging >/dev/null || { log "lock record held"; exit 5; }
# CONSUME THE INTENT FIRST (watch.sh's rule): a trigger that stays on re-fires.
gh pr edit "$PR" --repo "$R" --remove-label change:start --add-label deploy:staging >/dev/null
log "claimed the lock for $sha"

# --- 2. guard 0: on top of main, or refused and reset -------------------------
if ! git merge-base --is-ancestor origin/main "$(git rev-parse "origin/$(gh pr view "$PR" --repo "$R" --json headRefName -q .headRefName)")" 2>/dev/null; then
  ./change/lock.sh release >/dev/null 2>&1 || true
  for l in deploy:staging change:scheduled staging:e2e staging:smoke staging:uat staging:deployed staging:healthy; do
    gh pr edit "$PR" --repo "$R" --remove-label "$l" >/dev/null 2>&1 || true
  done
  say "Refused: \`$sha\` is behind \`main\`. Deploying it would ship a tree missing what landed since. Every marker has been cleared, the intent included. Rebase onto \`main\`, push, and say \`change:start\` again."
  log "behind main; refused and reset"; exit 6
fi

# --- 3. staging: install, health, then the instruments ------------------------
deploy staging "$sha" || fail "deploy staging" "staging did not come up serving $sha"
gh pr edit "$PR" --repo "$R" --add-label staging:deployed >/dev/null
./gates/health.sh --pr "$PR" --env staging "$STG" "$sha" >/dev/null || fail "guard 5 on staging" "staging is not serving $sha"
ROUTER_URL="$STG" ./gates/e2e.sh --pr "$PR" --env staging >/dev/null || fail "e2e" "the authorizing run failed on staging"
./gates/smoke.sh --pr "$PR" --env staging "$STG" >/dev/null || fail "smoke" "the smoke walk failed on staging"
./gates/uat.sh "$STG" >/dev/null || fail "uat" "the as-is Playwright journey was refused on staging (a flow change without its acceptance diff?)"
./change/observe.sh "$PR" uat --on "$STG" >/dev/null || fail "observe" "the acceptance could not be recorded"
log "staging: healthy, e2e, smoke, uat on $sha"

# --- 4. promotion: promote.yml lands deploy:production on staging:smoke -------
i=0
until gh pr view "$PR" --repo "$R" --json labels -q '[.labels[].name]|join(" ")' | grep -q 'deploy:production'; do
  i=$((i+1)); [ $i -le 48 ] || fail "promotion" "deploy:production did not land within 8 minutes (promote.yml)"
  sleep 10
done
log "promoted"

# --- 5. production: install, then guard 5 -------------------------------------
deploy production "$sha" || fail "deploy production" "production did not come up serving $sha"
gh pr edit "$PR" --repo "$R" --add-label production:deployed >/dev/null
HEALTH_SAMPLES=5 ./gates/health.sh --pr "$PR" --env production "$PROD" "$sha" >/dev/null || fail "guard 5 on production" "production did not converge on $sha"
landed=$(date -u +%FT%TZ)
log "LANDED $sha at $landed"

# --- 6. the second identity approves, under its standing delegation ------------
GH_TOKEN="$(gh auth token --user aygp-dr)" gh pr review "$PR" --repo "$R" --approve \
  --body "Approved by the second identity under its standing delegation, not by a person looking: gates green on \`$sha\`, staging and production healthy, driven by change/driver.sh." >/dev/null 2>&1 || true
./change/guard4.sh "$PR" >/dev/null 2>&1 || { sleep 60; ./change/guard4.sh "$PR" >/dev/null || fail "guard 4" "the authorization stack is not complete on $sha"; }

# --- 7. settle: complete, merge, PIR, cleanup, end -------------------------------
FRONT_URL="$PROD" STAGING_URL="$STG" ./change/settle.sh "$PR" >/dev/null || fail "settle" "settlement refused; see the PR"
./change/lock.sh release >/dev/null 2>&1 || true
log "SETTLED #$PR ($sha): landed $landed, merged $(gh pr view "$PR" --repo "$R" --json mergedAt -q .mergedAt)"
