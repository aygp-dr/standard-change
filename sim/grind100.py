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

# --- reliability, as asked ---------------------------------------------------
# 80% of deployments succeed and pass smoke. The other 20% fail AT STAGING,
# before production: the gate is the thing that catches them, which is what the
# gate is for. They forfeit the slot and go back to assessing.
P_DEPLOY_OK = 0.80
# Production is OBSERVABLE, and 1% of cutovers are observed unhealthy. This is
# guard 5 firing after the deploy -- convergence, not liveness. It is a
# different failure from the 20%: that one never reached production.
P_PROD_FAIL = 0.01


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
    """window_advisory demotes guard 3 from a refusal to a warning.

    remediation is the choice made when guard 5 observes production unhealthy.
    We pick ONE and live with it, because the two have different costs and the
    point is to see which:

      rollback     -- switch the front back to the idle colour. Assumed always
                      to work (it is a front switch, not a deploy). The change
                      closes `backed_out`, which is NOT `failed`: it ran, it
                      was observed, and it was withdrawn.
      rollforward  -- ship a hotfix. It must pass guard 2 and guard 5 like
                      anything else, so it can fail too. And it merges as
                      Divergence.HOTFIX, which is in WITHDRAWS -- so it
                      invalidates the staging pass of every other change in
                      flight. That collateral is the number worth measuring.
    """
    window_advisory: bool = False
    remediation: str = "rollback"       # rollback | rollforward
    name: str = "spec (window blocks)"


@dataclass
class Outcome:
    shipped: int = 0
    blocked_berth: int = 0
    warned_no_window: int = 0
    refused: int = 0
    abstained: int = 0
    staging_failed: int = 0      # the 20%: caught by the gate, never reached prod
    prod_incidents: int = 0      # the 1%: guard 5 observed unhealthy
    rolled_back: int = 0
    hotfixes: int = 0
    hotfix_failed: int = 0
    withdrawn_by_hotfix: int = 0 # collateral: other changes invalidated
    restore_slots: int = 0       # total slots production spent unhealthy
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
    """100 PRs, one berth, with deployments that fail and a production that can
    be observed unhealthy.

    Two failure kinds, kept apart because they are different events:
      - 20% fail AT STAGING. The gate caught them; production never saw them.
        The slot is forfeited and the change goes back to assessing. This is
        the pipeline working.
      - 1% of cutovers are observed unhealthy by guard 5 AFTER production has
        the build. This is an incident, and it is remediated.
    """
    w = World(berths=1)
    o = Outcome()
    changes = make_changes(N_PRS, rng)
    for c in changes:
        w.submit(c)
        w.run_gates(c)
        c.staged_at = c.head if rng.random() < 0.9 else None

    inflight: Change | None = None
    until = 0
    arrivals = list(changes)
    clock = 0
    pending: list[Change] = []
    unhealthy_since: int | None = None

    while arrivals or pending or inflight is not None:
        if arrivals and rng.random() < 0.6:
            pending.append(arrivals.pop(0))

        if inflight is not None and clock >= until:
            c = inflight
            # --- the 20%: staging caught it. Never reached production. -------
            if rng.random() >= P_DEPLOY_OK:
                o.staging_failed += 1
                o.note("staging gate refused the deploy (the 20%) -- slot forfeited")
                c.state = State.ASSESSING
                c.staged_at = None
                inflight = None
                clock += 1
                continue
            # --- the cutover happened. Guard 5 now observes production. ------
            if rng.random() < P_PROD_FAIL:
                o.prod_incidents += 1
                unhealthy_since = clock
                if pol.remediation == "rollback":
                    # A front switch, assumed always to work. The change closes
                    # backed_out -- it ran, it was observed, it was withdrawn.
                    # NOT `failed`: nothing about the change was untested.
                    o.rolled_back += 1
                    o.restore_slots += 1
                    o.note("guard 5 unhealthy -> ROLLBACK (front switch, 1 slot)")
                    c.state = State.FAILED
                    unhealthy_since = None
                else:
                    # Roll forward: a hotfix must itself pass guard 2 and guard
                    # 5. It can fail, and while it is being built production
                    # stays unhealthy.
                    o.hotfixes += 1
                    hf = Change(Kind.EMERGENCY, Divergence.HOTFIX, deploys=Deploys.SOME)
                    w.submit(hf); w.run_gates(hf); hf.staged_at = hf.head
                    cost = 2                      # build + deploy the hotfix
                    if rng.random() >= P_DEPLOY_OK:
                        o.hotfix_failed += 1
                        cost += 2                 # the hotfix failed; try again
                        o.note("ROLL FORWARD: the hotfix itself failed its gate")
                    o.restore_slots += cost
                    # THE COLLATERAL, and it is the point of measuring this.
                    # A hotfix merges as Divergence.HOTFIX, which is in
                    # WITHDRAWS -- so every other change waiting with a staging
                    # pass has that pass invalidated and must re-run.
                    for other in pending:
                        if other.staged_at is not None:
                            other.staged_at = None
                            o.withdrawn_by_hotfix += 1
                    o.note(f"guard 5 unhealthy -> ROLL FORWARD (hotfix, {cost} slots)")
                    c.state = State.FAILED
                    unhealthy_since = None
                inflight = None
                clock += 1
                continue
            # --- healthy. It shipped. ----------------------------------------
            c.state = State.COMPLETED
            o.shipped += 1
            inflight = None

        if inflight is None and pending:
            c = pending.pop(0)
            if not can_reach_production(c, infra, pol, o):
                o.refused += 1
            else:
                c.state = State.IMPLEMENTING
                if c.deploys is Deploys.SOME:
                    w.in_prod = w.trunk
                inflight = c
                until = clock + (3 if c.touches is Divergence.PIPELINE else 1)
        elif inflight is not None:
            for _ in pending:
                o.blocked_berth += 1
            if pending:
                o.note(f"blocked by berth: coordinate with the holder ({inflight.chg})")
        clock += 1
        if clock > 20000:
            o.note("ABORT: clock ran away")
            break
    return o


