#!/usr/bin/env python3
"""Grind a week of change traffic through the model in simulated time.

The full PR path is heavyweight -- branch, push, labeller, gates, window,
deploy, verify, settle -- and exercising every scenario that way costs hours.
This drives the same state machine on a simulated clock, so a week runs in
under a second, and records every INTERESTING transition it reaches.

The output is not a pass/fail. It is a TEST PLAN: for each transition the model
actually produced, the steps to reproduce it with real PRs, so the expensive
run can be aimed rather than exploratory.

    ./speedrun.py                 # a week, mixed traffic
    ./speedrun.py --days 30 --seed 7
    ./speedrun.py --plan          # emit the test plan
"""
import argparse
import collections
import random
import sys

from pipeline_sim import (Change, Divergence, Kind, SLOTS_PER_DAY, State, World)

# What arrives, and how often. Doc changes are frequent and inert; emergencies
# are rare and expensive. These proportions are the assumption most worth
# arguing with -- change them and the plan changes.
MIX = [
    ("app change",   0.55, Kind.STANDARD, Divergence.ARTIFACT),
    ("doc update",   0.25, Kind.STANDARD, Divergence.INERT),
    ("pipeline",     0.15, Kind.NORMAL,   Divergence.PIPELINE),
    ("emergency",    0.05, Kind.EMERGENCY, Divergence.ARTIFACT),
]


class Run:
    def __init__(self, days, berths, seed, gate_pass=0.90, health_pass=0.95):
        self.w = World(berths=berths, seed=seed)
        self.rng = random.Random(seed)
        self.days = days
        self.gate_pass = gate_pass
        self.health_pass = health_pass
        self.events = collections.Counter()
        self.trace = []
        self.rollbacks = []
        self.live = []          # changes not yet终 finished

    def _note(self, kind, detail):
        self.events[kind] += 1
        self.trace.append((self.w.clock, kind, detail))

    def arrive(self):
        r = self.rng.random(); acc = 0
        for name, p, kind, touches in MIX:
            acc += p
            if r < acc:
                c = self.w.submit(Change(kind=kind, touches=touches))
                self._note("submitted", f"{c.chg} {name}")
                return c, name
        return None, None

    def step(self):
        # arrivals: a few per day
        if self.rng.random() < 0.35:
            c, name = self.arrive()
            if c:
                # gates: may be red
                if self.rng.random() < self.gate_pass:
                    self.w.run_gates(c)
                else:
                    self._note("gate red", f"{c.chg} — will retry")
                if c.kind is Kind.EMERGENCY and c.gates_green():
                    self.w.emergency_now(c)
                    self._note("emergency break-glass", c.chg)
                elif c.gates_green():
                    if self.w.reserve(c) is None:
                        self._note("window refused", f"{c.chg} guard 0 or queue")
                self.live.append(c)

        before = {c.chg: c.state for c in self.w.changes}
        self.w.tick()

        for c in self.w.changes:
            was, now = before.get(c.chg), c.state
            if was == now:
                continue
            if now is State.IMPLEMENTING:
                self._note("activated", c.chg)
            elif now is State.COMPLETED:
                # guard 5 may refuse after the deploy
                if self.rng.random() >= self.health_pass:
                    self.rollbacks.append((self.w.clock, c.chg))
                    self._note("ROLLBACK", f"{c.chg} — guard 5 refused, reverting")
                else:
                    self._note("completed", c.chg)
            elif was is State.SCHEDULED and now is State.ASSESSING:
                self._note("slot forfeited", f"{c.chg} — guards refused at reliance")

        # anything that forfeited or went red re-requests
        for c in self.live:
            if c.state is State.ASSESSING and c.gates_green() and c.window is None:
                if self.rng.random() < 0.5:
                    self.w.rebase(c); self.w.run_gates(c)
                    if self.w.reserve(c) is not None:
                        self._note("re-requested", c.chg)

    def go(self):
        for _ in range(self.days * SLOTS_PER_DAY):
            self.step()
        return self


def report(r):
    done = [c for c in r.w.changes if c.state is State.COMPLETED]
    print(f"\n  {r.days} simulated days, {r.w.berths} berth(s), "
          f"{len(r.w.changes)} changes arrived")
    print(f"  shipped {len(done)}   forfeits {r.w.forfeited}   "
          f"rollbacks {len(r.rollbacks)}   trunk at {r.w.trunk}")
    print(f"\n  {'transition':<26} {'count':>6}")
    for k, n in r.events.most_common():
        print(f"  {k:<26} {n:>6}")
    return r


PLAN = {
 "submitted":            ("open a PR touching apps/<x>",
                          "labeller attaches app:<x> and change:standard"),
 "window refused":       ("add change:requested while another change holds the berth",
                          "blocked:queue, and a comment naming the holder"),
 "gate red":             ("push a commit that fails a unit test",
                          "gate.yml red; promote.yml must refuse"),
 "activated":            ("let a reserved window come due with main unmoved",
                          "deploy:staging appears; the scheduler, not a person, adds it"),
 "slot forfeited":       ("merge an apps/** change to main while a window is reserved",
                          "the slot is forfeited, berth HELD, staging pass withdrawn"),
 "emergency break-glass":("add change:emergency + an approving review, then deploy:production",
                          "staging is skipped; guards 2 and 5 still run"),
 "ROLLBACK":             ("deploy, then make /version.json report the OLD sha",
                          "guard 5 UNCONVERGED, rollback to the idle colour, PIR records it"),
 "completed":            ("a clean change end to end",
                          "production:healthy, then merge, then the berth frees"),
 "re-requested":         ("rebase a forfeited change and re-add change:requested",
                          "it takes the next free window"),
}


def plan(r):
    print("\n" + "=" * 72)
    print("  TEST PLAN — every transition the model actually reached")
    print("=" * 72)
    for k, n in r.events.most_common():
        how, expect = PLAN.get(k, ("(no PR recipe yet)", ""))
        print(f"\n  {k}   (model reached it {n}x)")
        print(f"    do:     {how}")
        print(f"    expect: {expect}")
    missing = [k for k in PLAN if k not in r.events]
    if missing:
        print(f"\n  NOT REACHED by this run: {', '.join(missing)}")
        print("    Either the mix does not produce it, or the model cannot.")
        print("    Worth knowing before spending a real PR on it.")


if __name__ == "__main__":
    a = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    a.add_argument("--days", type=int, default=7)
    a.add_argument("--berths", type=int, default=1)
    a.add_argument("--seed", type=int, default=20260913)
    a.add_argument("--plan", action="store_true")
    a.add_argument("--trace", action="store_true")
    args = a.parse_args()
    r = report(Run(args.days, args.berths, args.seed).go())
    if args.trace:
        print()
        for t, k, d in r.trace[:40]:
            print(f"  [{r.w.fmt(t)}] {k:<24} {d}")
    if args.plan:
        plan(r)
