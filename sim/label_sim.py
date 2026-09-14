#!/usr/bin/env python3
"""label_sim.py -- the label namespace as an explicit-state machine, checked.

The same machine as tla/Labels.tla, transcribed from the scripts rather than
from the declaration, so that a state the scripts can reach shows up here as
a reachable state rather than as an incident. Three axes, plus the estate:

  CLASS      itil:standard | itil:normal | itil:emergency
  LIFECYCLE  change:requested -> change:scheduled -> change:complete
  ACTION     deploy:staging (the berth) and deploy:production
  ESTATE     freeze, emergency -- facts about the world, not about any PR

and, per PR, the head's OBSERVATIONS, the author's READINESS (draft), how the
window was BOOKED (none | queued | designated), and SETTLEMENT: served,
merged, the PIR, and cleanup -- the merge to main and the label cleanup that
follow change:complete, in settle.sh's order, plus the automatic merge path
(merge-on-healthy.yml -> release.sh) that merges without recording.

Two checks, and they are different kinds of evidence:

  exhaustive   breadth-first over every reachable state to a stated depth
               BOUND. Within the bound this is a proof; the number printed is
               what was covered.
  property     random walks PAST the bound with Hypothesis, when it is
               installed. Finds nothing the exhaustive pass could not, in
               principle -- it exists so that "the bound was too small" has
               a cheap check, not so the bound can be skipped.

Eleven RULES, each switchable with --disable so the checker can FAIL eleven ways.
sim/cross_check.py flips each one here and in TLC and requires the same
invariant to be named. This replaces the 216-tuple cross-product of the
first cut (7220216), which enumerated label COMBINATIONS and could not say
whether any of them was reachable.
"""
import argparse, collections, itertools, sys

RULES = ["DraftGuard", "WindowGuard", "FreezeGuard", "EstateGuard", "BerthGuard",
         "ClassGuard", "LifecycleExclusive", "ReapFreesBerth", "SettleClears",
         "ReapSparesInFlight", "RecordOnMerge"]

PRS = ("p1", "p2")

# ---------------------------------------------------------------------------
# State. One immutable tuple per PR plus the estate; hashable so BFS can
# de-duplicate exactly as TLC does.
PR = collections.namedtuple("PR", "cls life draft release booking berth prod verdict uat healthy closed "
                                  "served merged pir cleaned")
State = collections.namedtuple("State", "prs freeze emg bad badcls")

def fresh(draft):
    return PR(cls=frozenset(), life=frozenset(), draft=draft, release=False,
              booking="none", berth=False, prod=False, verdict="none",
              uat=False, healthy=False, closed=False,
              served=False, merged=False, pir=False, cleaned=False)

def inits():
    for d in itertools.product([False, True], repeat=len(PRS)):
        yield State(prs=tuple(fresh(x) for x in d), freeze=False, emg=False, bad=False, badcls=False)

def is_open(q):      return not q.closed and not q.merged and "complete" not in q.life
def active(q):       return q.life - {"complete"}
def is_emg(q):       return "emergency" in q.cls
def holder(st):      return {i for i, q in enumerate(st.prs) if q.berth}
def put(st, i, q, **est):
    prs = list(st.prs); prs[i] = q
    return st._replace(prs=tuple(prs), **est)

