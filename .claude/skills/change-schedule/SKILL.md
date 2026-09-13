---
name: change-schedule
description: Reserve a deployment window on the change schedule, read what is scheduled, and check team environments in and out of the IDP. Use when asked to schedule or book a deployment, request a change window, see what is deploying today or who holds an environment, check out or release a team/app environment, clear a stale checkout, or explain why a deployment is blocked on the queue, a freeze, or an emergency. Covers reservation only — it does not start deployments and does not close them out.
---

# change-schedule — reserve, and read

Read `../_shared/vocabulary.md` first. This skill covers **reservation**, the
first of three verbs (`docs/idp-api.org`). It never starts a deployment.

## The label to add

**`change:requested`** — the only label a person adds to start a change.

It raises the request. It does not book a window, claim a berth, or deploy.
Everything after is the system: `change:scheduled` when a window is booked,
`deploy:staging` while the deployment is running, `staging:passed` and
`production:healthy` when checks come back.

Do not add `deploy:staging` or `deploy:production` by hand. They are **actions
in flight**, not requests — adding one says "the workflow is deploying right
now", which is not something a person can truthfully assert. Do not add
`production:healthy` either: it is a check result, and typing it claims a
measurement nobody took. See `../_shared/vocabulary.md`.

## Reserve a window

```sh
./change/schedule.sh block <pr> "<groups>" <minutes>   # -> .change-event-id
```

Creates `CHANGE: standard-change#<pr> <groups>` with the PR URL, head SHA and
target environment. Call it **after** the queue guards pass — a window recorded
for a change that was refused is noise.

**Reserving is not deploying.** The guards checked here are stale by the time
the window arrives, which is why activation re-checks them and is a separate
skill. If asked to "just deploy it now", that is `change-activate`, and it is
the scheduler's call rather than yours.

Windows quantize to 30 minutes because the change schedule is a calendar. That
caps throughput at 48 slots/day/berth before any gate runs — shortening the
gate suite cannot buy a slot the schedule does not have.

## Read the schedule

```sh
./change/schedule.sh check <window>      # freezes and emergencies overlapping
scripts/../../_shared/idp.py change list --open
```

## Team environments

```sh
../_shared/idp.py list
../_shared/idp.py checkout <env> --pr <n> --hours <h>
../_shared/idp.py release <env>
../_shared/idp.py clear <env> --reason "..."
../_shared/idp.py expired
```

Leases expire; `clear` reclaims with a recorded reason. Same shape as the
60-minute stale-lock rule, for the same reason — a holder that dies must not
hold forever. The blast radius differs: a stale team environment inconveniences
one team, a stale berth wedges every deployment, which is why the berth's
release is automatic rather than lease-based.
