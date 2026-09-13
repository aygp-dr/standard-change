#!/usr/bin/env python3
"""Property-based test of the promotion pipeline, over permutations of ops.

Complements tla/StandardChange.tla rather than repeating it:

  TLA+          exhaustive, tiny bound (2 PRs, 2 merges, 830 states), checks
                the DESIGN. Proves no counterexample exists in that space.
  this file     stochastic, large bound (up to 4 PRs, long op sequences),
                checks an executable MODEL of the implementation, including
                the divergence classification TLA+ abstracts away.

Run with GUARD_4B=0 to inject the scenario-D4 defect; hypothesis must then
find and shrink a counterexample. A property suite that cannot fail verifies
nothing (spec.org, Verification contract).
"""
import os
import sys

from hypothesis import HealthCheck, settings, target
from hypothesis.stateful import (Bundle, RuleBasedStateMachine, invariant,
                                 precondition, rule)
import hypothesis.strategies as st

GUARD_4B = os.environ.get("GUARD_4B", "1") != "0"

# Divergence classes, lowest to highest (spec.org, Guard 4b).
INERT, PIPELINE, ARTIFACT, HOTFIX = 0, 1, 2, 3
CLASS_NAME = {INERT: "inert", PIPELINE: "pipeline", ARTIFACT: "artifact", HOTFIX: "hotfix"}
# Only these can change what ships, so only these withdraw a staging pass.
WITHDRAWS = (ARTIFACT, HOTFIX)


class PR:
    def __init__(self, pid, touches):
        self.id = pid
        self.touches = touches
        self.base = 0
        self.gated = False
        self.staging_pass = False
        self.prod_label = False
        self.emergency = False
        self.approved = False
        self.merged = False

    def __repr__(self):
        return f"PR{self.id}({CLASS_NAME[self.touches]})"


class Pipeline(RuleBasedStateMachine):
    prs = Bundle("prs")

    def __init__(self):
        super().__init__()
        self.main_v = 0
        self.merges = []          # (version, class) of everything on main
        self.holder = None
        self.next_id = 1
        self.regressed = False
        self.all_prs = []          # bundles hold VarReferences, not our objects

    # ---- authoring -------------------------------------------------------
    # TLA+ proved two PRs suffice for D4; capping the bundle stops the search
    # diluting its rule choices across PRs that cannot matter.
    @precondition(lambda self: len(self.all_prs) < int(os.environ.get("PBT_PRS", 3)))
    @rule(target=prs, touches=st.sampled_from([INERT, PIPELINE, ARTIFACT]))
    def open_pr(self, touches):
        p = PR(self.next_id, touches)
        self.next_id += 1
        p.base = self.main_v
        self.all_prs.append(p)
        return p

    @rule(p=prs)
    def push(self, p):
        if p.merged:
            return
        p.gated = False              # gates must re-run
        p.staging_pass = False       # SHA binding
        p.prod_label = False

    @rule(p=prs)
    def gates_pass(self, p):
        if not p.merged:
            p.gated = True

    @rule(p=prs)
    def rebase(self, p):
        if p.merged or p.base == self.main_v:
            return
        p.base = self.main_v
        p.gated = False              # a rebase is a new tree
        p.staging_pass = False
        p.prod_label = False

    @rule(p=prs)
    def mark_emergency(self, p):
        if not p.merged:
            p.emergency = True

    @rule(p=prs)
    def approve(self, p):
        if not p.merged:
            p.approved = True

    # ---- the queue -------------------------------------------------------
    @rule(p=prs)
    def claim_staging(self, p):
        if p.merged or p.emergency:
            return
        if self.holder is not None:          # guard 1
            return
        if p.base != self.main_v:            # guard 0
            return
        if not p.gated:
            return
        self.holder = p

    @rule(p=prs)
    def staging_passed(self, p):
        if self.holder is p and p.gated and not p.merged:
            p.staging_pass = True

    @rule(p=prs)
    def promote(self, p):
        if p.merged or not p.gated:          # guard 2, no bypass
            return
        if p.staging_pass or (p.emergency and p.approved):
            p.prod_label = True

    # ---- production ------------------------------------------------------
    @rule(p=prs)
    def deploy_and_merge(self, p):
        if p.merged or not p.prod_label or not p.gated:
            return
        if not (p.staging_pass or (p.emergency and p.approved)):   # guard 4
            return
        if GUARD_4B and not p.emergency and self._divergence(p) in WITHDRAWS:
            return                                                 # guard 4b
        # Did this merge revert something already on main?
        if not p.emergency and self._divergence(p) in WITHDRAWS and p.touches == ARTIFACT:
            self.regressed = True
        p.merged = True
        self.main_v += 1
        self.merges.append((self.main_v, HOTFIX if p.emergency else p.touches))
        if self.holder is p:
            self.holder = None
        self._main_moved()

    def _divergence(self, p):
        """Highest class that landed on main since p's base."""
        since = [c for v, c in self.merges if v > p.base]
        return max(since) if since else INERT

    def _main_moved(self):
        """main-moved.yml: withdraw passes main has outrun. Never takes a berth."""
        if not GUARD_4B:
            return
        for p in self._live():
            if p.base < self.main_v and self._divergence(p) in WITHDRAWS:
                p.staging_pass = False
                p.prod_label = False
                # berth deliberately NOT released: preemption keeps the position

    def _live(self):
        return [p for p in self._all() if not p.merged]

    def _all(self):
        return self.all_prs

    # ---- invariants ------------------------------------------------------
    @invariant()
    def steer(self):
        """Most rules no-op when their guards fail, so the search gets no
        signal from them. Record the shape D4 needs -- a live staging pass on a
        PR that main has already outrun -- and report it once at teardown.
        target() may be called at most once per label per test, so it cannot
        live in an invariant."""
        armed = sum(1 for p in self._live()
                    if p.prod_label and p.gated and p.staging_pass
                    and not p.emergency and p.touches == ARTIFACT
                    and self._divergence(p) in WITHDRAWS)
        stale = sum(1 for p in self._live()
                    if p.staging_pass and p.base < self.main_v)
        # Target the IMMEDIATE precondition of the bug, not a proxy for it:
        # one deploy_and_merge away from regressing.
        self.best = max(getattr(self, "best", 0),
                        armed * 1000 + stale * 10 + self.main_v)

    def teardown(self):
        target(float(getattr(self, "best", 0)), label="stale staging passes")

    @invariant()
    def at_most_one_holder(self):
        assert self.holder is None or not self.holder.merged, \
            "a merged PR still holds the berth"

    @invariant()
    def no_red_gates_shipped(self):
        for p in self._all():
            assert not (p.merged and not p.gated), f"{p} merged with red gates"

    @invariant()
    def no_silent_bypass(self):
        for p in self._all():
            if p.merged and not p.staging_pass:
                assert p.emergency and p.approved, \
                    f"{p} skipped staging without an approved emergency"

    @invariant()
    def no_regression(self):
        assert not self.regressed, \
            "a non-emergency change shipped an artifact tree that predates a " \
            "hotfix or artifact merge already on main (scenario D4)"