# ---------------------------------------------------------------------------
# Actions, one per script or workflow write. Each yields (name, next_state).
def actions(st, R):
    for i, q in enumerate(st.prs):
        p = PRS[i]
        if q.closed:
            continue
        if not is_open(q):
            # a merged or completed change is no longer a candidate, but the
            # calendar does not know that: cancel and reap still fire.
            if "scheduled" in q.life and not q.berth:
                yield f"Cancel({p})", put(st, i, q._replace(life=q.life - {"scheduled"}, booking="none"))
            if "scheduled" in q.life and (not R["ReapSparesInFlight"] or not q.prod):
                berth = False if R["ReapFreesBerth"] else q.berth
                yield f"Reap({p})", put(st, i, q._replace(life=q.life - {"scheduled"}, booking="none", berth=berth))
            continue
        # labeller.yml:44-48 -- derive the class on every push. It never reads
        # itil:emergency, by design: the class is a derivation, the emergency a
        # declaration. preflight.sh:187 refuses two classes; a person resolves.
        for c in ("standard", "normal"):
            yield f"Label({p},{c})", put(st, i, q._replace(
                cls=(q.cls - {"standard", "normal"}) | {c}))
        # a person declares an emergency (label-owners.tsv: human)
        if not is_emg(q):
            yield f"DeclareEmergency({p})", put(st, i, q._replace(cls=q.cls | {"emergency"}))
        # a person removes the derived class that is wrong (preflight.sh:190)
        if is_emg(q) and len(q.cls) > 1:
            yield f"ResolveClass({p})", put(st, i, q._replace(cls=frozenset({"emergency"})))
        # gh pr ready
        if q.draft:
            yield f"MarkReady({p})", put(st, i, q._replace(draft=False))
        # a person adds release
        if not q.release:
            yield f"AddRelease({p})", put(st, i, q._replace(release=True))
        # change/watch.sh:37-38 -- consume, then record the ask
        if q.release:
            life = q.life if (R["LifecycleExclusive"] and "scheduled" in q.life) else q.life | {"requested"}
            yield f"Watch({p})", put(st, i, q._replace(release=False, life=life))
        # a person adds change:requested
        if "requested" not in q.life and "scheduled" not in q.life:
            yield f"Request({p})", put(st, i, q._replace(life=q.life | {"requested"}))
        # change/schedule.sh block:257
        if "scheduled" not in q.life:
            life = ((q.life - {"requested"}) | {"scheduled"}) if R["LifecycleExclusive"] else q.life | {"scheduled"}
            for b in ("queued", "designated"):
                yield f"Book({p},{b})", put(st, i, q._replace(life=life, booking=b))
        # change/schedule.sh cancel:303 -- Open is not required: a merged,
        # unsettled change can still be un-booked
        if "scheduled" in q.life and not q.berth:
            yield f"Cancel({p})", put(st, i, q._replace(life=q.life - {"scheduled"}, booking="none"))
        # change/reap.sh:10-14 reads only the window's end. It does not look at
        # deploy:production (ReapSparesInFlight = FALSE is the script) nor at
        # MERGED.
        if "scheduled" in q.life and (not R["ReapSparesInFlight"] or not q.prod):
            berth = False if R["ReapFreesBerth"] else q.berth
            yield f"Reap({p})", put(st, i, q._replace(life=q.life - {"scheduled"}, booking="none", berth=berth))
        # gates/preflight.sh then change/activate.sh:265-268
        if not q.berth:
            others = holder(st) - {i}
            refused = (q.draft or q.booking == "none"
                       or (st.freeze and not is_emg(q))
                       or (st.emg and not is_emg(q))
                       or bool(others))
            permitted = ((not R["ClassGuard"] or len(q.cls) <= 1)
                         and (not R["DraftGuard"] or not q.draft)
                         and (not R["WindowGuard"] or q.booking != "none")
                         and (not R["FreezeGuard"] or not st.freeze or is_emg(q))
                         and (not R["EstateGuard"] or not st.emg or is_emg(q))
                         and (not R["BerthGuard"] or not others))
            if permitted:
                yield f"Activate({p})", put(st, i, q._replace(berth=True),
                                                bad=st.bad or refused, badcls=st.badcls or len(q.cls) > 1)
        # gates/e2e.sh --pr, gates/smoke.sh --pr
        if q.berth:
            for v in ("pass", "fail"):
                yield f"Observe({p},{v})", put(st, i, q._replace(verdict=v))
        # change/observe.sh:44
        if q.berth and q.verdict == "pass" and not q.uat:
            yield f"Accept({p})", put(st, i, q._replace(uat=True))
        # promote.yml:26
        if q.berth and not q.prod and ((q.verdict == "pass" and q.uat) or is_emg(q)):
            yield f"Promote({p})", put(st, i, q._replace(prod=True))
        # gates/health.sh --pr:99
        if q.prod and not q.healthy:
            yield f"Converge({p})", put(st, i, q._replace(healthy=True, served=True))
        # merge-on-healthy.yml -> release.sh: the AUTOMATIC merge. Clears the
        # action labels and production:healthy; records nothing unless
        # RecordOnMerge, which the tree does not implement.
        if q.healthy and not q.merged:
            nq = q._replace(merged=True, berth=False, prod=False, healthy=False)
            if R["RecordOnMerge"]:
                nq = nq._replace(life=frozenset(), pir=True, cleaned=True, release=False,
                                 verdict="none", uat=False, booking="none")
            yield f"MergeOnHealthy({p})", put(st, i, nq)
        # change/abort.sh:95-114
        if is_open(q) and ("scheduled" in q.life or q.berth):
            yield f"Abort({p})", put(st, i, q._replace(
                closed=True, life=q.life - {"scheduled"}, berth=False, release=False,
                verdict="none", uat=False, healthy=False, served=False))
        # labeller.yml:101 on synchronize
        if q.verdict != "none" or q.uat or q.healthy:
            yield f"Push({p})", put(st, i, q._replace(verdict="none", uat=False, healthy=False, served=False))
    for i, q in enumerate(st.prs):
        p = PRS[i]
        if q.closed:
            continue
        # settle.sh:70 re-measures; :105 writes change:complete
        if q.served and "complete" not in q.life and not q.pir:
            yield f"Complete({p})", put(st, i, q._replace(life=q.life | {"complete"}))
        # settle.sh:124-140 -- merge unless the forge already says MERGED
        if "complete" in q.life and not q.merged:
            yield f"SettleMerge({p})", put(st, i, q._replace(merged=True))
        # settle.sh:150-168 -- the PIR
        if "complete" in q.life and q.merged and not q.pir:
            yield f"Pir({p})", put(st, i, q._replace(pir=True))
        # settle.sh:244-252 -- cleanup, change:complete included
        if q.pir and not q.cleaned:
            nq = q._replace(cleaned=True)
            if R["SettleClears"]:
                nq = nq._replace(life=frozenset(), berth=False, prod=False, release=False,
                                 verdict="none", uat=False, healthy=False, booking="none")
            yield f"Cleanup({p})", put(st, i, nq)
    yield "Freeze", st._replace(freeze=not st.freeze)
    yield "Estate", st._replace(emg=not st.emg)

