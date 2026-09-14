#!/usr/bin/env python3
"""Grind 100 PRs under two release policies, and under degraded infrastructure.

WHY THIS EXISTS. The question asked was: "if I ask release:start it should
generally just deploy, as long as nobody else is mid-deployment" -- with the
calendar demoted to a WARNING and the berth kept as a hard block. That is a
different pipeline from the one spec.org describes, so it is worth running
rather than arguing about.

The second question was: which changes can still reach production when parts
of the infrastructure are gone? That is not a policy choice. It falls out of
which guard reads which component, and the answer is a matrix, not a rule.

Imports the existing model; does not modify it. No network, no estate.

    python3 sim/grind100.py
"""
from __future__ import annotations

import random
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from pipeline_sim import (Change, Deploys, Divergence, Kind,  # noqa: E402
                          SLOTS_PER_DAY, State, World)

N_PRS = 100
SEED = 20260914


# ---------------------------------------------------------------------------
# Infrastructure. Each component is named by the guard that reads it, because
# "can we still ship" is answered by that mapping and by nothing else.
# ---------------------------------------------------------------------------
@dataclass
class Infra:
    forge: bool = True        # guards 0, 2, 4 (review + check runs)
    calendar: bool = True     # guard 3 (the window)
    staging: bool = True      # producing NEW staging observations
    production: bool = True   # guards 5 and 6 -- observing the served build
    name: str = "all up"

    def down(self) -> list[str]:
        return [k for k in ("forge", "calendar", "staging", "production")
                if not getattr(self, k)]


@dataclass
class Policy:
    """window_advisory demotes guard 3 from a refusal to a warning."""
    window_advisory: bool = False
    name: str = "spec (window blocks)"


@dataclass
class Outcome:
    shipped: int = 0
    blocked_berth: int = 0
    warned_no_window: int = 0
    refused: int = 0
    abstained: int = 0
    reasons: dict = field(default_factory=dict)

    def note(self, why: str) -> None:
        self.reasons[why] = self.reasons.get(why, 0) + 1


def make_changes(n: int, rng: random.Random) -> list[Change]:
    """A realistic mix, calibrated against the 2026-09-13/14 night.

    22 of ~30 driven changes merged; most were tiny copy/CSS edits carrying
    one app label, a few were control-plane. Emergencies were rare (one).
    """
    out = []
    for _ in range(n):
        r = rng.random()
        kind = (Kind.EMERGENCY if r < 0.02 else
                Kind.NORMAL if r < 0.15 else Kind.STANDARD)
        t = rng.choices(list(Divergence)[:3], weights=[0.55, 0.15, 0.30])[0]
        d = rng.choices([Deploys.SOME, Deploys.PROVABLY_NONE, Deploys.INDETERMINATE],
                        weights=[0.85, 0.12, 0.03])[0]
        out.append(Change(kind, t, deploys=d))
    return out


def can_reach_production(c: Change, infra: Infra, pol: Policy, o: Outcome) -> bool:
    """The guard-by-guard question, with infra mapped onto it.

    Every branch here is a guard reading a component. Nothing is a policy
    judgement except the one marked as such.
    """
    # Guard 2 -- gates green on the head SHA. NO BYPASS, not even emergency.
    # Read from the forge. If the forge cannot answer, the verdict is
    # INDETERMINATE, which is not "green" -- class 1 and class 8.
    if not infra.forge:
        o.abstained += 1
        o.note("guard 2/4 abstain: forge unreachable, verdicts unreadable")
        return False

    # Guard 3 -- the window. THIS is the policy question, and the only one.
    if not infra.calendar:
        if pol.window_advisory:
            o.warned_no_window += 1
            o.note("WARN: calendar unreachable, proceeding (advisory policy)")
        else:
            o.abstained += 1
            o.note("guard 3 abstain: calendar unreachable (exit 4 blocks)")
            return False
    elif pol.window_advisory:
        # Even with a calendar, the advisory policy does not require a booking.
        o.warned_no_window += 1
        o.note("WARN: no window booked, proceeding (advisory policy)")

    # Guard 4 -- authorization is a RECORD naming this build, not the live
    # staging environment. So staging being GONE does not block a change whose
    # observations were already recorded: the record stays true about the SHA
    # it names. What is lost is the ability to produce NEW observations.
    if not infra.staging:
        if c.staged_at == c.head:
            o.note("staging down, but prior observations name this build -- guard 4 satisfied")
        else:
            o.abstained += 1
            o.note("guard 4 abstain: staging down and no record names this build")
            return False

    # Guards 5 and 6 -- production convergence and production-first. These read
    # the SERVED build. There is no bypass and no record that can stand in,
    # because the subject does not exist until the deploy happens. An
    # unobservable production blocks EVERYTHING, emergency included.
    if not infra.production:
        o.abstained += 1
        o.note("guard 5/6 abstain: production unobservable -- no bypass exists")
        return False

    # Guard 6's three-valued deploys(c).
    if c.deploys is Deploys.INDETERMINATE:
        o.abstained += 1
        o.note("guard 6 abstain: deploy set indeterminate (not exempt)")
        return False
    return True


