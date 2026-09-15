#!/usr/bin/env python3
"""label_sim.py -- the label namespace as an explicit-state machine, checked.

The same machine as tla/Labels.tla, transcribed from the scripts rather than
from the declaration, so that a state the scripts can reach shows up here as
a reachable state rather than as an incident. Three axes, plus the estate:

  CLASS      itil:standard | itil:normal | itil:emergency
  LIFECYCLE  change:requested -> change:scheduled -> change:complete
  ACTION     deploy:staging (the berth), <env>:deployed, deploy:production
  ESTATE     freeze, emergency -- facts about the world, not about any PR

and, per PR, the head's OBSERVATIONS (<env>:healthy, the staging verdict,
uat), the author's READINESS (draft), a person's staging:hold, how the window
was BOOKED, and SETTLEMENT (served, merged, the PIR, cleanup).

Two checks, and they are different kinds of evidence:

  exhaustive   breadth-first over every reachable state to a stated depth
               BOUND. Within the bound this is a proof; the number printed is
               what was covered. The fourteen-rule machine has 25,066,512
               states at depth 37 (TLC); Python exhausts it only with a lot
               of memory, so the default bound is a slice and TLC is the
               proof of the whole.
  property     random walks PAST the bound with Hypothesis, when installed.

  --census     print every distinct per-change SHAPE reached -- the tuple of
               (lifecycle, action labels, observations, flags) -- so README's
               lifecycle diagram can be checked against what is reachable.

Seventeen RULES, each switchable with --disable so the checker can FAIL
seventeen ways. sim/cross_check.py flips each one here and in TLC and requires
the same invariant to be named.
"""
import argparse, collections, itertools, sys

# INTERFERE is not a rule of the pipeline. It is a rule of the WORLD: any
# actor -- a human, a CI workflow, a scheduler, another agent -- may add or
# remove any label at any moment, and none of them can see the others. The
# labels are the entire channel (research/findings/labels-are-the-only-channel.org).
#
# With it ON, label-set invariants like OneLifecycle STOP BEING INVARIANTS,
# because no guard on one writer can prevent a violation produced by a writer
# it does not control. That is not the model breaking; it is the model finally
# describing the estate we actually run, where five identities wrote
# deploy:staging in one day.
#
# What must survive interference is the ACTION invariants: no deploy on a
# draft, no deploy with two classes, no unbooked deploy, no verdict without a
# measurement. Those hold because the refusal happens at the deploy, not at
# the labelling -- which is the whole reason guard 4 reads observation records
# that name a build, and why a label cannot name one.
RULES = ["Interfere", "DraftGuard", "WindowGuard", "FreezeGuard", "EstateGuard", "BerthGuard",
         "ClassGuard", "LifecycleExclusive", "ReapFreesBerth", "SettleClears",
         "ReapSparesInFlight", "RecordOnMerge", "EmergencyPreempts",
         "HoldGuard", "HealthyBeforeVerdict", "LockResets", "UnaffectedMerges"]

PRS = ("p1", "p2")

PR = collections.namedtuple("PR", "cls life draft release booking berth sdep shealthy hold prod pdep "
                                  "verdict uat healthy closed served merged pir cleaned unit unaff")
State = collections.namedtuple("State", "prs freeze emg bad badcls badpromote badverdict emgwaited refuseddirty badunaff")

def fresh(draft, unit):
    return PR(cls=frozenset(), life=frozenset(), draft=draft, release=False, booking="none",
              berth=False, sdep=False, shealthy=False, hold=False, prod=False, pdep=False,
              verdict="none", uat=False, healthy=False, closed=False,
              served=False, merged=False, pir=False, cleaned=False, unit=unit, unaff=False)

def inits():
    # draft is the author's; unit is the labeller's finding (the diff touches an app:*), fixed per head
    for d in itertools.product([False, True], repeat=len(PRS)):
        for u in itertools.product([False, True], repeat=len(PRS)):
            yield State(prs=tuple(fresh(x, y) for x, y in zip(d, u)), freeze=False, emg=False,
                        bad=False, badcls=False, badpromote=False, badverdict=False, emgwaited=False,
                        refuseddirty=False, badunaff=False)

def is_open(q):       return not q.closed and not q.merged and "complete" not in q.life
def active(q):        return q.life - {"complete"}
def is_emg(q):        return "emergency" in q.cls
def holder(st):       return {i for i, q in enumerate(st.prs) if q.berth}
def emg_ready(st, q): return st.emg and is_open(q) and is_emg(q) and "scheduled" in q.life and not q.draft and not q.berth
def put(st, i, q, **est):
    prs = list(st.prs); prs[i] = q
    return st._replace(prs=tuple(prs), **est)
