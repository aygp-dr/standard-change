---
name: change-schedule
description: Schedule, track and redline deployments for standard-change, and check environments in and out of the internal developer platform. Use when scheduling a standard deployment or change window, closing one out (redlining) after it completes, checking out or releasing a team/app environment, seeing who holds an environment, or clearing a stale checkout. Also use when asked why a deployment is blocked on the queue, a freeze, or an emergency.
---

# change-schedule

Two resources, deliberately governed differently. Confusing them is the failure
this skill exists to prevent.

| Resource | What | Claimed via | This skill |
|---|---|---|---|
| `env/<team>-<app>` | Team/app environment. Many, disposable, leased. **Cannot promote.** | `idp.py checkout` | yes — full lifecycle |
| `staging` | The **single path to production**. Queued, one PR at a time. | the `deploy:staging` **label** on a PR | **read-only** — report, never grant |
| `production` | — | `deploy:production`, set by automation | read-only |

**Never check out `staging` through the IDP.** It is not a lease, it is a
position in a queue, and it is claimed by adding `deploy:staging` to a pull
request so that `change/queue.sh` evaluates guard 0 (up to date with `main`) and
guard 1 (singleton). Granting it as a lease would bypass both. If asked to
"check out staging", explain this and add the label to the PR instead.

## 1. Schedule a standard deployment

A change window is a **record**, not a permission. Writing it never blocks.

```sh
./change/schedule.sh block <pr> "<groups>" <minutes>   # -> .change-event-id
```

Creates `CHANGE: standard-change#<pr> <groups>` on the change calendar with the
PR URL, head SHA, and target environment in the description. Call it after the
queue guards pass and before deploying — a window recorded for a change that
was refused is noise.

For a scheduled (not immediate) deployment, add `--at <ISO8601>`; the skill
records the intent, but **nothing auto-deploys at that time**. A human or a
ChatOps `/deploy` still adds the label, and every guard still runs at that
moment. A schedule that deploys unattended would evaluate guard 0 against a
`main` that has moved since — precisely the failure `spec.org` §Guard 4b exists
to close.

## 2. Redline on completion

```sh
./change/schedule.sh close <event-id> <pass|fail|cancelled|rolled-back>
./change/pir.sh <pr> <job-status>         # post-implementation review comment
```

Redlining is closing the loop on the record: the window gets its outcome, and
the PIR carries gate durations, the staging slot, the production deployment id,
the previous SHA (the rollback target), and anything unusual — a stale-lock
clearance, a freeze wait, a staging bypass and who approved it.

Run both in `always()` steps. **An unredlined window is a defect**, not an
untidiness: it leaves the schedule claiming a change is still in flight, and
the next preflight reads that schedule.

If telemetry is wired up, the same call emits the deployment marker. Until it
is, the PIR comment is the record of what happened.

## 3. Environment checkout

```sh
scripts/idp.py list                          # who holds what, and for how long
scripts/idp.py checkout <env> --pr <n> --hours <h>
scripts/idp.py release <env>
scripts/idp.py clear <env> --reason "..."    # force; always leaves an audit line
scripts/idp.py expired                       # leases past their deadline
```

Backed by `environments.tsv`, which is a source of truth (a CMDB), not a
generated file — do not tangle over it.

**Leases expire.** A checkout carries a deadline; `expired` lists the ones past
it and `clear` reclaims them with a recorded reason. This is the same shape as
the 60-minute stale-lock rule in `gates/preflight.sh`, for the same reason: a
holder that dies must not hold a resource forever. The difference is blast
radius — a stale team environment inconveniences one team, a stale staging
claim wedges every deployment, which is why staging's release is automatic on
merge and failure rather than lease-based.

## Reporting a block

When a deployment will not proceed, name which guard refused and what clears it:

| Symptom | Guard | What clears it |
|---|---|---|
| `blocked:queue` | 1 — staging held by another PR | that PR merges or fails out; then **rebase** |
| `deploy:staging` removed, "behind main" | 0 — not up to date | rebase onto `main`, re-add the label |
| `staging:passed` vanished with no push | 4b — `main` moved underneath it | rebase, re-run staging |
| `blocked:freeze` | 3 — `FREEZE:`/`EMERGENCY:` event | the window passes, or `change:emergency` on the PR |
| `blocked:lock` | 3 — another deployment holds the lock | it releases, or the 60-minute stale rule |
| promote refused, gates green | 2 — `gate-selftest` did not run | re-run gates; a suite with no self-test has no verdict |

Guards 2 and 5 have **no bypass at all**, emergencies included. If asked to
work around either, decline and say which one — an emergency may skip the
staging *environment*, never the unit gates or the production health check.

## Two meanings of "emergency"

- `EMERGENCY:` **calendar event** — blocks the whole estate. Everyone waits.
- `change:emergency` **label** — exempts one PR from staging and from guard 0.

Same word, opposite direction. When someone says "there's an emergency", find
out which one they mean before acting.
