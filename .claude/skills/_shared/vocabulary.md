# Shared vocabulary for the change-* skills

Read by `change-schedule`, `change-activate`, `change-settle`. Kept in one
place so three skills cannot drift into three dialects.

## The two resources, governed oppositely

| resource | what it is | claimed via | skill may grant it? |
|---|---|---|---|
| `env/<team>-<app>` | team environment. Many, disposable, leased. **Cannot promote.** | `idp.py checkout` | yes |
| `staging` | the **berth** — the single path to production | the `deploy:staging` label, so `queue.sh` runs guards 0 and 1 | **never** |

**Never check out `staging`.** It is a queue position, not a lease. Granting it
as a lease bypasses guard 0 (up to date with main) and guard 1 (singleton).
`idp.py` refuses it; do not work around that.

## The guards

| # | asks | bypass |
|---|---|---|
| 0 | is the base up to date with main? | emergency only |
| 1 | is the berth free? | n/a — emergency skips staging |
| 2 | are all gates green on **this head sha**? | **none, ever** |
| 4 | is there a staging pass, or an approved emergency? | — |
| 4b | did main move under it, and did that change what ships? | emergency only |
| 5 | has the estate **converged** on the new build? | **none, ever** |

Guards 2 and 5 have no bypass at all. If asked to work around either, decline
and name which one.

## Three kinds of label

| kind | examples | who adds it | safe to add by hand? |
|---|---|---|---|
| derived | `app:*`, `change:standard` | the labeller, from the diff | no — resynced on every push |
| **request** | **`change:scheduled`**, `change:emergency`, `labeler:skip` | a human | **yes — this is the point** |
| observation | `deploy:staging`, `staging:passed`, `production:healthy` | a gate or the scheduler | **no** — it asserts a measurement |

`change:scheduled` is the one a person adds to start a change. `deploy:staging`
means *the berth is held* and is emitted at activation.

Hand-adding an observation label asserts something nobody measured. A workflow
triggered by one must **re-derive the fact** rather than trust it — which is
why `health.sh` is cheap and idempotent.

## Refusals name three things

Never report a refusal as a status code. Always: **the fact, the cost, the
recovery** — and whether the berth is held.

> `[hotfix] an emergency landed under you.` CHG-20260913-0007 shipped
> `apps/checkout/src/session.js`. Deploying your current build would REVERT it.
> This is not a staleness warning. Berth held until 14:35Z; the pass is
> withdrawn until staging re-runs on a tree containing the fix.

`berth: held` vs `berth: released` is not optional. **Preemption is not
staleness**: a change that went stale on its own loses its position; one
invalidated by someone else's emergency keeps it and gets an extension.

## Two meanings of "emergency"

- `EMERGENCY:` **calendar event** — blocks the whole estate. Everyone waits.
- `change:emergency` **label** — exempts one change from staging.

Same word, opposite direction. Find out which is meant before acting.