CLEAR_STAGING = dict(berth=False, sdep=False, shealthy=False)
CLEAR_BUILD = dict(verdict="none", uat=False, healthy=False, served=False, sdep=False, shealthy=False, pdep=False)

# `abandoned` is a CHANGE closure: nobody is driving this any more. It is not
# `failed` (nothing was wrong with it), not `backed-out` (it never deployed),
# and not `cancelled` or `expired` -- those are WINDOW results and can never be
# true of a change. spec.org §Nomenclature, corrected 2026-09-15.
LIFE_LABELS = ("requested", "scheduled", "start", "complete", "abandoned", "superseded")


def actions(st, R):
    # THE UNCOORDINATED WRITER. Enabled by default; --disable Interfere turns
    # the world back into one where every actor is well behaved, which is the
    # world the earlier model assumed and the estate has never been in.
    if R["Interfere"]:
        for i, q in enumerate(st.prs):
            p = PRS[i]
            if q.closed:
                continue
            for lab in LIFE_LABELS:
                if lab not in q.life:
                    yield (f"Interfere({p},+{lab})",
                           put(st, i, q._replace(life=q.life | {lab})))
                else:
                    yield (f"Interfere({p},-{lab})",
                           put(st, i, q._replace(life=q.life - {lab})))
            # somebody else's berth label, added or taken -- scenarios D21
            yield (f"Interfere({p},berth={not q.berth})",
                   put(st, i, q._replace(berth=not q.berth)))

    for i, q in enumerate(st.prs):
        p = PRS[i]
        if q.closed:
            continue
        # the calendar does not know a change is merged or complete: cancel and reap still fire
        if "scheduled" in q.life and not q.berth:
            yield f"Cancel({p})", put(st, i, q._replace(life=q.life - {"scheduled"}, booking="none"))
        if "scheduled" in q.life and (not R["ReapSparesInFlight"] or not q.prod):
            nq = q._replace(life=q.life - {"scheduled"}, booking="none")
            if R["ReapFreesBerth"]: nq = nq._replace(**CLEAR_STAGING)
            yield f"Reap({p})", put(st, i, nq)
        # settlement runs on merged/complete changes too
        if q.served and "complete" not in q.life and not q.pir:
            yield f"Complete({p})", put(st, i, q._replace(life=q.life | {"complete"}))
        if "complete" in q.life and not q.merged:
            yield f"SettleMerge({p})", put(st, i, q._replace(merged=True))
        if "complete" in q.life and q.merged and not q.pir:
            yield f"Pir({p})", put(st, i, q._replace(pir=True))
        if q.pir and not q.cleaned:
            nq = q._replace(cleaned=True)
            if R["SettleClears"]:
                nq = nq._replace(life=frozenset(), berth=False, prod=False, release=False, verdict="none",
                                 uat=False, healthy=False, booking="none", sdep=False, shealthy=False,
                                 pdep=False, hold=False)
            yield f"Cleanup({p})", put(st, i, nq)
        if not is_open(q):
            continue
        # labeller.yml:44-48 -- derive the class on every push; never reads itil:emergency
        for c in ("standard", "normal"):
            yield f"Label({p},{c})", put(st, i, q._replace(cls=(q.cls - {"standard", "normal"}) | {c}))
        if not is_emg(q):
            yield f"DeclareEmergency({p})", put(st, i, q._replace(cls=q.cls | {"emergency"}))
        if is_emg(q) and len(q.cls) > 1:
            yield f"ResolveClass({p})", put(st, i, q._replace(cls=frozenset({"emergency"})))
        if q.draft:
            yield f"MarkReady({p})", put(st, i, q._replace(draft=False))
        if not q.release:
            yield f"AddRelease({p})", put(st, i, q._replace(release=True))
        if q.release:  # watch.sh:37-38
            life = q.life if (R["LifecycleExclusive"] and "scheduled" in q.life) else q.life | {"requested"}
            yield f"Watch({p})", put(st, i, q._replace(release=False, life=life))
        if "requested" not in q.life and "scheduled" not in q.life:
            yield f"Request({p})", put(st, i, q._replace(life=q.life | {"requested"}))
        if "scheduled" not in q.life:  # schedule.sh block:257
            life = ((q.life - {"requested"}) | {"scheduled"}) if R["LifecycleExclusive"] else q.life | {"scheduled"}
            for b in ("queued", "designated"):
                yield f"Book({p},{b})", put(st, i, q._replace(life=life, booking=b))
        # preflight, then activate.sh:271-275 -- claim the berth.
        # WAS activate.sh:265-268, which is the window-close trap, a different
        # control entirely. The citation rotted when lines moved and nothing
        # noticed, because nothing here executes activate.sh: this simulator
        # replays its OWN table and the pointer to the driver is prose.
        # Peer standard-change-002 names the general case F-15.
        if not q.berth:
            others = holder(st) - {i}
            refused = (q.unaff or q.draft or q.booking == "none" or (st.freeze and not is_emg(q))
                       or (st.emg and not is_emg(q)) or bool(others))
            permitted = ((not R["UnaffectedMerges"] or not q.unaff)
                         and (not R["ClassGuard"] or len(q.cls) <= 1)
                         and (not R["DraftGuard"] or not q.draft)
                         and (not R["WindowGuard"] or q.booking != "none")
                         and (not R["FreezeGuard"] or not st.freeze or is_emg(q))
                         and (not R["EstateGuard"] or not st.emg or is_emg(q))
                         and (not R["BerthGuard"] or not others))
            if permitted:
                yield f"Activate({p})", put(st, i, q._replace(berth=True),
                                            bad=st.bad or refused, badcls=st.badcls or len(q.cls) > 1,
                                            badunaff=st.badunaff or q.unaff)
        # THE LOCK: deploy:staging is the environment lock. Refused while another
        # holds it, a change loses every marker, human intent included; the
        # person re-states it (rule LockResets).
        if not q.berth and "scheduled" in q.life and not q.draft and (holder(st) - {i}):
            markers = bool(q.life) or q.booking != "none" or q.release or q.hold or q.verdict != "none" or q.uat or q.sdep or q.shealthy
            if R["LockResets"]:
                yield f"LockRefusal({p})", put(st, i, q._replace(life=frozenset(), booking="none", release=False, hold=False,
                                                                 verdict="none", uat=False, sdep=False, shealthy=False))
            else:
                yield f"LockRefusal({p})", st._replace(refuseddirty=st.refuseddirty or markers)
        # the install and its health
        if q.berth and not q.sdep:
            yield f"DeployStaging({p})", put(st, i, q._replace(sdep=True))
        if q.sdep and not q.shealthy:
            yield f"StagingHealthy({p})", put(st, i, q._replace(shealthy=True))
        # a person's hold, toggled
        yield f"Hold({p})", put(st, i, q._replace(hold=not q.hold))
        # e2e / smoke: only once staging is healthy, under the rule
        if q.berth and (not R["HealthyBeforeVerdict"] or q.shealthy):
            for v in ("pass", "fail"):
                yield f"Observe({p},{v})", put(st, i, q._replace(verdict=v), badverdict=st.badverdict or not q.shealthy)
        if q.berth and q.verdict == "pass" and not q.uat:
            yield f"Accept({p})", put(st, i, q._replace(uat=True))
        # promote.yml: smoke lands deploy:production; a hold stops it
        if q.berth and not q.prod and (q.verdict == "pass" or is_emg(q)) and (not R["HoldGuard"] or not q.hold):
            yield f"Promote({p})", put(st, i, q._replace(prod=True), badpromote=st.badpromote or q.hold)
        if q.prod and not q.pdep:
            yield f"DeployProduction({p})", put(st, i, q._replace(pdep=True))
        if q.pdep and not q.healthy:
            yield f"Converge({p})", put(st, i, q._replace(healthy=True, served=True))
        # merge-on-healthy.yml -> release.sh: the automatic merge, recording nothing
        if q.healthy and not q.merged:
            nq = q._replace(merged=True, berth=False, prod=False, healthy=False, sdep=False, shealthy=False, pdep=False)
            if R["RecordOnMerge"]:
                nq = nq._replace(life=frozenset(), pir=True, cleaned=True, release=False,
                                 verdict="none", uat=False, booking="none", hold=False)
            yield f"MergeOnHealthy({p})", put(st, i, nq)
        # abort.sh:95-114
        if "scheduled" in q.life or q.berth:
            yield f"Abort({p})", put(st, i, q._replace(closed=True, life=q.life - {"scheduled"}, berth=False,
                                                      release=False, **CLEAR_BUILD))
        # release:unaffected -- a person's claim that the estate is untouched; the only
        # act left is the merge, and only when the labeller agrees (no app:*).
        # A claim that contradicts the labeller is withdrawn by a person. [UnaffectedMerges]
        if not q.unaff:
            yield f"DeclareUnaffected({p})", put(st, i, q._replace(unaff=True))
        if q.unaff:
            yield f"WithdrawUnaffected({p})", put(st, i, q._replace(unaff=False))
        if q.unaff and not q.draft and not q.berth and (not R["UnaffectedMerges"] or not q.unit):
            yield f"MergeUnaffected({p})", put(st, i, q._replace(merged=True, pir=True, cleaned=True, life=frozenset(),
                                                                 release=False, booking="none", hold=False,
                                                                 verdict="none", uat=False),
                                               badunaff=st.badunaff or q.unit)
        # labeller.yml:101 on synchronize: everything about the old head
        if q.verdict != "none" or q.uat or q.healthy or q.sdep or q.shealthy or q.pdep:
            yield f"Push({p})", put(st, i, q._replace(**CLEAR_BUILD))
    # the estate closes for an emergency: eviction, or the record that one waited
    for i, e in enumerate(st.prs):
        if not emg_ready(st, e):
            continue
        for j, h in enumerate(st.prs):
            if j == i or not h.berth or is_emg(h) or h.prod:
                continue
            if R["EmergencyPreempts"]:
                yield f"Evict({PRS[i]},{PRS[j]})", put(st, j, h._replace(
                    life=h.life - {"scheduled"}, booking="none", verdict="none", uat=False, **CLEAR_STAGING))
            else:
                yield f"EmergencyWaits({PRS[i]})", st._replace(emgwaited=True)
    yield "Freeze", st._replace(freeze=not st.freeze)
    yield "Estate", st._replace(emg=not st.emg)

