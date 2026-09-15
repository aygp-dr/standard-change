---
name: release-end
description: End a release that is in flight, with a reason, closing the change with a code that names a fact. Use when asked to stop, abort, cancel, abandon or back out a release, or to clear a stuck change's markers. It writes the closure and clears every marker; it never merges, deploys, rolls back, or re-adds the person's start.
---

# /release-end [PR] "<reason>" [--backed-out --to <sha>]

The person's word to stop. Calls
`./change/abort.sh <pr> "<reason>" [--backed-out --to <sha>]`, then
`./change/schedule.sh unschedule <pr> "<reason>"` for any future window,
because abort closes only the current one and a future reservation would
survive.

## Preconditions, checked before calling

- The PR is OPEN and not MERGED. A merged change is settle's, not abort's.
- It is in flight: it carries at least one of the start label,
  `change:scheduled`, `deploy:staging`, `deploy:production`. abort on a bare
  PR clears nothing and writes a false closure.
- A reason is given. abort.sh requires one; a closure with no cause is not a
  record.
- `./change/lock.sh status` names this PR or is free. abort.sh calls
  `lock.sh release`, and a hand run with no run id releases anyone's lock.
- Read production's `x-build-sha` first. If it equals this head, refuse the
  plain form: ending it now leaves production stranded.

## The one thing it writes

The closure record comment, then everything abort.sh does in order:
deployment records to failure, the current window closed with the code,
every marker cleared, the closure code, the lock released, `change:end`.

## What it refuses, and says

- "no reason given; a closure with no cause is not a record."
- "production is serving <sha>, this change's head; roll back with
  targets/node/switch.sh, then end with --backed-out --to <sha>."
- "--backed-out asserts an estate action; name the sha."
- "#N carries no marker; there is no release to end."
- "the lock is #M's; ending #N would release it."
- "abandoned and superseded are declared closure codes and abort.sh has no
  flag for them; refused until the script has them." Never write those labels
  by hand.

## What it never does

Merge; deploy; roll production back (recording a rollback is not performing
one); clear `app:*` or `itil:*`; rebook; re-add the start label. Ending does
not requeue: the intent is spent, and saying it again is a second word from
the person (024 F7: a machine fault should not spend the person's word).

## How the person knows

The "Change closed: code" comment with build, reason and labels at closure;
the PR left with `app:*`, the class, the closure code and `change:end`;
`./change/schedule.sh list` showing the window closed with the same code;
`./change/lock.sh status` free.