def report(pol: Policy, infra: Infra, o: Outcome) -> None:
    print(f"\n  {pol.name} / remediation={pol.remediation} / infra={infra.name}")
    print(f"    shipped {o.shipped:3d}  staging-caught {o.staging_failed:3d}  "
          f"prod-incidents {o.prod_incidents:2d}  berth-blocks {o.blocked_berth:3d}")
    if o.prod_incidents:
        print(f"    rolled-back {o.rolled_back:2d}  hotfixes {o.hotfixes:2d} "
              f"(failed {o.hotfix_failed})  slots-unhealthy {o.restore_slots:3d}  "
              f"passes-withdrawn {o.withdrawn_by_hotfix:3d}")


def main() -> None:
    up = Infra(name="all up")
    print(f"=== {N_PRS} PRs, one berth, seed {SEED}")
    print(f"    deploy succeeds {P_DEPLOY_OK:.0%}, production observed unhealthy "
          f"{P_PROD_FAIL:.0%} of cutovers")

    print("\n--- policy x remediation, production observable")
    combos = [Policy(False, "rollback",    "spec (window blocks)"),
              Policy(False, "rollforward", "spec (window blocks)"),
              Policy(True,  "rollback",    "release:start (advisory)"),
              Policy(True,  "rollforward", "release:start (advisory)")]
    for pol in combos:
        report(pol, up, grind(pol, up, random.Random(SEED)))

    print("\n=== REMEDIATION, over 40 seeds (the 1% needs repeats to be visible)")
    for rem in ("rollback", "rollforward"):
        pol = Policy(True, rem, "release:start (advisory)")
        inc = sl = hf = hff = wd = shp = 0
        for k in range(40):
            o = grind(pol, up, random.Random(SEED + k))
            inc += o.prod_incidents; sl += o.restore_slots; hf += o.hotfixes
            hff += o.hotfix_failed; wd += o.withdrawn_by_hotfix; shp += o.shipped
        print(f"  {rem:<12} incidents {inc:3d}  slots-unhealthy {sl:4d}  "
              f"mean-restore {sl/max(inc,1):.2f} slots  hotfixes {hf:3d} "
              f"(failed {hff})  passes-withdrawn {wd:4d}  shipped {shp}")

    print("\n=== degraded infrastructure (unchanged rules)")
    infras = [Infra(calendar=False, name="calendar DOWN"),
              Infra(staging=False, name="staging DOWN"),
              Infra(production=False, name="production UNOBSERVABLE"),
              Infra(forge=False, name="forge DOWN")]
    print("    component down            spec policy   release:start")
    for infra in infras:
        a = grind(Policy(False, "rollback", "spec"), infra, random.Random(SEED)).shipped
        b = grind(Policy(True, "rollback", "adv"), infra, random.Random(SEED)).shipped
        print(f"    {infra.name:<24} {a:3d}/{N_PRS}        {b:3d}/{N_PRS}")


if __name__ == "__main__":
    main()