def invariants():  # same order as tla/Labels.cfg
    yield "NoDeployWithTwoClasses", lambda st: not st.badcls
    yield "CleanIsClean", lambda st: all(not q.cleaned or (not q.life and not q.berth and not q.prod and not q.release
                                          and not q.sdep and not q.shealthy and not q.pdep and not q.hold
                                          and q.verdict == "none" and not q.uat and not q.healthy and q.booking == "none")
                                          for q in st.prs)
    yield "MergedHasRecord", lambda st: all(not (q.merged and not q.life) or q.pir for q in st.prs)
    # NOT CHECKED UNDER INTERFERENCE. At most one active lifecycle label is a
    # property the pipeline CONVERGES to, not one it can hold against an
    # uncoordinated writer. It is still checked when Interfere is disabled,
    # which is where it says something: it means the pipeline's own actions
    # never produce two.
    yield "OneLifecycle", lambda st: all(len(active(q)) <= 1 for q in st.prs)
    # --- LABEL-SET PROPERTIES vs ACTION PROPERTIES ---------------------------
    #
    # The four below are stated over the LABEL, not over the act of deploying,
    # and `--disable Interfere` is the only world in which they can hold. Run
    # with interference and NoUnbookedDeploy falls at depth 1 to a single
    # Interfere(p1,berth=True): somebody set the berth label without a booking,
    # which is a thing that happens (deploy-staging.yml sets it; a person can
    # set it; a second driver set it on 2026-09-15 at 02:51:42Z).
    #
    # That is not a bug in the estate. It is these four being MISNAMED: they
    # read as "no unbooked deploy" and they check "no unbooked LABEL". The
    # deploy is what must be refused, and the pipeline does refuse it -- at the
    # deploy, from a record, not from the label. The model has not caught up.
    #
    # They are reported under interference rather than silently skipped,
    # because the gap between what they say and what they check is the finding.
    yield "NoDraftDeployed", lambda st: all(not q.draft or (not q.berth and not q.prod) for q in st.prs)
    yield "NoUnbookedDeploy", lambda st: all(not (q.berth or q.prod) or q.booking != "none" for q in st.prs)
    yield "BerthHasCause", lambda st: all(not q.berth or "scheduled" in q.life for q in st.prs)
    yield "AtMostOneHolder", lambda st: len(holder(st)) <= 1
    yield "NoRefusedClaim", lambda st: not st.bad
    yield "EmergencyNeverWaits", lambda st: not st.emgwaited
    yield "NoPromoteUnderHold", lambda st: not st.badpromote
    yield "VerdictOnHealthy", lambda st: not st.badverdict
    yield "LockRefusalResets", lambda st: not st.refuseddirty
    yield "UnaffectedNeverDeploys", lambda st: not st.badunaff

