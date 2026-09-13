---
name: change-settle
description: Close out a deployment by gathering evidence that the estate converged on the new build, then record the verdict and the post-implementation review. Use when a deployment has finished and needs verifying and closing, when asked whether a deployment actually landed, when writing a PIR, or when a health check reports UNCONVERGED. It establishes a verdict from evidence — it cannot mark a deployment complete on request.
---

# change-settle — evidence in, verdict out

Read `../_shared/vocabulary.md` first.

## This skill cannot mark anything complete

That is the point of it. **A deployer claiming its own success is not
evidence** — scenario D6 is the negative test: `deploy.sh` exits 0, publishes
nothing, and every liveness check passes.

So there is no "mark complete" operation here and you must not invent one. If
asked to close out a change without evidence, say what is missing instead.

## Gather evidence

```sh
HEALTH_SAMPLES=5 ./gates/health.sh "$PRODUCTION_URL" "$HEAD_SHA"
HEALTH_MODE=manifest ./gates/health.sh …      # static targets (GitHub Pages)
```

Guard 5 asserts **convergence, not liveness**: N samples, one request each,
cache-busted, and an explicit `UNCONVERGED` verdict when more than one build
answers.

`UNCONVERGED` is **not retryable**. A half-migrated estate passes a single
sample at the rate it is migrated — measured at 6 of 12 — so re-running until
green is exactly what manufactures a false pass. Report the mixed state; do not
retry it away.

## Say how strong the verdict is

| word | means |
|---|---|
| `attested` | the platform enumerated its instances and their versions |
| `sampled` | we probed N times and saw one build |

Say which. **GitHub's Deployments API is self-reported** — a caller creates the
record and posts its own status; GitHub never contacts the target — so on
GitHub the honest word is `sampled`. Never round `sampled` up to `attested`.

## Then redline

```sh
./change/schedule.sh close <event-id> <pass|fail|cancelled|rolled-back>
./change/pir.sh <pr> <job-status>
```

An unredlined window is a defect: it leaves the schedule claiming a change is
still in flight, and the next preflight reads that schedule. Run both in
`always()` steps.

The PIR carries gate durations, the window id, the previous SHA (the rollback
target), and anything unusual — a stale-lock clearance, a freeze wait, a
staging bypass and who approved it.

## What settlement still cannot know

N samples cannot see a replica taking no traffic during the window. **A
sampling check can only fail to refute convergence, never establish it.** Say
so when it matters; do not present `sampled` as proof.