# ---------------------------------------------------------------------------
# Invariants, in the same order as tla/Labels.cfg so the first one violated
# is the one TLC would name.
def invariants():
    yield "NoDeployWithTwoClasses", lambda st: not st.badcls
    yield "CleanIsClean",     lambda st: all(not q.cleaned or
                                            (not q.life and not q.berth and not q.prod and not q.release
                                             and q.verdict == "none" and not q.uat
                                             and not q.healthy and q.booking == "none")
                                            for q in st.prs)
    yield "MergedHasRecord",  lambda st: all(not (q.merged and not q.life) or q.pir for q in st.prs)
    yield "OneLifecycle",     lambda st: all(len(active(q)) <= 1 for q in st.prs)
    yield "NoDraftDeployed",  lambda st: all(not q.draft or (not q.berth and not q.prod) for q in st.prs)
    yield "NoUnbookedDeploy", lambda st: all(not (q.berth or q.prod) or q.booking != "none" for q in st.prs)
    yield "BerthHasCause",    lambda st: all(not q.berth or "scheduled" in q.life for q in st.prs)
    yield "AtMostOneHolder",  lambda st: len(holder(st)) <= 1
    yield "NoRefusedClaim",   lambda st: not st.bad

def violated(st):
    for name, inv in invariants():
        if not inv(st):
            return name
    return None