def violated(st):
    for name, inv in invariants():
        if not inv(st): return name
    return None

def shape(q):
    """The per-change shape README's lifecycle diagram must be able to name."""
    life = "+".join(sorted(q.life)) or "opened"
    if q.closed: life = "closed"
    acts = [n for n, v in (("deploy:staging", q.berth), ("staging:deployed", q.sdep), ("deploy:production", q.prod),
                           ("production:deployed", q.pdep)) if v]
    obs = [n for n, v in (("staging:healthy", q.shealthy), (f"staging:{q.verdict}", q.verdict != "none"),
                          ("staging:uat", q.uat), ("production:healthy", q.healthy)) if v]
    flags = [n for n, v in (("hold", q.hold), ("merged", q.merged), ("pir", q.pir), ("cleaned", q.cleaned),
                            ("unit", q.unit), ("unaffected", q.unaff)) if v]
    return (life, " ".join(acts) or "-", " ".join(obs) or "-", " ".join(flags) or "-")

def explore(R, bound, census=None):
    seen = {}; frontier = []
    for s0 in inits():
        seen[s0] = None; frontier.append(s0)
        if census is not None:
            for q in s0.prs: census.add(shape(q))
        v = violated(s0)
        if v: return len(seen), 0, v, [("Init", s0)]
    depth = 0
    while frontier and depth < bound:
        nxt = []
        for st in frontier:
            for name, st2 in actions(st, R):
                if st2 in seen: continue
                seen[st2] = (st, name)
                if census is not None:
                    for q in st2.prs: census.add(shape(q))
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

