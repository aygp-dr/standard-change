#!/usr/bin/env python3
"""Release-train mode for the change pipeline — research, not spec.

Companion to =pipeline_sim.py=, which models the repo's actual semantics: one
change per berth, every guard re-evaluated at reliance, and guard 4b
withdrawing a staging pass whenever an =artifact= or =hotfix= merge lands under
a scheduled change. That model produces the ADR-0001 result: twenty changes all
touching the same deployable surface complete 1 of 20, at one berth and at
eight, because every merge invalidates every other scheduled change.

This file asks one question and tries to answer it with numbers:

    If the batch is validated ONCE instead of each member separately, what
    happens to that 1/20 — and what does the batch cost when it is red?

Nothing here is a proposal. =pipeline_sim.py= is untouched and remains the
model of record; the baseline below is driven THROUGH it so the comparison is
anchored to the engine Hypothesis already beat on.

Vocabulary is the spec's. A *validation cycle* (V slots) is one full
revalidation of a tree: the thing guard 4b makes you redo. A *hold* (H slots)
is the deployment itself. Both modes pay the same V and H; only the number of
things a single V covers differs.
"""
from __future__ import annotations

import math
import random
import statistics
import sys
from dataclasses import dataclass, field

from pipeline_sim import (SLOTS_PER_DAY, SLOT_MINUTES, Change, Divergence,
                          Kind, State, World)

V_DEFAULT = 1          # slots per validation cycle (30 min)
H_DEFAULT = 1          # slots per deployment hold


# --------------------------------------------------------------------------
# Baseline: the repo's own model, driven to steady state.
# --------------------------------------------------------------------------
# ADR-0001's table runs each change exactly once: forfeit and you are done, so
# "1/20 completed" is partly an artefact of the harness. The honest baseline
# lets a forfeited change do what a human would -- rebase, re-gate, re-book --
# and then asks what the STEADY-STATE rate is. The answer is the interesting
# one: it is still one change per revalidation cycle, and still independent of
# berths. Re-queueing turns 1/20 into 20/20 eventually; it does not make the
# pipeline faster than one-at-a-time.

def run_per_change(n=20, berths=1, horizon=SLOTS_PER_DAY, V=V_DEFAULT,
                   H=H_DEFAULT, p_bad=0.0, seed=0, requeue=True,
                   touches=Divergence.ARTIFACT):
    """Drive pipeline_sim.World. Returns a metrics dict.

    requeue=False reproduces ADR-0001's table exactly (one shot per change).
    requeue=True is the steady-state question.
    """
    w = World(berths=berths, hold_slots=H)
    rng = random.Random(seed)
    bad = {}
    for _ in range(n):
        c = w.submit(Change(kind=Kind.STANDARD, touches=touches))
        c.submitted_at = 0                      # type: ignore[attr-defined]
        bad[c.chg] = rng.random() < p_bad
        w.run_gates(c)
        w.reserve(c, slot=1 + V)                # a first validation is not free
    validations = n
    ejected = 0
    for _ in range(horizon):
        w.tick()
        for c in w.changes:
            if c.state is State.COMPLETED:
                continue
            if c.state is State.IMPLEMENTING:
                # a bad change is caught by its own validation, not by a peer's
                continue
            if c.state is State.ASSESSING and requeue:
                if bad[c.chg]:
                    bad[c.chg] = False          # author fixes it once found
                    ejected += 1
                c.window = None                 # stale slot ref after a refusal
                c.base = w.trunk                # rebase onto the tip
                c.head += 1
                c.gated_at = c.staged_at = None
                w.run_gates(c)                  # costs one validation cycle
                validations += 1
                w.reserve(c, slot=w.clock + V + 1)
    done = [c for c in w.changes if c.state is State.COMPLETED]
    lat = [c.completed for c in done]
    return dict(mode="per-change", n=n, berths=berths, completed=len(done),
                forfeits=w.forfeited, validations=validations, ejected=ejected,
                mean_latency=statistics.mean(lat) if lat else float("nan"),
                horizon=horizon, trunk=w.trunk)