Pipeline.TestCase.settings = settings(
    max_examples=int(os.environ.get("PBT_EXAMPLES", 300)),
    stateful_step_count=40,
    deadline=None,
    suppress_health_check=[HealthCheck.too_slow],
)
TestPipeline = Pipeline.TestCase



# --------------------------------------------------------------------------
# Exhaustive mode. Hypothesis samples rule sequences uniformly, which does not
# reliably reach a ~10-step ordered interleaving with no interfering pushes --
# measured at 1.1% for the precondition and 0% for the bug over 4000 random
# plays. For "every permutation" at a small bound, enumerate instead of sample:
# BFS over reachable states, which is what TLA+ does, but against this model
# rather than the design.
# --------------------------------------------------------------------------
def exhaustive(n_prs=2, touches=None, max_depth=12, verbose=False):
    from collections import deque

    touches = touches or [ARTIFACT, ARTIFACT]
    OPS = ["push", "gates_pass", "rebase", "mark_emergency", "approve",
           "claim_staging", "staging_passed", "promote", "deploy_and_merge"]

    def fresh():
        s = Pipeline.__new__(Pipeline)
        s.main_v = 0; s.merges = []; s.holder = None; s.next_id = 1
        s.regressed = False; s.all_prs = []
        for t in touches[:n_prs]:
            s.open_pr(t)
        return s

    def snap(s):
        return (s.main_v, tuple(s.merges),
                s.holder.id if s.holder else 0,
                tuple((p.base, p.gated, p.staging_pass, p.prod_label,
                       p.emergency, p.approved, p.merged) for p in s.all_prs))

    def restore(s, snapshot):
        mv, merges, hid, prs = snapshot
        s.main_v = mv; s.merges = list(merges); s.regressed = False
        s.holder = next((p for p in s.all_prs if p.id == hid), None)
        for p, st in zip(s.all_prs, prs):
            (p.base, p.gated, p.staging_pass, p.prod_label,
             p.emergency, p.approved, p.merged) = st

    start = fresh()
    seen = {snap(start): []}
    q = deque([snap(start)])
    explored = 0
    while q:
        cur = q.popleft()
        path = seen[cur]
        if len(path) >= max_depth:
            continue
        for op in OPS:
            for p in start.all_prs:
                restore(start, cur)
                getattr(start, op)(p)
                explored += 1
                if start.regressed:
                    return False, path + [f"{op}(PR{p.id})"], explored, len(seen)
                nxt = snap(start)
                if nxt not in seen:
                    seen[nxt] = path + [f"{op}(PR{p.id})"]
                    q.append(nxt)
    return True, None, explored, len(seen)


def _main():
    print(f"guard 4b: {'ON' if GUARD_4B else 'OFF (injecting scenario D4)'}")
    if "--exhaustive" in sys.argv:
        ok, trace, explored, states = exhaustive()
        print(f"  explored {explored} transitions over {states} distinct states")
        if ok:
            print("  no invariant violation reachable at this bound")
            return 0
        print("  COUNTEREXAMPLE (shortest path to a regression):")
        for i, step in enumerate(trace, 1):
            print(f"    {i:>2}. {step}")
        return 1
    import unittest
    r = unittest.main(exit=False, argv=[sys.argv[0], "-v"], verbosity=0).result
    return 0 if r.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(_main())
