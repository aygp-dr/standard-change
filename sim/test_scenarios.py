#!/usr/bin/env python3
"""Hypothesis scenarios over the closed-loop simulator.

Needs no PRs, no forge, no running apps, no worktrees, no network. Simulated
time, so multi-day scenarios run in milliseconds.

What this does NOT cover, deliberately: the port-block and worktree rules.
Those are verified by actually running the apps (three blocks, 18 ports), and
no simulation substitutes for that -- it is a different claim about a different
system.
"""
import sys

from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

from pipeline_sim import (Change, Deploys, Divergence, Kind, SLOTS_PER_DAY,
                          State, World)

kinds = st.sampled_from([Kind.STANDARD, Kind.NORMAL])
touches = st.sampled_from(list(Divergence)[:3])


@given(st.lists(st.tuples(kinds, touches), min_size=1, max_size=8),
       st.integers(min_value=1, max_value=4))
@settings(max_examples=400, deadline=None,
          suppress_health_check=[HealthCheck.too_slow])
def test_invariants_hold(specs, berths):
    """No ordering of submit/gate/reserve/tick violates the guards."""
    w = World(berths=berths)
    for kind, t in specs:
        c = w.submit(Change(kind=kind, touches=t))
        w.run_gates(c)
        w.reserve(c)
    for _ in range(SLOTS_PER_DAY):
        w.tick()
        w.check()


@given(st.integers(min_value=1, max_value=6))
@settings(max_examples=200, deadline=None)
def test_emergency_never_strands_a_regression(n):
    """D4, structurally: an emergency merging under a scheduled change must
    never let that change ship a tree predating the hotfix."""
    w = World(berths=1)
    victims = []
    for _ in range(n):
        c = w.submit(Change(kind=Kind.STANDARD, touches=Divergence.ARTIFACT))
        w.run_gates(c)
        w.reserve(c)
        victims.append(c)
    e = w.submit(Change(kind=Kind.EMERGENCY, touches=Divergence.ARTIFACT))
    w.run_gates(e)
    w.emergency_now(e)
    for _ in range(SLOTS_PER_DAY):
        w.tick()
        w.check()
    assert not w.regressed


@given(st.integers(min_value=2, max_value=10))
@settings(max_examples=100, deadline=None)
def test_capacity_is_bounded_by_the_calendar(n):
    """Throughput can never exceed the change schedule's quantum."""
    w = World(berths=1)
    for _ in range(n):
        c = w.submit(Change(kind=Kind.STANDARD, touches=Divergence.INERT))
        w.run_gates(c)
        w.reserve(c)
    for _ in range(SLOTS_PER_DAY * 2):
        w.tick()
    done = [c for c in w.changes if c.state is State.COMPLETED]
    assert len(done) <= SLOTS_PER_DAY * 2 * w.berths


def demo():
    """The scenario the reservation/activation split exists for."""
    w = World(berths=1)
    victim = w.submit(Change(kind=Kind.STANDARD, touches=Divergence.ARTIFACT))
    w.run_gates(victim)
    w.reserve(victim, slot=6)                 # books a window 3 hours out
    hot = w.submit(Change(kind=Kind.EMERGENCY, touches=Divergence.ARTIFACT))
    w.run_gates(hot)
    w.emergency_now(hot)                      # breaks glass now
    for _ in range(10):
        w.tick()
    print("\n".join(w.log))
    print(f"\nregressed: {w.regressed}   forfeited slots: {w.forfeited}")
    print(f"{victim.chg} state={victim.state.value} forfeits={victim.forfeits}")
    assert not w.regressed


if __name__ == "__main__":
    if "--demo" in sys.argv:
        demo()
    else:
        import pytest
        sys.exit(pytest.main([__file__, "-q"]))


# ---------------------------------------------------------------------------
# Guard 6 -- production-first. Three cases, and the third is the one that both
# real implementations got wrong: they collapsed "deploys nothing" together
# with "could not tell", and exempted both.
#
# Each test below must FAIL if guard 6 is removed from World._finish. That is
# the standard spec.org sets: absence of the bug is not an answer.
# ---------------------------------------------------------------------------

def _ready(w, c):
    """Walk a change to the point where the merge is the next thing to happen."""
    w.submit(c); w.run_gates(c); w.reserve(c)
    for _ in range(SLOTS_PER_DAY):
        if c.state is State.COMPLETED or c.state is State.ASSESSING:
            break
        w.tick()
    return c


def test_guard6_refuses_when_production_is_behind():
    """SOME + production serving an older trunk -> refuse."""
    w = World()
    w.trunk, w.in_prod = 3, 2          # trunk moved, production did not follow
    c = _ready(w, Change(Kind.STANDARD, Divergence.INERT, deploys=Deploys.SOME))
    assert c.state is not State.COMPLETED, \
        "guard 6 let a change merge onto a trunk production is not serving"


def test_guard6_abstains_when_the_deploy_set_is_unknown():
    """INDETERMINATE -> abstain and BLOCK. Never exempt.

    This is the case the repo's `groups.sh ... || true` turned into 'deploys
    nothing', and the case 000 answered with exit 0 'exempt'.
    """
    w = World()
    w.trunk, w.in_prod = 3, 2
    c = _ready(w, Change(Kind.STANDARD, Divergence.INERT,
                         deploys=Deploys.INDETERMINATE))
    assert c.state is not State.COMPLETED, \
        "indeterminate was treated as exempt -- the defect both implementations had"


def test_guard6_abstains_when_production_cannot_be_observed():
    """SOME + unreachable production -> abstain, not proceed.

    Class 1: unreachable is not falsified. 000 returned exempt here.
    """
    w = World()
    w.trunk, w.in_prod = 3, 3          # would otherwise pass
    w.prod_reachable = False
    c = _ready(w, Change(Kind.STANDARD, Divergence.INERT, deploys=Deploys.SOME))
    assert c.state is not State.COMPLETED, \
        "guard 6 proceeded without observing production"


def test_guard6_exempts_only_on_positive_evidence():
    """PROVABLY_NONE -> exempt, even with production behind.

    The permit direction. Without it the three tests above would pass on a
    guard that simply refuses everything, which is not a guard.
    """
    w = World()
    w.trunk, w.in_prod = 3, 2
    c = _ready(w, Change(Kind.STANDARD, Divergence.INERT,
                         deploys=Deploys.PROVABLY_NONE))
    assert c.state is State.COMPLETED, \
        "a change proven to deploy nothing was blocked by guard 6"
