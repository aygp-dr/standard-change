---
name: release-start
description: Say release:start on one pull request, or run the scheduler once for the oldest start. Use when a person asks to release, ship, deploy or start a change, or asks why their start has not been heard. It writes exactly one label and lets the process take over; it never deploys, approves, merges, rebases, or touches another change's markers.
---

# /release-start [PR | next]

The person's word. The process (`change/scheduler.sh` consuming through
`change/driver.sh`) does everything after it. This skill exists to say the
word correctly and to tell the person what will happen, so that a start
said twice or said on the wrong change does not thrash the pipeline.

The label is `release:start` (renamed from `change:start` on 2026-09-16; the rest of the tense-pair grammar waits for rebuild 005).

## Preconditions, checked before writing

- The PR is OPEN and not a draft. driver.sh does not check draft; preflight's
  DraftGuard and unaffected.sh do, so this skill must.
- It carries at least one `app:*`. With none, the word is `release:skip`.
- It does not carry `release:skip`. unaffected.sh refuses the pair; say so.
- It does not already carry the start label. A trigger that stays on re-fires
  (023 F6 started two drivers).
- It does not carry `deploy:staging`: it is already in flight.
- Read `./change/lock.sh status` and `gh pr list --label deploy:staging`
  first and report the holder up front. driver exit 5 goes to stdout only
  (024 F3), so the person would otherwise not hear it.

## The one thing it writes

`gh pr edit <n> --add-label <start-label>` on one PR. For `next`, no label:
`./change/scheduler.sh --once`, which takes the oldest start.

## What it refuses, and says

- "#N is a draft."
- "#N carries release:skip; both cannot be true; withdraw one."
- "#N has no app:* label; nothing to release; say release:skip."
- "#N already said start at T; a second start is not a faster start."
- "The berth is held by #M since T; your start will stay said and be retried
  every 20 s; nothing is asked of you."

## What it never does

Add `deploy:staging` (that asserts a deploy is running); clear another
change's markers (D21); rebase or push the person's branch (driver.sh asks
the forge); approve; book a window.

## How the person knows it was heard

Within two scheduler ticks: either the comment "Heard `release:start`.
Waiting: the berth is held by #M", or the start label gone and
`deploy:staging` on. If neither arrives in 60 s, say "no scheduler is
running on this estate" (024 F4: a dead daemon leaves reassurance behind)
and name the command that starts one:
`nohup ./change/scheduler.sh >> experiments/023-start-only/scheduler.log &`.