def random_walks(R, bound, walks, length):
    try:
        from hypothesis import given, settings, strategies as hst, HealthCheck
    except ImportError:
        return None
    found = {}
    @settings(max_examples=walks, deadline=None, database=None, suppress_health_check=list(HealthCheck))
    @given(hst.lists(hst.integers(min_value=0, max_value=10**6), min_size=bound + 1, max_size=length))
    def walk(choices):
        st = next(iter(inits())); trace = [("Init", st)]
        for c in choices:
            opts = list(actions(st, R))
            if not opts: break
            name, st = opts[c % len(opts)]; trace.append((name, st))
            v = violated(st)
            if v and "hit" not in found:
                found["hit"] = (v, trace); raise AssertionError(v)
    try: walk()
    except AssertionError: pass
    return walks, found.get("hit", (None, []))[0]

def show(q):
    return (f"cls={sorted(q.cls)} life={sorted(q.life)} draft={q.draft} book={q.booking} berth={q.berth} "
            f"sdep={q.sdep} shealthy={q.shealthy} hold={q.hold} prod={q.prod} pdep={q.pdep} v={q.verdict} "
            f"uat={q.uat} healthy={q.healthy} merged={q.merged} pir={q.pir} closed={q.closed} unit={q.unit} unaff={q.unaff}")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--disable", action="append", default=[], choices=RULES)
    ap.add_argument("--bound", type=int, default=10, help="exhaustive BFS depth")
    ap.add_argument("--walks", type=int, default=100)
    ap.add_argument("--length", type=int, default=40)
    ap.add_argument("--census", action="store_true", help="print every distinct per-change shape reached")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()
    R = {r: r not in a.disable for r in RULES}
    say = (lambda *x: None) if a.quiet else print
    say(f"  rules off: {[r for r in RULES if not R[r]] or 'none'}")
    census = set() if a.census else None
    n, d, v, trace = explore(R, a.bound, census)
    if v:
        say(f"  exhaustive: VIOLATION {v} at depth {d} after {n} states")
        for act, st in trace[-min(len(trace), 8):]:
            say(f"    {act:<24} {' | '.join(show(q) for q in st.prs)} freeze={st.freeze} emg={st.emg}")
        print(f"VERDICT violated {v}"); return 1
    say(f"  exhaustive: {n} states, depth {d}, "
        f"{'state space exhausted' if trace == [] else f'bound {a.bound} reached, not exhausted'}, no violation")
    if a.census:
        say(f"\n  {len(census)} distinct per-change shapes reached within the bound:")
        say(f"  {'lifecycle':<20} {'actions':<62} {'observations':<58} flags")
        for row in sorted(census):
            say(f"  {row[0]:<20} {row[1]:<62} {row[2]:<58} {row[3]}")
    if a.walks == 0:
        say("  property: walks disabled (--walks 0)")
    else:
        rw = random_walks(R, a.bound, a.walks, a.length)
        if rw is None: say("  property: hypothesis not installed -- walks past the bound skipped")
        elif rw[1]: say(f"  property: VIOLATION {rw[1]} on a walk past the bound"); print(f"VERDICT violated {rw[1]}"); return 1
        else: say(f"  property: {rw[0]} walks of up to {a.length} steps past depth {a.bound}, no violation")
    print("VERDICT holds"); return 0

if __name__ == "__main__":
    sys.exit(main())