# --------------------------------------------------------------------------
# Train mode.
# --------------------------------------------------------------------------
@dataclass
class Car:
    """A change riding a train. Same entity as spec.org's =change=."""
    chg: str
    touches: Divergence
    bad: bool = False
    submitted: int = 0
    completed: int | None = None
    rides: int = 0                       # how many trains it was put on


@dataclass
class Train:
    departs: int
    cars: list[Car] = field(default_factory=list)
    validations: int = 0


class TrainWorld:
    """Work marked ready collects on a branch; the branch departs on a cadence.

    The branch is validated ONCE for the whole batch, then merges to trunk as a
    single merge event. That is the entire mechanical difference from
    pipeline_sim: N changes, one guard-4b subject.

    Red-train recovery is the cost side. Attribution is not free once N > 1:
    isolating one bad car in a batch of N costs ceil(log2 N) validation runs
    (this is exactly what the "one logical step per commit" rule is buying --
    it makes each bisect step cheap and each step's verdict meaningful), plus
    one more run to revalidate the remainder. Multiple bad cars pay it again.
    """

    def __init__(self, cadence=8, V=V_DEFAULT, H=H_DEFAULT, cap=None,
                 recovery="bisect", seed=0):
        assert recovery in ("bisect", "dissolve")
        self.clock = 0
        self.trunk = 0
        self.cadence = cadence
        self.V, self.H, self.cap = V, H, cap
        self.recovery = recovery
        self.rng = random.Random(seed)
        self.platform: list[Car] = []          # ready, waiting for a train
        self.in_flight: Train | None = None
        self.phase_until = 0
        self.phase = "idle"
        self.done: list[Car] = []
        self.validations = 0
        self.log: list[str] = []
        self.emergencies: list[int] = []       # slots at which glass broke
        self.rebuilds = 0                      # trains revalidated for a hotfix
        self._blocked_until = 0                # path busy recovering a red train

    # -- boarding ----------------------------------------------------------
    def submit(self, car: Car):
        car.submitted = self.clock
        self.platform.append(car)

    def emergency(self):
        """Break glass. Merges to trunk now, jumping whatever is forming.

        By construction this does NOT ride the train: the case that must not
        wait is the case the cadence cannot serve. The forming branch is now
        based on a trunk that moved with a =hotfix= class merge, so its batch
        validation -- if it had one -- is void (guard 4b).
        """
        self.trunk += 1
        self.emergencies.append(self.clock)
        self._log("EMERGENCY merged to trunk (hotfix); forming branch is stale")
        if self.in_flight is not None:
            # the batch in validation was validated against a pre-hotfix trunk
            self.in_flight.validations += 1
            self.validations += 1
            self.phase_until = self.clock + self.V
            self.phase = "validating"
            self.rebuilds += 1
            self._log(f"train re-validates {len(self.in_flight.cars)} cars "
                      f"(one run for the batch, not one per car)")

    # -- the clock ---------------------------------------------------------
    def tick(self):
        self.clock += 1
        if self.in_flight is not None:
            if self.clock >= self.phase_until:
                self._advance()
        elif self.clock % self.cadence == 0 and self.clock >= self._blocked_until:
            self._depart()

    def _depart(self):
        if not self.platform:
            return
        cars = self.platform[:self.cap] if self.cap else list(self.platform)
        for c in cars:
            self.platform.remove(c)
            c.rides += 1
        t = Train(departs=self.clock, cars=cars)
        self.in_flight = t
        t.validations += 1
        self.validations += 1
        self.phase, self.phase_until = "validating", self.clock + self.V
        self._log(f"train departs slot {self.clock} with {len(cars)} cars")

    def _advance(self):
        t = self.in_flight
        assert t is not None
        if self.phase == "validating":
            bad = [c for c in t.cars if c.bad]
            if not bad:
                self.phase, self.phase_until = "deploying", self.clock + self.H
                return
            if self.recovery == "dissolve":
                # No bisect: dissolve the train and validate every car on its
                # own to recover attribution. That is N validation runs -- i.e.
                # exactly per-change mode, paid all at once. Stated this way
                # because "just roll it back" is not a recovery, it is a
                # deferral: a red train tells you the BATCH is bad and nothing
                # about which member, and somebody still has to find out.
                n = len(t.cars)
                for c in t.cars:
                    c.bad = False              # found by its own run
                    self.platform.append(c)
                self.validations += n
                t.validations += n
                self._log(f"train RED, dissolved: {n} cars revalidated "
                          f"individually ({len(bad)} bad) = {n} runs")
                self.in_flight, self.phase = None, "idle"
                self.phase_until = self.clock + n * self.V
                self._blocked_until = self.clock + n * self.V
                return
            # bisect: isolate ONE bad car, eject it, revalidate the remainder
            steps = max(1, math.ceil(math.log2(max(len(t.cars), 2))))
            victim = bad[0]
            victim.bad = False
            t.cars.remove(victim)
            self.platform.append(victim)
            self.validations += steps + 1
            t.validations += steps + 1
            self.phase_until = self.clock + (steps + 1) * self.V
            self._log(f"train RED: bisect {steps} runs to find {victim.chg}, "
                      f"eject, revalidate {len(t.cars)} remaining")
            return
        # deploying -> merge, one merge event for the whole batch
        self.trunk += 1
        for c in t.cars:
            c.completed = self.clock
            self.done.append(c)
        self._log(f"train lands: {len(t.cars)} cars, trunk -> {self.trunk}")
        self.in_flight, self.phase = None, "idle"

    def _log(self, m):
        self.log.append(f"[slot {self.clock:>3}] {m}")


