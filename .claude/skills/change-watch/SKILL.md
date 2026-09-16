---
name: change-watch
description: Report the estate's health — which of the five invariants are failing, what the dashboard says, who holds the berth, and whether the calendar has stale windows. Use when asked how the estate is, whether anything is wrong, what is blocking deployments, why a change is stuck, or to check before or after a deployment round. Do NOT use to fix what it finds: this skill observes and never writes a label, clears a lock, or reaps a window.
---

# change-watch — the verb that only looks

Read `../_shared/vocabulary.md` first.

**This skill writes nothing.** Not a label, not a lock, not a window. That is
the whole discipline: the estate has three writers already (a human, the
workflows, and whichever driver is running), and `scenarios.org` D21 is what
happened when a fourth cleared a lock it did not hold while its own log said
"releasing the estate". A watcher that repairs is a fourth writer.

If asked to fix something this skill surfaces, say what you found, name the
verb that owns the fix, and let the caller decide. The owning verbs are in
`change/label-owners.tsv`.

## The five invariants

`gates/pr-state-audit.py` holds them and their self-test. Do not reimplement
them here — two copies of one rule is the defect this repo keeps finding.

| | invariant | why it exists |
|---|---|---|
| I1 | at most one open PR carries `deploy:staging` | the berth. Guard 1 has admitted two holders (D22) |
| I2 | at most one open PR carries `deploy:production` | the path to production is a singleton |
| I3 | no open PR carries a terminal label | `release:ended`/`complete`/`failed`/`backed-out` claim a state an open change is not in |
| I4 | no PR is finished **and** moving | #52 carried `release:ended` through an entire successful deploy |
| I5 | the six declared exclusive groups hold | declared in `label-owners.tsv`; nothing read them until this gate |

## How to look

```sh
gmake -s pr-audit                 # the five, against the live forge
python3 gates/pr-state-audit.py --json   # same, for a machine
curl -s http://192.168.86.29:9999/api/status   # the dashboard's own view
./change/lock.sh status           # who holds the berth, and since when
./change/schedule.sh list --open  # windows still open
./targets/node/switch.sh status   # ask the FRONT which colour is live
```

`gmake pr-audit` **exits 1 when it finds something**. That is its verdict, not
a failure to produce one — do not report a non-zero exit as "the audit broke".
The dashboard made exactly that mistake and rendered findings as "the audit did
not run".

## Reporting rules

**Clean and unread are different answers.** If the audit could not run, the
forge could not be reached, or the dashboard is dark, say *indeterminate* and
say which. Never report an estate you could not observe as healthy — that is
`spec.org` defect class 1, and it is the class this pipeline has produced most
often.

**Name the change, not just the count.** "2 findings" is useless to someone who
has to act. "#55 and #70 carry `release:ended` while open" is actionable.

**Distinguish a violation from a symptom.** A stale `release:scheduled` after a
window was reaped is bookkeeping. Two PRs holding `deploy:staging` means a
deployment is happening that nobody is coordinating.

**Say what is normal.** `production-first` red on a change that has not
deployed is its designed state, not a finding. So is `UNSTABLE` mergeability.
Reporting those as problems trains the reader to ignore you.

## What to check, in order

1. **Estate flags** — `freeze` or `emergency` on issue #1 stops everything,
   including whoever declared it. Check first; nothing else matters if set.
2. **The berth** — `lock.sh status` and `deploy:staging` holders. These are two
   different records of one fact and they disagree under contention; report
   both when they differ rather than picking one.
3. **The invariants** — `gmake -s pr-audit`.
4. **The calendar** — windows whose end is past and whose result is still
   unset. Nothing calls `change/reap.sh` on a timer, so stale windows accumulate
   and push `schedule.sh block` days into the future.
5. **The front** — ask `switch.sh status`, which queries the running front. Do
   not read a state file; that is what reported blue while green was serving.

## When there is nothing wrong

Say so in one line and stop. A long green report is furniture, and an operator
who has to read five paragraphs to learn nothing happened will stop reading the
one that matters.