def grind(pol: Policy, infra: Infra, rng: random.Random) -> Outcome:
    """100 PRs, one berth. release:start is the intent; the berth is the queue."""
    w = World(berths=1)
    o = Outcome()
    changes = make_changes(N_PRS, rng)
    for c in changes:
        w.submit(c)
        w.run_gates(c)
        c.staged_at = c.head if rng.random() < 0.9 else None

    # A DEPLOYMENT TAKES TIME, or the berth never contends and the block the
    # request is actually about is never exercised. The first version of this
    # completed each change inside its own iteration and reported
    # blocked-berth 0 for every run -- a queue with no queueing in it.
    #
    # Duration is in slots and comes from the real cycle: deploy+settle ~2m,
    # soak 1m, walk ~1m against 10-minute slots on the night of 09-13/14, so
    # one slot for a normal change and more for a control-plane one.
    inflight: Change | None = None
    until = 0
    arrivals = list(changes)
    clock = 0
    pending: list[Change] = []
    while arrivals or pending or inflight is not None:
        # arrivals: changes ask for release:start as they show up
        if arrivals and rng.random() < 0.6:
            pending.append(arrivals.pop(0))
        # the berth frees
        if inflight is not None and clock >= until:
            inflight.state = State.COMPLETED
            o.shipped += 1
            inflight = None
        # somebody wants to go
        if inflight is None and pending:
            c = pending.pop(0)
            if not can_reach_production(c, infra, pol, o):
                o.refused += 1
            else:
                c.state = State.IMPLEMENTING
                if c.deploys is Deploys.SOME:
                    w.in_prod = w.trunk
                inflight = c
                dur = 3 if c.touches is Divergence.PIPELINE else 1
                until = clock + dur
        elif inflight is not None:
            # GUARD 1 -- the berth BLOCKS, and the refusal NAMES THE HOLDER.
            # "as long as nobody else is in the middle of a deployment" is the
            # whole rule; a change that is blocked is told who to coordinate
            # with, which a bare `blocked:queue` label never said.
            for c in pending:
                o.blocked_berth += 1
                o.note(f"blocked by berth: coordinate with the holder ({inflight.chg})")
            pending = pending[:0] + pending  # they wait, they are not dropped
        clock += 1
        if clock > 20000:
            o.note("ABORT: clock ran away")
            break
    return o


def report(pol: Policy, infra: Infra, o: Outcome) -> None:
    print(f"\n  policy={pol.name:<28} infra={infra.name}")
    print(f"    shipped {o.shipped:3d}   blocked-berth {o.blocked_berth:3d}   "
          f"abstained {o.abstained:3d}   warned {o.warned_no_window:3d}")
    for why, n in sorted(o.reasons.items(), key=lambda kv: -kv[1])[:4]:
        print(f"      {n:3d}  {why}")


def main() -> None:
    policies = [Policy(False, "spec (window blocks)"),
                Policy(True, "release:start (advisory)")]
    infras = [
        Infra(name="all up"),
        Infra(calendar=False, name="calendar DOWN"),
        Infra(staging=False, name="staging DOWN"),
        Infra(production=False, name="production UNOBSERVABLE"),
        Infra(forge=False, name="forge DOWN"),
    ]
    print(f"=== {N_PRS} PRs, one berth, seed {SEED}")
    for pol in policies:
        for infra in infras:
            report(pol, infra, grind(pol, infra, random.Random(SEED)))

    print("\n=== THE MATRIX: can a change still reach production?")
    print("    component down      spec policy      release:start policy")
    for infra in infras[1:]:
        a = grind(policies[0], infra, random.Random(SEED)).shipped
        b = grind(policies[1], infra, random.Random(SEED)).shipped
        print(f"    {infra.name:<20} {a:3d}/{N_PRS}          {b:3d}/{N_PRS}")


if __name__ == "__main__":
    main()