def run_train(n=20, cadence=8, horizon=SLOTS_PER_DAY, V=V_DEFAULT, H=H_DEFAULT,
              cap=None, p_bad=0.0, seed=0, recovery="bisect",
              arrivals="closed", rate=0.0):
    w = TrainWorld(cadence=cadence, V=V, H=H, cap=cap, recovery=recovery,
                   seed=seed)
    rng = random.Random(seed + 7919)
    made = 0
    if arrivals == "closed":
        for i in range(n):
            w.submit(Car(chg=f"TRN-{i:04d}", touches=Divergence.ARTIFACT,
                         bad=rng.random() < p_bad))
        made = n
    for _ in range(horizon):
        if arrivals == "open" and rng.random() < rate:
            w.submit(Car(chg=f"TRN-{made:04d}", touches=Divergence.ARTIFACT,
                         bad=rng.random() < p_bad))
            made += 1
        w.tick()
    lat = [c.completed - c.submitted for c in w.done]
    return dict(mode=f"train/{cadence}", n=made, cadence=cadence,
                completed=len(w.done), validations=w.validations,
                mean_latency=statistics.mean(lat) if lat else float("nan"),
                max_latency=max(lat) if lat else float("nan"),
                horizon=horizon, trunk=w.trunk, world=w)




# --------------------------------------------------------------------------
# Per-change mode under open arrivals, so the CEILING is observable.
# --------------------------------------------------------------------------
def run_per_change_open(rate=0.5, berths=1, horizon=SLOTS_PER_DAY * 5,
                        V=V_DEFAULT, H=H_DEFAULT, seed=0):
    """Same engine, arrivals spread over time instead of all at slot 0.

    A closed population of 20 measures a transient. An open arrival stream
    measures the ceiling, which is the quantity ADR-0001 is really about.
    """
    w = World(berths=berths, hold_slots=H)
    rng = random.Random(seed)
    born, validations = {}, 0
    for _ in range(horizon):
        if rng.random() < rate:
            c = w.submit(Change(kind=Kind.STANDARD, touches=Divergence.ARTIFACT))
            born[c.chg] = w.clock
            w.run_gates(c)
            validations += 1
            w.reserve(c, slot=w.clock + V + 1)
        w.tick()
        for c in w.changes:
            if c.state is State.ASSESSING:
                c.window = None
                c.base = w.trunk
                c.head += 1
                c.gated_at = c.staged_at = None
                w.run_gates(c)
                validations += 1
                w.reserve(c, slot=w.clock + V + 1)
    done = [c for c in w.changes if c.state is State.COMPLETED]
    lat = [c.completed - born[c.chg] for c in done]
    return dict(arrived=len(born), completed=len(done),
                per_day=len(done) / (horizon / SLOTS_PER_DAY),
                backlog=len(born) - len(done), validations=validations,
                mean_latency=statistics.mean(lat) if lat else float("nan"))


