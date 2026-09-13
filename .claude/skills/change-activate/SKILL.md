---
name: change-activate
description: Act as the deployment scheduler when a reserved change window comes due — re-evaluate every guard at that moment and either activate the deployment or forfeit the slot with a reason. Use ONLY when running as the scheduler, for example when a scheduled slot fires, when asked to process due windows, or when asked why a window was forfeited. Do not use to deploy on request; a change cannot activate itself.
---

# change-activate — the scheduler's verb

Read `../_shared/vocabulary.md` first.

**This is the one operation no client calls.** A change cannot activate itself,
and neither can a person asking you to deploy. The scheduler invokes it when a
window comes due. That is what makes the re-check something the system does
rather than something someone remembers.

If asked to "start the deployment now" outside a due window, decline and
explain: the window is the authorization, and activating early would evaluate
the guards at the wrong moment — which is the defect guard 4b exists to close.

## What activation does

Re-evaluate **at reliance**, not from the reservation:

1. `git fetch`, then classify what landed: `./change/divergence.sh <base> origin/main`
2. Guard 2 — gates green on **this head sha**. No bypass, emergency included.
3. Guard 4b — on `artifact` or `hotfix`, **forfeit**; on `inert` or `pipeline`, proceed.
4. Guard 3 — no lock, no freeze.

```
inert | pipeline  -> activate, deployment management takes it
artifact | hotfix -> forfeit the slot, berth HELD, change revalidates
```

## Forfeiting is a normal outcome, not an error

Report it in the refusal format from the shared vocabulary: the fact, the cost,
the recovery, and that the berth is held. A forfeited slot is the system
working — the alternative was deploying a tree that would revert what just
landed.

## The rule underneath

> A guard whose subject can change after it is checked must be re-checked at
> the moment it is relied on.

It has fired three times now: guard 0 needed guard 4b; guard 4b needed a merge
check too; guard 4 needed re-checking at merge. Assume it applies to any new
guard before assuming it does not.