# ---------------------------------------------------------------------------
def explore(R, bound):
    """BFS to depth BOUND. Returns (states, depth_reached, violation, trace)."""
    seen = {}
    frontier = []
    for s0 in inits():
        seen[s0] = None; frontier.append(s0)
        v = violated(s0)
        if v: return len(seen), 0, v, [("Init", s0)]
    depth = 0
    while frontier and depth < bound:
        nxt = []
        for st in frontier:
            for name, st2 in actions(st, R):
                if st2 in seen: continue
                seen[st2] = (st, name)
                v = violated(st2)
                if v:
                    trace = []; cur = st2
                    while seen[cur] is not None:
                        prev, act = seen[cur]; trace.append((act, cur)); cur = prev
                    trace.append(("Init", cur)); trace.reverse()
                    return len(seen), depth + 1, v, trace
                nxt.append(st2)
        frontier = nxt; depth += 1
    return len(seen), depth, None, [] if not frontier else None

def random_walks(R, bound, walks, length, seed):
    """Past the bound: Hypothesis-driven walks. Returns (walks_run, violation, trace) or None."""
    try:
        from hypothesis import given, settings, strategies as hst, HealthCheck
    except ImportError:
        return None
    found = {}
    @settings(max_examples=walks, deadline=None, database=None,
              suppress_health_check=list(HealthCheck), derandomize=seed is None)
    @given(hst.lists(hst.integers(min_value=0, max_value=10**6), min_size=bound + 1, max_size=length))
    def walk(choices):
        st = next(iter(inits()))
        trace = [("Init", st)]
        for c in choices:
            opts = list(actions(st, R))
            if not opts: break
            name, st = opts[c % len(opts)]
            trace.append((name, st))
            v = violated(st)
            if v and "hit" not in found:
                found["hit"] = (v, trace)
                raise AssertionError(v)
    try:
        walk()
    except AssertionError:
        pass
    return walks, found.get("hit", (None, []))[0], found.get("hit", (None, []))[1]

def show(q):
    return (f"cls={sorted(q.cls)} life={sorted(q.life)} draft={q.draft} rel={q.release} "
            f"book={q.booking} berth={q.berth} prod={q.prod} v={q.verdict} uat={q.uat} "
            f"healthy={q.healthy} served={q.served} merged={q.merged} pir={q.pir} "
            f"cleaned={q.cleaned} closed={q.closed}")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--disable", action="append", default=[], choices=RULES,
                    help="switch a rule off; the checker must then find a violation")
    ap.add_argument("--bound", type=int, default=12, help="exhaustive BFS depth")
    ap.add_argument("--walks", type=int, default=200, help="random walks past the bound")
    ap.add_argument("--length", type=int, default=40, help="max walk length")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()
    R = {r: r not in a.disable for r in RULES}
    off = [r for r in RULES if not R[r]]
    say = (lambda *x: None) if a.quiet else print

    say(f"  rules off: {off or 'none'}")
    n, d, v, trace = explore(R, a.bound)
    if v:
        say(f"  exhaustive: VIOLATION {v} at depth {d} after {n} states")
        for act, st in trace[-min(len(trace), 8):]:
            say(f"    {act:<24} {' | '.join(show(q) for q in st.prs)} freeze={st.freeze} emg={st.emg}")
        print(f"VERDICT violated {v}")
        return 1
    complete = trace == []
    say(f"  exhaustive: {n} states, depth {d}, "
        f"{'state space exhausted' if complete else f'bound {a.bound} reached, not exhausted'}, no violation")
    rw = random_walks(R, a.bound, a.walks, a.length, None) if a.walks > 0 else None
    if a.walks == 0:
        say("  property: walks disabled (--walks 0)")
    elif rw is None:
        say("  property: hypothesis not installed -- walks past the bound skipped")
    else:
        w, hv, htrace = rw
        if hv:
            say(f"  property: VIOLATION {hv} on a walk past the bound")
            print(f"VERDICT violated {hv}")
            return 1
        say(f"  property: {w} walks of up to {a.length} steps past depth {a.bound}, no violation")
    print("VERDICT holds")
    return 0

if __name__ == "__main__":
    sys.exit(main())