# --------------------------------------------------------------------------
# Analytic companion: shipped-per-validation as a function of batch size.
# --------------------------------------------------------------------------
def yield_per_validation(N, p):
    """Expected changes shipped per validation run for a batch of N.

    One initial run. Each bad car costs ceil(log2 N) bisect runs plus one
    revalidation. Bad cars do not ship this ride. At p = 0 this is just N,
    which is why p = 0 is a degenerate row and not an argument for infinite
    batches -- it says only "if nothing ever fails, never validate twice".
    """
    k = N * p
    steps = 0 if N <= 1 else math.ceil(math.log2(N))
    cost = 1 + k * (steps + 1)
    return (N - k) / cost


def optimum_batch(p, hi=512):
    best = max(range(1, hi + 1), key=lambda N: yield_per_validation(N, p))
    return best, yield_per_validation(best, p)


# --------------------------------------------------------------------------
# Report.
# --------------------------------------------------------------------------
def report():
    print(f"slot = {SLOT_MINUTES} min; {SLOTS_PER_DAY} slots/day; "
          f"V = {V_DEFAULT} slot, H = {H_DEFAULT} slot\n")

    print("== 1. ADR-0001 baseline reproduced (one shot per change, 20 artifact) ==")
    print("| berths | completed | forfeits |")
    for b in (1, 4, 8):
        r = run_per_change(n=20, berths=b, requeue=False, V=0)
        print(f"| {b:>6} | {r['completed']:>2}/20     | {r['forfeits']:>8} |")

    print("\n== 1b. The same 20 changes on ONE train ==")
    r = run_train(n=20, cadence=8, p_bad=0.0, horizon=SLOTS_PER_DAY)
    print(f"| one train | {r['completed']}/20 completed "
          f"| {r['validations']} validation run "
          f"| all land in a single merge to trunk |")

    print("\n== 2. Per-change CEILING: open arrivals, 5 days, forfeits re-book ==")
    print("| offered/day | berths | completed/day | backlog | validations/ship | mean latency (h) |")
    for rate in (0.25, 0.5, 1.0):
        for b in (1, 4, 8, 16):
            rs = [run_per_change_open(rate=rate, berths=b, seed=s) for s in range(8)]
            cd = statistics.mean(r["per_day"] for r in rs)
            bl = statistics.mean(r["backlog"] for r in rs)
            vs = statistics.mean(r["validations"] for r in rs) / max(
                statistics.mean(r["completed"] for r in rs), 1e-9)
            lat = statistics.mean(r["mean_latency"] for r in rs) * SLOT_MINUTES / 60
            print(f"| {rate * SLOTS_PER_DAY:>11.0f} | {b:>6} | {cd:>13.1f} "
                  f"| {bl:>7.1f} | {vs:>16.1f} | {lat:>16.1f} |")

    print("\n== 3. Train CEILING: same offered load, cadence 4 slots (2 h), p=0 ==")
    print("| offered/day | completed/day | cars/train | validations/ship | mean latency (h) |")
    for rate in (0.25, 0.5, 1.0):
        rs = [run_train(cadence=4, p_bad=0.0, seed=s, arrivals="open", rate=min(rate, 1.0),
                        horizon=SLOTS_PER_DAY * 5, n=0) for s in range(8)]
        comp = statistics.mean(r["completed"] for r in rs)
        trains = statistics.mean(r["trunk"] for r in rs)
        val = statistics.mean(r["validations"] for r in rs)
        lat = statistics.mean(r["mean_latency"] for r in rs) * SLOT_MINUTES / 60
        print(f"| {rate * SLOTS_PER_DAY:>11.0f} | {comp / 5:>13.1f} "
              f"| {comp / max(trains, 1e-9):>10.1f} | {val / max(comp, 1e-9):>16.2f} "
              f"| {lat:>16.1f} |")

    print("\n== 4. Cadence buys latency, not throughput (p=0, offered 24/day) ==")
    print("| cadence (slots) | cadence (h) | completed/day | cars/train | mean latency (h) | predicted C/2+V+H (h) |")
    for cad in (2, 4, 8, 16, 24, 48):
        rs = [run_train(cadence=cad, p_bad=0.0, seed=s, arrivals="open", rate=0.5,
                        horizon=SLOTS_PER_DAY * 10, n=0) for s in range(8)]
        comp = statistics.mean(r["completed"] for r in rs)
        trains = statistics.mean(r["trunk"] for r in rs)
        lat = statistics.mean(r["mean_latency"] for r in rs) * SLOT_MINUTES / 60
        pred = (cad / 2 + V_DEFAULT + H_DEFAULT) * SLOT_MINUTES / 60
        print(f"| {cad:>15} | {cad * SLOT_MINUTES / 60:>11.1f} | {comp / 10:>13.1f} "
              f"| {comp / max(trains, 1e-9):>10.1f} | {lat:>16.1f} | {pred:>21.1f} |")

    print("\n== 5. Red trains: bisect cost as p_bad rises (cadence 8, offered 24/day) ==")
    print("| p_bad | completed/day | cars/train | validations/ship | mean latency (h) |")
    for p in (0.0, 0.01, 0.02, 0.05, 0.10, 0.20, 0.40):
        rs = [run_train(cadence=8, p_bad=p, seed=s, arrivals="open", rate=0.5,
                        horizon=SLOTS_PER_DAY * 10, n=0) for s in range(24)]
        comp = statistics.mean(r["completed"] for r in rs)
        trains = statistics.mean(r["trunk"] for r in rs)
        val = statistics.mean(r["validations"] for r in rs)
        lat = statistics.mean(r["mean_latency"] for r in rs) * SLOT_MINUTES / 60
        print(f"| {p:>5.2f} | {comp / 10:>13.1f} | {comp / max(trains, 1e-9):>10.1f} "
              f"| {val / max(comp, 1e-9):>16.2f} | {lat:>16.1f} |")

    print("\n== 6. Analytic crossing: changes shipped per validation run ==")
    print("| p_bad | N=1  | N=2  | N=4  | N=8  | N=16 | N=32 | best N | best yield | vs N=1 | N*.p | P(green train) |")
    for p in (0.0, 0.01, 0.02, 0.05, 0.10, 0.20, 0.33, 0.50):
        cells = [f"{yield_per_validation(N, p):.2f}" for N in (1, 2, 4, 8, 16, 32)]
        bN, by = optimum_batch(p)
        star = " (capped)" if bN >= 512 else ""
        one = yield_per_validation(1, p)
        pg = (1 - p) ** bN
        print(f"| {p:>5.2f} | " + " | ".join(c.ljust(4) for c in cells)
              + f" | {str(bN) + star:>6} | {by:>10.2f} | {by / one:>6.1f}x "
                f"| {bN * p:>4.2f} | {pg:>14.2f} |")

    print("\n== 7. Measured crossing: best cadence per p_bad, offered 24/day ==")
    print("| p_bad | best cadence | cars/train | completed/day | validations/ship | mean latency (h) |")  # best = fewest validations per shipped change
    for p in (0.0, 0.02, 0.05, 0.10, 0.20, 0.40):
        best = None
        for cad in (1, 2, 4, 8, 16, 32):
            rs = [run_train(cadence=cad, p_bad=p, seed=s, arrivals="open", rate=0.5,
                            horizon=SLOTS_PER_DAY * 10, n=0) for s in range(24)]
            comp = statistics.mean(r["completed"] for r in rs)
            trains = statistics.mean(r["trunk"] for r in rs)
            val = statistics.mean(r["validations"] for r in rs)
            lat = statistics.mean(r["mean_latency"] for r in rs) * SLOT_MINUTES / 60
            eff = val / max(comp, 1e-9)          # validation runs per shipped change
            if best is None or eff < best[0]:
                best = (eff, cad, comp / max(trains, 1e-9), comp / 10, lat)
        eff, cad, cars, cd, lat = best
        print(f"| {p:>5.2f} | {cad:>12} | {cars:>10.1f} | {cd:>13.1f} "
              f"| {eff:>16.2f} | {lat:>16.1f} |")

    print("\n== 8. Bisect vs dissolve: what attribution is worth (cadence 8) ==")
    print("| p_bad | bisect/day | dissolve/day | bisect val/ship | dissolve val/ship "
          "| bisect lat (h) | dissolve lat (h) | runs that shipped NOTHING (bisect/dissolve) |")
    for p in (0.02, 0.05, 0.10, 0.20):
        out = []
        for rec in ("bisect", "dissolve"):
            rs = [run_train(cadence=8, p_bad=p, seed=s, arrivals="open", rate=0.5,
                            recovery=rec, horizon=SLOTS_PER_DAY * 10, n=0)
                  for s in range(24)]
            comp = statistics.mean(r["completed"] for r in rs)
            val = statistics.mean(r["validations"] for r in rs)
            lat = statistics.mean(r["mean_latency"] for r in rs) * SLOT_MINUTES / 60
            good = [r["mean_latency"] for r in rs
                    if r["mean_latency"] == r["mean_latency"]]
            lat = statistics.mean(good) * SLOT_MINUTES / 60 if good else float("nan")
            starved = len(rs) - len(good)
            out.append((val / max(comp, 1e-9), lat, comp / 10, starved))
        print(f"| {p:>5.2f} | {out[0][2]:>10.1f} | {out[1][2]:>12.1f} "
              f"| {out[0][0]:>15.2f} | {out[1][0]:>17.2f} "
              f"| {out[0][1]:>14.1f} | {out[1][1]:>16.1f} "
              f"| {out[0][3]:>2}/24 | {out[1][3]:>2}/24 |")

    print("\n== 9. An emergency jumps the train ==")
    w = TrainWorld(cadence=8, seed=0)
    for i in range(12):
        w.submit(Car(chg=f"TRN-{i:04d}", touches=Divergence.ARTIFACT))
    for s in range(1, 20):
        w.tick()
        if s == 9:
            w.emergency()
    print("\n".join(w.log))
    print(f"  -> validations consumed: {w.validations}; batch rebuilds: {w.rebuilds}")
    print("\n  The same 12 changes, per-change mode, emergency at slot 9:")
    w2 = World(berths=1, hold_slots=H_DEFAULT)
    for _ in range(12):
        c = w2.submit(Change(kind=Kind.STANDARD, touches=Divergence.ARTIFACT))
        w2.run_gates(c)
        w2.reserve(c, slot=2)
    v = 12
    for s in range(1, 20):
        w2.tick()
        if s == 9:
            e = w2.submit(Change(kind=Kind.EMERGENCY, touches=Divergence.ARTIFACT))
            w2.run_gates(e)
            w2.emergency_now(e)
        for c in w2.changes:
            if c.state is State.ASSESSING:
                c.window = None
                c.base, c.head = w2.trunk, c.head + 1
                c.gated_at = c.staged_at = None
                w2.run_gates(c)
                v += 1
                w2.reserve(c, slot=w2.clock + V_DEFAULT + 1)
    done = len([c for c in w2.changes if c.state is State.COMPLETED])
    print(f"  -> {done}/12 completed in 19 slots, {v} validation runs, "
          f"{w2.forfeited} forfeits")


    print("\n== 10. How often does break-glass void the batch? (cadence 8) ==")
    print("| emergencies/day | trains rebuilt | rebuild rate | extra validations/ship | mean latency (h) |")
    for eday in (0, 1, 2, 4, 8):
        rs = []
        for seed in range(24):
            w = TrainWorld(cadence=8, seed=seed)
            rng = random.Random(seed + 104729)
            made = 0
            for _ in range(SLOTS_PER_DAY * 10):
                if rng.random() < 0.5:
                    w.submit(Car(chg=f"E-{made:04d}", touches=Divergence.ARTIFACT))
                    made += 1
                if rng.random() < eday / SLOTS_PER_DAY:
                    w.emergency()
                w.tick()
            lat = [c.completed - c.submitted for c in w.done]
            rs.append((w.trunk - len(w.emergencies), w.rebuilds, w.validations,
                       len(w.done), statistics.mean(lat) if lat else float("nan")))
        trains = statistics.mean(r[0] for r in rs)
        reb = statistics.mean(r[1] for r in rs)
        val = statistics.mean(r[2] for r in rs)
        comp = statistics.mean(r[3] for r in rs)
        lat = statistics.mean(r[4] for r in rs) * SLOT_MINUTES / 60
        print(f"| {eday:>15} | {reb:>14.1f} | {reb / max(trains, 1e-9):>12.2f} "
              f"| {val / max(comp, 1e-9):>22.2f} | {lat:>16.1f} |")
    print("\n== 11. Cadence latency fed to gates/simulate-gates.py's own curve ==")
    print("(emergency_pressure: logistic, patience 4 h, genuinely-urgent floor 5%)")
    import os
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "..", "gates"))
    try:
        from importlib import util as _u
        _s = _u.spec_from_file_location("simgates", os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "..", "gates",
            "simulate-gates.py"))
        _m = _u.module_from_spec(_s); _s.loader.exec_module(_m)
        ep = _m.emergency_pressure
    except Exception as exc:                      # pragma: no cover
        print(f"  could not load gates/simulate-gates.py: {exc}")
        ep = None
    if ep:
        print("| cadence (h) | cars/train | validations/ship | mean latency (h) "
              "| predicted emergency share |")
        for cad in (2, 4, 8, 16, 24, 48):
            rs = [run_train(cadence=cad, p_bad=0.05, seed=s_, arrivals="open",
                            rate=0.5, horizon=SLOTS_PER_DAY * 10, n=0)
                  for s_ in range(16)]
            lat = statistics.mean(r["mean_latency"] for r in rs) * SLOT_MINUTES / 60
            comp = statistics.mean(r["completed"] for r in rs)
            val = statistics.mean(r["validations"] for r in rs)
            trains = statistics.mean(r["trunk"] for r in rs)
            print(f"| {cad * SLOT_MINUTES / 60:>11.1f} "
                  f"| {comp / max(trains, 1e-9):>10.1f} "
                  f"| {val / max(comp, 1e-9):>16.2f} | {lat:>16.1f} "
                  f"| {ep(lat) * 100:>24.1f}% |")
        b = run_per_change_open(rate=0.5, berths=8, seed=0)
        print(f"| per-change  | {1.0:>10.1f} | {b['validations'] / max(b['completed'], 1):>16.2f} "
              f"| {b['mean_latency'] * SLOT_MINUTES / 60:>16.1f} "
              f"| {ep(b['mean_latency'] * SLOT_MINUTES / 60) * 100:>24.1f}% |")
        print("  A cadence long enough to amortize well is a cadence long enough")
        print("  to push traffic onto the one path that skips staging.")

    print("  Every rebuild is ONE validation run for the whole batch -- the train")
    print("  amortizes the emergency's cost too. What it cannot do is carry the")
    print("  emergency: break-glass jumps by construction, so the batch evidence")
    print("  never covers the change that most needed it.")


if __name__ == "__main__":
    report()
