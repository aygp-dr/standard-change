#!/usr/bin/env python3
"""label_sim.py -- an explicit-state checker for the label semantics AS THEY ARE.

Not a model of what the pipeline should do. A transition relation transcribed
from the scripts that actually run, so that a combination nobody intended shows
up as a reachable state with a trace rather than as an incident.

  gates/preflight.sh        the blockers, the class conflict, the exemption
  change/queue.sh           guards 0 and 1
  change/guard4.sh          the authorization stack
  change/settle.sh          change:complete, the merge, the cleanup
  change/observe.sh         the one human observation
  .github/labeller.yml      derivation of app:*, control-plane, itil:{standard,normal}
  change/label-owners.tsv   the declaration: owners, persistence, exclusion groups

THREE INDEPENDENT AXES, and conflating any two is the defect this repo keeps
finding:

  class      itil:standard | itil:normal | itil:emergency    what kind of change
  lifecycle  change:requested -> :scheduled -> :complete      where the record is
  scope      app:* | control-plane                            derived from the diff

and a FOURTH thing that is not an axis of the change at all:

  estate     freeze, a berth held, an emergency in flight

The estate axis is the one with no namespace. `freeze` is a bare label with no
row in the declaration; "an emergency is in flight" is read off itil:emergency,
which is a classification. That is the subject of --question emergency.

BOTH DIRECTIONS, ALWAYS. An invariant that cannot change truth value under any
edit to the rules is an invariant this checker does not verify -- the
gate-selftest rule applied to a model. So every invariant here is wired to
either a MUTATION that must break it or a REPAIR that must fix it, and
--selftest fails if any of them does neither.

USAGE
  ./sim/label_sim.py                        baseline: explore and report findings
  ./sim/label_sim.py --selftest             the negative test, both directions
  ./sim/label_sim.py --mutate NAME          inject one defect
  ./sim/label_sim.py --repair NAME          apply one proposed fix
  ./sim/label_sim.py --question emergency   the bare-`emergency` decision
  ./sim/label_sim.py --witness              emit the deciding state for TLC
  ./sim/label_sim.py --prs 3 --random 4000  property-based, where exhaustive
                                            will not fit
"""
from __future__ import annotations

import argparse
import itertools
import pathlib
import random
import sys
from collections import deque

ROOT = pathlib.Path(__file__).resolve().parent.parent
DECL = ROOT / "change" / "label-owners.tsv"

# --------------------------------------------------------------------------
# THE DECLARATION. Read, never assumed -- if a row moves, this moves with it.
# --------------------------------------------------------------------------


def declaration():
    labels, groups = {}, {}
    for line in DECL.read_text().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        f = line.split("\t")
        if f[0] == "exclusive" and len(f) >= 5:
            groups[f[1]] = {"members": set(f[2].split()), "cardinality": f[3]}
        elif len(f) >= 6:
            labels[f[0]] = {"owner": f[1], "persistent": f[2] == "yes",
                            "human_add": f[3] == "yes", "human_rm": f[4] == "yes"}
    return labels, groups


# --------------------------------------------------------------------------
# STATE
# --------------------------------------------------------------------------

CLS = ("S", "N", "E")          # itil:standard | itil:normal | itil:emergency
LIFE = ("R", "C", "X")         # change:requested | :scheduled | :complete
SCOPES = ("app", "cp", "inert")

# The evidence ladder. EV_FAIL is a recorded staging:*-failed, which outranks
# its pass -- docs/label-ownership.org rule 4.
EV_FAIL, EV_NONE, EV_E2E, EV_SMOKE, EV_UAT = -1, 0, 1, 2, 3

PR_FIELDS = (
    "scope",    # 'app' | 'cp' | 'inert'   derived from the diff, fixed
    "cls",      # frozenset over CLS. A SET, because nothing enforces <=1: the
                # labeller derives S or N and a person declares E, and the two
                # writers never meet. #2 carried two at once.
    "life",     # frozenset over LIFE. Also a set, and for the same reason.
    "gated",    # gates green on THIS head
    "berth",    # deploy:staging -- the berth claim guard 1 reads
    "ev",       # the evidence ladder above
    "evsha",    # does the evidence name the current head? (guard 4, issue #16)
    "inprod",   # production has CONVERGED on this build
    "hold",     # hold:staging -- the only human stop
    "frz",      # the bare `freeze` label. UNDECLARED; preflight reads it anyway
    "emgest",   # a bare `emergency` label. DOES NOT EXIST TODAY: under the
                # as-is rules it is written by the same act that writes cls|{E}
    "merged",
)

# BOUNDED, AND SAID SO. Every human action here is reversible -- declare and
# withdraw, freeze and thaw, hold and release, push -- so the reachable set is
# unbounded in practice while every finding in it is reachable in two or three.
# Machine actions are free; HUMAN INTERVENTIONS carry a budget in the state.
# The claim is therefore "exhaustive up to K human interventions", which is a
# real claim, is printed with every result, and is the same kind of bound
# MaxMerges puts on the TLA+ specs.
BUDGET = 3
MAXMERGES = 2


def mkpr(scope):
    return (scope, frozenset(), frozenset(), False, False, EV_NONE, True,
            False, False, False, False, False)


IDX = {f: i for i, f in enumerate(PR_FIELDS)}


def pr_set(pr, **kw):
    d = list(pr)
    for k, v in kw.items():
        d[IDX[k]] = v
    return tuple(d)


def pr_get(pr, f):
    return pr[IDX[f]]


class State(tuple):
    """(prs, mainv, hist, budget).

    `hist` is a set of breach records. Several of the properties here are about
    the ORDER things happened in -- a hold added after a deploy is not a hold
    that was bypassed -- and a state alone cannot say that. So the transition
    that commits the breach records it, exactly as `regressed` is recorded in
    StandardChange.tla."""

    __slots__ = ()
    prs = property(lambda s: s[0])
    mainv = property(lambda s: s[1])
    hist = property(lambda s: s[2])
    budget = property(lambda s: s[3])


def mkstate(prs, mainv=0, hist=frozenset(), budget=BUDGET):
    return State((tuple(prs), mainv, frozenset(hist), budget))


# --------------------------------------------------------------------------
# MUTATIONS and REPAIRS -- the two directions.
#
# tla/check.sh flips Guard4b to FALSE and requires TLC to find the D4 trace.
# These are the same device, in both directions: a MUTATION removes a rule the
# scripts have and must break something; a REPAIR adds a rule they do not have
# and must fix something.
# --------------------------------------------------------------------------

MUTATIONS = {
    "none": "baseline -- the rules as the scripts have them today",
    "no-class-conflict": "preflight stops refusing a PR carrying two classes",
    "no-freeze": "preflight stops reading the `freeze` label",
    "no-emergency-block": "preflight stops blocking on an emergency in flight",
    "no-berth-mutex": "guard 1 stops refusing a second berth claim",
    "label-authorizes": "guard 4 authorizes from the label, not the record (pre-#16)",
    "no-hold": "guard 4c stops reading hold:staging",
    "no-uat": "guard 4 stops requiring the human observation",
}

REPAIRS = {
    "none": "the rules as they are",
    "estate-emergency": "a bare `emergency` label, separate from the itil:* class",
    "lifecycle-replaces": "a lifecycle transition REPLACES the previous state\n"
                          "                      instead of accumulating alongside it",
    "class-required": "preflight refuses a change carrying NO class, not just two",
    "class-exclusive": "declaring an emergency RETIRES the labeller's derived class,\n"
                       "                      so the declared cardinality is enforced and not merely stated",
    "soak": "a control-plane change is not counted proven at its own merge",
    "emergency-preempts": "an emergency is exempt from the berth check too, not\n"
                          "                      only from the checks that run after it",
    "declare-estate-labels": "`freeze` and `emergency` get rows in the declaration",
    "complete-is-transient": "the declaration stops calling change:complete persistent",
}

EMERGENCY_READINGS = ("class", "estate")


class Rules:
    """The rules as the scripts have them, plus one mutation and one repair."""

    def __init__(self, mutate="none", repair="none"):
        self.m = mutate
        self.r = repair

    @property
    def emergency_reading(self):
        # THE QUESTION, in one line. Today the estate fact is read off a
        # classification; the repair reads it off a label of its own.
        return "estate" if self.r == "estate-emergency" else "class"

    # -- the estate ---------------------------------------------------------
    def frozen(self, st):
        """preflight:  gh pr list --state open --label freeze

        Does NOT exclude self, and `freeze` has no row in the declaration."""
        if self.m == "no-freeze":
            return False
        return any(pr_get(p, "frz") and not pr_get(p, "merged") for p in st.prs)

    def emergency_in_flight(self, st, me):
        """preflight:  gh pr list --label itil:emergency, minus self.

        THE WHOLE QUESTION IS THIS FUNCTION."""
        if self.m == "no-emergency-block":
            return False
        estate = self.emergency_reading == "estate"
        for i, p in enumerate(st.prs):
            if i == me or pr_get(p, "merged"):
                continue
            if pr_get(p, "emgest") if estate else ("E" in pr_get(p, "cls")):
                return True
        return False

    def estate_blocked(self, st, me):
        return self.frozen(st) or self.emergency_in_flight(st, me)

    def exempt(self, st, i):
        """preflight: `this is itil:emergency -- the freeze and queue rules do
        not apply to it`.

        Read off the CLASS, always, and that is correct: the exemption is about
        what kind of change this is. What is wrong today is that the write
        granting this exemption is the same write that declares the estate
        blocked."""
        return "E" in pr_get(st.prs[i], "cls")

    def berth_holder(self, st, me):
        for i, p in enumerate(st.prs):
            if i != me and not pr_get(p, "merged") and pr_get(p, "berth"):
                return i
        return None

    # -- gates/preflight.sh, in preflight's own order -----------------------
    def preflight(self, st, i):
        """(exit, reason); 0 proceeds.

        The ORDER is preflight's order, because the order is load-bearing: the
        berth check comes BEFORE the estate check and carries no emergency
        exemption."""
        p = st.prs[i]
        if pr_get(p, "merged"):
            return 7, "already merged"
        rc, why = 0, "proceed"
        cls = pr_get(p, "cls")
        # the class conflict: sets rc and keeps going, as the real script does
        if self.m != "no-class-conflict" and "E" in cls and (cls & {"S", "N"}):
            rc, why = 2, "two classes: %s" % sorted(cls)
        if self.r == "class-required" and not cls:
            return 2, "no class at all; every rule below branches on the class"
        if "C" not in pr_get(p, "life"):
            return 4, "not on the calendar -- no open window covers now"
        if not pr_get(p, "gated"):
            return 1, "the gates are not green on this head"
        # NO EMERGENCY EXEMPTION HERE, and it is checked BEFORE the estate.
        # preflight's own comment says "the freeze and QUEUE rules do not apply"
        # to an emergency -- but the queue rule it means is the estate check
        # below, and this berth check, which is also a queue rule, already ran.
        # An emergency therefore waits on an ordinary change's berth while that
        # ordinary change waits on the emergency. Neither moves.
        #
        # This also duplicates change/queue.sh's guard 1. Two sites, one rule,
        # so `no-berth-mutex` has to remove both -- neutering one leaves the
        # other standing and the mutation is invisible.
        h = self.berth_holder(st, i)
        preempts = self.r == "emergency-preempts" and self.exempt(st, i)
        if h is not None and self.m != "no-berth-mutex" and not preempts:
            return 5, "the berth is held by pr%d" % h
        if self.exempt(st, i):
            pass                    # the freeze and queue rules do not apply
        elif self.frozen(st):
            return 3, "a deployment freeze is in force"
        elif self.emergency_in_flight(st, i):
            return 2, "an emergency is in flight"
        if pr_get(p, "hold") and self.m != "no-hold":
            return 2, "hold:staging -- a person is holding this"
        return rc, why

    # -- change/queue.sh: guards 0 and 1 ------------------------------------
    def queue_claim(self, st, i):
        p = st.prs[i]
        if self.r == "emergency-preempts" and self.exempt(st, i):
            return 0, "the emergency preempts the berth"
        if self.m != "no-berth-mutex" and self.berth_holder(st, i) is not None:
            return 5, "staging is held"
        return 0, "claimed"

    # -- change/guard4.sh: the authorization stack --------------------------
    def guard4(self, st, i):
        p = st.prs[i]
        ev = pr_get(p, "ev")
        floor = EV_SMOKE if self.m == "no-uat" else EV_UAT
        if ev == EV_FAIL:
            return 1, "a recorded failure has not been withdrawn"
        if ev < floor:
            return 1, "the authorization stack is incomplete"
        # issue #16: the observation must name THIS build. `label-authorizes`
        # is the frozen pre-#16 guard -- it reads the durable label instead.
        if not pr_get(p, "evsha") and self.m != "label-authorizes":
            return 1, "that observation is about a different build"
        if pr_get(p, "hold") and self.m != "no-hold":
            return 1, "a person is holding this change"
        if not pr_get(p, "gated"):
            return 1, "the gates are not green"
        return 0, "authorized"

    def may_settle(self, st, i):
        p = st.prs[i]
        return pr_get(p, "inprod") and pr_get(p, "ev") >= EV_UAT

    def may_merge(self, st, i):
        """docs/changing-the-pipeline.org: a control-plane change is proven by
        USE, across N subsequent deployments, not by its own merge. Nothing in
        the repo implements this, so without the repair it merges."""
        if self.r == "soak" and pr_get(st.prs[i], "scope") == "cp":
            return False
        return True

    def declared(self, decl, label):
        if self.r == "declare-estate-labels" and label in ("freeze", "emergency"):
            return True
        return label in decl[0]

    def persistent(self, decl, label):
        if self.r == "complete-is-transient" and label == "change:complete":
            return False
        row = decl[0].get(label)
        return bool(row and row["persistent"])


# --------------------------------------------------------------------------
# TRANSITIONS. Each is named for the thing that performs it, because who writes
# a label is part of what the label means -- that is the declaration's premise.
# --------------------------------------------------------------------------


TRUTH = None          # set below, once Rules exists: the unmutated rules


def breaches(rules, st, i, what):
    """What is wrong about THIS step, recorded now because the state it happens
    in does not survive."""
    p, out = st.prs[i], set()
    # An ORDINARY change -- one not classified an emergency -- moving while the
    # estate is closed. ADR 0001 S8. preflight refuses this today, so it appears
    # only under mutation, which is what makes S8 a verified rule rather than a
    # documented intention.
    #
    # NOTE THE `TRUTH` RULES. The estate's state is asked of an UNMUTATED copy
    # of the rules, never of the rules under test. The first version asked
    # `rules`, so the `no-freeze` mutation removed the block and, with it, the
    # ability to notice the block had been removed -- the mutant graded itself
    # and every mutation "changed nothing". It is guard 5's defect exactly: if
    # the thing being checked supplies the evidence, there is no check.
    if TRUTH.estate_blocked(st, i) and not TRUTH.exempt(st, i):
        out.add(("underblock", i))
    if len(pr_get(p, "cls")) > 1:
        out.add(("twoclass", i))
    if what == "prod":
        if pr_get(p, "hold"):
            out.add(("held", i))
        if not pr_get(p, "evsha"):
            out.add(("stale", i))
        if not pr_get(p, "cls"):
            out.add(("unclassified", i))
        if pr_get(p, "ev") < EV_UAT:
            out.add(("nouat", i))
    return out


def self_grant(rules, st, i, nxt):
    """THE DECISIVE CHECK, and it is about an ACTION rather than a state.

    Did this one human write BOTH close the estate to everybody else AND move
    its own PR from non-exempt to exempt? If a single act can do both, the
    carrier of the declaration is the remedy for it by construction -- whatever
    the change actually contains -- and no scoping of the query can separate
    them, because both readings read the same PR's own label set."""
    others = [j for j in range(len(st.prs)) if j != i]
    if not others:
        return set()
    blocked_before = any(rules.estate_blocked(st, j) for j in others)
    blocked_after = any(rules.estate_blocked(nxt, j) for j in others)
    exempt_before = rules.exempt(st, i)
    exempt_after = rules.exempt(nxt, i)
    if (not blocked_before and blocked_after) and (not exempt_before and exempt_after):
        return {("selfgrant", i)}
    return set()


def successors(rules, st):
    n = len(st.prs)
    estate_label = rules.emergency_reading == "estate"
    for i in range(n):
        p = st.prs[i]
        scope, cls, life = pr_get(p, "scope"), pr_get(p, "cls"), pr_get(p, "life")

        def upd(cost=0, **kw):
            prs = list(st.prs)
            prs[i] = pr_set(p, **kw)
            return mkstate(prs, st.mainv, st.hist, st.budget - cost)

        # ---- after the merge, one thing still happens ----------------------
        if pr_get(p, "merged"):
            # settle.sh's cleanup clears change:complete once the forge records
            # MERGED. The declaration calls that label persistent and "Never
            # cleared"; the script clears it. They cannot both be right.
            if "X" in life:
                yield ("change/settle.sh cleanup pr%d" % i, upd(life=frozenset()))
            continue

        spend = st.budget > 0

        # ---- the labeller, on every push. Derived; owner = labeller --------
        # is_normal wins over has_app, and NEITHER matches an inert diff -- the
        # classify step then leaves the class alone, so an inert change carries
        # no class at all.
        want = {"app": {"S"}, "cp": {"N"}, "inert": set()}[scope]
        if rules.r == "class-exclusive" and "E" in cls:
            want = set()      # a person has declared this; the labeller stands off
        derived = frozenset(want) | (cls & {"E"})
        if derived != cls:
            yield ("labeller/derive-class pr%d" % i, upd(cls=derived))

        # ---- the gates ------------------------------------------------------
        if not pr_get(p, "gated"):
            yield ("gates/run pr%d" % i, upd(gated=True))

        # ---- the author pushes. Every observation is about a BUILD, so a push
        #      makes all of them about a build nobody is proposing to merge.
        if spend and (pr_get(p, "ev") != EV_NONE or pr_get(p, "gated")):
            yield ("author/push pr%d" % i,
                   upd(1, gated=False, evsha=False, inprod=False))

        # ---- decision 1: ASK. human_add only (docs/control-path.org) -------
        if not life:
            yield ("human/change:requested pr%d" % i, upd(life=frozenset({"R"})))
        # ---- decision 2: TAKE A SLOT. owner = scheduler --------------------
        if "R" in life and "C" not in life:
            # NOTE WHAT IS NOT HERE. Nothing removes change:requested. The
            # declaration says "the pipeline clears it", and the only thing that
            # does is settle.sh's cleanup, at the very end. So the two lifecycle
            # labels coexist for the whole life of the change, and the group
            # says "<=1 active".
            nxt = life | {"C"}
            if rules.r == "lifecycle-replaces":
                nxt = frozenset({"C"})
            yield ("scheduler/change:scheduled pr%d" % i, upd(life=nxt))

        if spend:
            # ---- a person declares an emergency. human_add AND human_rm -----
            #
            # EVERY declaration is checked for the self-grant: did this one
            # write close the estate to everyone else AND exempt its own PR?
            def newcls(c):
                # The repair: declaring an emergency RETIRES the derived class,
                # so the group's cardinality is enforced rather than stated.
                return frozenset({"E"}) if rules.r == "class-exclusive" else c | {"E"}

            def declare(label, nxt):
                return (label, mkstate(nxt.prs, nxt.mainv,
                                       nxt.hist | self_grant(rules, st, i, nxt),
                                       nxt.budget))
            if "E" not in cls:
                if estate_label:
                    # TWO ACTS, because they are two facts about two subjects.
                    yield declare("human/itil:emergency (class) pr%d" % i,
                                  upd(1, cls=newcls(cls)))
                    if not pr_get(p, "emgest"):
                        yield declare("human/emergency (estate) pr%d" % i,
                                      upd(1, emgest=True))
                else:
                    # ONE LABEL. Declaring the estate blocked and classifying
                    # this change are THE SAME WRITE and cannot be done apart.
                    yield declare("human/itil:emergency pr%d" % i,
                                  upd(1, cls=newcls(cls), emgest=True))
            else:
                yield ("human/withdraw itil:emergency pr%d" % i,
                       upd(1, cls=cls - {"E"},
                           emgest=pr_get(p, "emgest") if estate_label else False))
            if estate_label and pr_get(p, "emgest"):
                yield ("human/withdraw emergency (estate) pr%d" % i,
                       upd(1, emgest=False))

            # ---- a person declares a freeze. No owner row exists for this. ---
            yield (("human/thaw pr%d" if pr_get(p, "frz") else "human/freeze pr%d") % i,
                   upd(1, frz=not pr_get(p, "frz")))
            # ---- a person holds ---------------------------------------------
            yield (("human/release-hold pr%d" if pr_get(p, "hold")
                    else "human/hold:staging pr%d") % i,
                   upd(1, hold=not pr_get(p, "hold")))

        # ---- claim the berth: preflight, then queue.sh ----------------------
        if not pr_get(p, "berth"):
            if rules.preflight(st, i)[0] == 0 and rules.queue_claim(st, i)[0] == 0:
                prs = list(st.prs)
                # PREEMPTION IS EVICTION, not sharing. An emergency that has to
                # wait for the berth is the defect; one that silently doubles up
                # in it is a worse one. The evicted change must be told, which
                # is what blocked:queue exists for.
                if rules.r == "emergency-preempts" and rules.exempt(st, i):
                    for j in range(n):
                        if j != i:
                            prs[j] = pr_set(prs[j], berth=False)
                prs[i] = pr_set(p, berth=True)
                yield ("workflow/deploy:staging pr%d" % i,
                       mkstate(prs, st.mainv,
                               st.hist | breaches(rules, st, i, "berth"),
                               st.budget))

        # ---- the instruments -------------------------------------------------
        if pr_get(p, "berth") and pr_get(p, "gated"):
            ev = pr_get(p, "ev")
            if ev in (EV_NONE, EV_FAIL):
                yield ("gates/e2e.sh --pr pr%d" % i, upd(ev=EV_E2E, evsha=True))
                yield ("gates/e2e.sh --pr FAILED pr%d" % i, upd(ev=EV_FAIL, evsha=True))
            elif ev == EV_E2E:
                yield ("gates/smoke.sh --pr pr%d" % i, upd(ev=EV_SMOKE, evsha=True))
            elif ev == EV_SMOKE:
                # the one human observation; observe.sh checks the build matches
                yield ("human/observe.sh uat pr%d" % i, upd(ev=EV_UAT, evsha=True))

        # ---- production -------------------------------------------------------
        if not pr_get(p, "inprod"):
            if rules.guard4(st, i)[0] == 0 and rules.preflight(st, i)[0] == 0:
                prs = list(st.prs)
                prs[i] = pr_set(p, inprod=True)
                yield ("targets/deploy.sh production pr%d" % i,
                       mkstate(prs, st.mainv,
                               st.hist | breaches(rules, st, i, "prod"),
                               st.budget))

        # ---- settle: change:complete is set BEFORE the merge -----------------
        if rules.may_settle(st, i) and "X" not in life:
            # settle.sh adds change:complete. It does not remove
            # change:scheduled -- nothing does, until the cleanup at the very
            # end -- so this is the SECOND place the lifecycle accumulates.
            nxt = life | {"X"}
            if rules.r == "lifecycle-replaces":
                nxt = frozenset({"X"})
            yield ("change/settle.sh change:complete pr%d" % i, upd(life=nxt))
        # ---- the merge ---------------------------------------------------------
        if "X" in life and st.mainv < MAXMERGES and rules.may_merge(st, i):
            prs = list(st.prs)
            prs[i] = pr_set(p, merged=True, berth=False)
            yield ("change/settle.sh merge pr%d" % i,
                   mkstate(prs, st.mainv + 1, st.hist, st.budget))


TRUTH = Rules()       # the oracle. Independent of whatever is under test.


# --------------------------------------------------------------------------
# INVARIANTS. Each returns None, or a one-line statement of what is wrong.
# --------------------------------------------------------------------------


def _h(st, kind):
    return sorted(i for k, i in st.hist if k == kind)


def inv_class_at_most_one(rules, st, decl):
    """change/label-owners.tsv, exclusion group `class`, cardinality <=1.

    Stated over the LABEL SET, because that is what the declaration is about.
    This is where this file and tla/Labels.tla first disagreed: the module
    stated it this way and found it violated, while this file stated it over
    preflight's verdict and found it holding, because preflight refuses such a
    PR. Both are true and they are DIFFERENT PROPERTIES -- the declared
    cardinality really is violated (#2), and the refusal below is what stops
    that from changing any verdict. The module was right; the weaker statement
    here was hiding the finding."""
    for i, p in enumerate(st.prs):
        if pr_get(p, "merged"):
            continue
        if len(pr_get(p, "cls")) > 1:
            return ("pr%d holds %s -- two members of exclusion group 'class'. "
                    "The labeller derives S or N from the diff and a person "
                    "declares E; nothing reconciles them, so the declared "
                    "cardinality is not enforced anywhere (#2)."
                    % (i, sorted(pr_get(p, "cls"))))
    return None


def inv_no_undefined_class_moves(rules, st, decl):
    """And the mitigation: a change whose class is undefined never moves.
    preflight refuses it, which is why the unenforced cardinality above has
    never changed a verdict."""
    bad = _h(st, "twoclass")
    if bad:
        return ("pr%s moved -- berth or production -- carrying two classes, so "
                "every rule that branches on the class branched on an undefined "
                "value" % bad)
    return None


def inv_lifecycle_at_most_one_active(rules, st, decl):
    """group `lifecycle`, cardinality '<=1 active'."""
    for i, p in enumerate(st.prs):
        if pr_get(p, "merged"):
            continue
        if len(pr_get(p, "life")) > 1:
            return ("pr%d holds %s -- two ACTIVE lifecycle states; the group "
                    "says at most one and nothing clears change:requested until "
                    "settle.sh's cleanup" % (i, sorted(pr_get(p, "life"))))
    return None


def inv_classified_before_deploy(rules, st, decl):
    """Every rule in preflight branches on the class. A change with NO class
    satisfies all of them by falling through, and the declaration permits it:
    the group's cardinality is <=1, not ==1."""
    bad = _h(st, "unclassified")
    if bad:
        return ("pr%s reached production carrying NO class label; every rule in "
                "preflight branches on the class and it fell through all of them"
                % bad)
    return None


def inv_berth_singleton(rules, st, decl):
    held = [i for i, p in enumerate(st.prs)
            if pr_get(p, "berth") and not pr_get(p, "merged")]
    if len(held) > 1:
        return "guard 1: prs %s all hold deploy:staging" % held
    return None


def inv_ordinary_change_waits(rules, st, decl):
    """ADR 0001 S8: a standard or normal change does not progress while either a
    freeze is declared or an emergency is in flight. One rule, two causes, one
    exemption. Recorded at the step, because by the time you look the
    declaration may have been withdrawn."""
    bad = _h(st, "underblock")
    if bad:
        return ("pr%s moved -- berth or production -- while the estate was "
                "closed, carrying no emergency classification" % bad)
    return None


def inv_declaring_a_block_does_not_exempt_the_declarer(rules, st, decl):
    """THE ONE THE QUESTION TURNS ON, and it is about an ACTION.

    `itil:emergency` names two facts about two subjects: that THIS change is
    classified an emergency, and that AN emergency is in flight. One label means
    one write asserts both -- so the act of closing the estate is the act of
    exempting its own carrier from the closure."""
    bad = _h(st, "selfgrant")
    if bad:
        return ("one human write closed the estate to every other change AND "
                "moved pr%s from blocked to exempt. The carrier of the "
                "declaration is the remedy for it by construction, whatever the "
                "change actually contains." % bad)
    return None


def inv_no_stale_authorization(rules, st, decl):
    bad = _h(st, "stale")
    if bad:
        return ("pr%s reached production authorized by an observation about a "
                "different build (issue #16)" % bad)
    return None


def inv_hold_is_a_hold(rules, st, decl):
    bad = _h(st, "held")
    if bad:
        return "pr%s reached production while carrying hold:staging" % bad
    return None


def inv_uat_before_production(rules, st, decl):
    bad = _h(st, "nouat")
    if bad:
        return "pr%s reached production below the uat rung of the stack" % bad
    return None


def inv_emergency_never_waits(rules, st, decl):
    """ADR 0001 S8 says an emergency proceeds: "an emergency is what a freeze is
    FOR; blocking it would mean the freeze prevents its own remedy."

    preflight checks the berth BEFORE it checks the estate, and the berth check
    carries no exemption. So an emergency waits on an ordinary change's berth,
    while that ordinary change is refused with exit 2 for the emergency being in
    flight. Nothing releases the berth: deploy:staging is owned by the workflow
    and is cleared by change/settle.sh, which that change can never reach."""
    for i, p in enumerate(st.prs):
        if pr_get(p, "merged") or "E" not in pr_get(p, "cls"):
            continue
        if rules.preflight(st, i)[0] != 5:
            continue
        h = rules.berth_holder(st, i)
        if h is None:
            continue
        if "E" in pr_get(st.prs[h], "cls"):
            continue                      # two emergencies is a different case
        if rules.preflight(st, h)[0] == 2:
            return ("pr%d is an emergency refused with exit 5 for pr%d's berth, "
                    "and pr%d is refused with exit 2 because pr%d is an emergency "
                    "in flight. Neither can move and nothing else clears "
                    "deploy:staging." % (i, h, h, i))
    return None


def inv_control_plane_soaks(rules, st, decl):
    """docs/changing-the-pipeline.org: a pipeline change is proven by USE, over
    N subsequent deployments. Nothing implements it."""
    for i, p in enumerate(st.prs):
        if pr_get(p, "merged") and pr_get(p, "scope") == "cp" and rules.r != "soak":
            return ("pr%d is control-plane and merged, counted proven by its own "
                    "merge; the soak practice says it is not proven until later "
                    "changes have shipped through it" % i)
    return None


def inv_complete_is_persistent(rules, st, decl):
    """The declaration marks change:complete persistent and says "Never
    cleared". change/settle.sh clears it, and the exclusion-group note in the
    same file says it is cleared at cleanup. The file contradicts itself."""
    if not rules.persistent(decl, "change:complete"):
        return None
    for i, p in enumerate(st.prs):
        if pr_get(p, "merged") and "X" not in pr_get(p, "life"):
            return ("pr%d merged and change:complete is gone, but the declaration "
                    "marks it persistent and says 'Never cleared' -- while the "
                    "same file's lifecycle group says it is cleared at cleanup"
                    % i)
    return None


def inv_every_label_declared(rules, st, decl):
    """gates/label-audit.py enforces the declaration against every label WRITE.
    It cannot see a label that is only ever READ."""
    for i, p in enumerate(st.prs):
        if pr_get(p, "frz") and not rules.declared(decl, "freeze"):
            return ("pr%d carries `freeze`, which gates/preflight.sh reads and "
                    "the declaration does not list -- the label has no owner, "
                    "which is the exact condition docs/label-ownership.org "
                    "exists for. (`blocked:freeze` IS declared, owned by "
                    "preflight, and nothing writes it.)" % i)
        if (pr_get(p, "emgest") and rules.emergency_reading == "estate"
                and not rules.declared(decl, "emergency")):
            return "pr%d carries a bare `emergency`, which is not declared" % i
    return None


INVARIANTS = {
    "ClassAtMostOne": inv_class_at_most_one,
    "NoUndefinedClassMoves": inv_no_undefined_class_moves,
    "LifecycleAtMostOneActive": inv_lifecycle_at_most_one_active,
    "ClassifiedBeforeDeploy": inv_classified_before_deploy,
    "BerthSingleton": inv_berth_singleton,
    "OrdinaryChangeWaits": inv_ordinary_change_waits,
    "DeclaringABlockDoesNotExempt": inv_declaring_a_block_does_not_exempt_the_declarer,
    "NoStaleAuthorization": inv_no_stale_authorization,
    "HoldIsAHold": inv_hold_is_a_hold,
    "UatBeforeProduction": inv_uat_before_production,
    "EmergencyNeverWaits": inv_emergency_never_waits,
    "ControlPlaneSoaks": inv_control_plane_soaks,
    "CompleteIsPersistent": inv_complete_is_persistent,
    "EveryLabelDeclared": inv_every_label_declared,
}

# THE NEGATIVE TEST, forwards: remove a rule the scripts have; the invariant it
# implements must go from holding to violated. If it does not, that invariant
# is not verifying the rule and says nothing when it is green.
NEGATIVES = {
    "no-freeze": "OrdinaryChangeWaits",
    "no-emergency-block": "OrdinaryChangeWaits",
    "no-class-conflict": "NoUndefinedClassMoves",
    "no-berth-mutex": "BerthSingleton",
    "label-authorizes": "NoStaleAuthorization",
    "no-hold": "HoldIsAHold",
    "no-uat": "UatBeforeProduction",
}

# THE NEGATIVE TEST, backwards: for the findings that are already true of the
# repository, apply the proposed fix; the invariant must go from violated to
# holding. A finding whose fix changes nothing is a finding that was misdiagnosed.
REPAIR_TESTS = {
    "estate-emergency": "DeclaringABlockDoesNotExempt",
    "lifecycle-replaces": "LifecycleAtMostOneActive",
    "class-required": "ClassifiedBeforeDeploy",
    "class-exclusive": "ClassAtMostOne",
    "soak": "ControlPlaneSoaks",
    "emergency-preempts": "EmergencyNeverWaits",
    "declare-estate-labels": "EveryLabelDeclared",
    "complete-is-transient": "CompleteIsPersistent",
}

# What is true of this repository today, confirmed by hand against the scripts.
# The baseline is green iff the violated set is exactly this: a new violation is
# a regression, a missing one is a fix and should shrink this list.
KNOWN = {
    "ClassAtMostOne",
    "LifecycleAtMostOneActive",
    "ClassifiedBeforeDeploy",
    "DeclaringABlockDoesNotExempt",
    "EmergencyNeverWaits",
    "ControlPlaneSoaks",
    "CompleteIsPersistent",
    "EveryLabelDeclared",
}


# --------------------------------------------------------------------------
# THE SEARCH
# --------------------------------------------------------------------------


def canon(st):
    """Symmetry reduction. Nothing in the rules reads a PR number, so a state
    and its permutation are the same state -- and the breach records must be
    permuted with it."""
    order = sorted(range(len(st.prs)), key=lambda i: repr(st.prs[i]))
    pos = {p: j for j, p in enumerate(order)}
    return (tuple(st.prs[i] for i in order), st.mainv,
            frozenset((k, pos[i]) for k, i in st.hist), st.budget)


def sweep(rules, decl, nprs=2, cap=4_000_000, budget=BUDGET):
    """EXHAUSTIVE over one shared visited set.

    Every assignment of scope (what the diff touched) and remedy-truth (does
    this change actually fix the emergency) is an initial state, explored in one
    search -- the shape of a TLA+ Init that picks nondeterministically from a
    set. Sharing the visited set across them is what makes it fit."""
    seen, q = {}, deque()
    for scopes in itertools.product(SCOPES, repeat=nprs):
        s0 = mkstate([mkpr(sc) for sc in scopes], budget=budget)
        k = canon(s0)
        if k not in seen:
            seen[k] = None
            q.append(s0)
    violations, n, truncated = {}, 0, False
    while q:
        st = q.popleft()
        n += 1
        for name, fn in INVARIANTS.items():
            if name in violations:
                continue
            msg = fn(rules, st, decl)
            if msg:
                violations[name] = (msg, trace(seen, st))
        if len(seen) >= cap:
            truncated = True
            break
        for action, nxt in successors(rules, st):
            k = canon(nxt)
            if k not in seen:
                seen[k] = (canon(st), action)
                q.append(nxt)
    return n, violations, truncated


def trace(seen, st):
    out, k, guard = [], canon(st), 0
    while seen.get(k) and guard < 64:
        parent, action = seen[k]
        out.append(action)
        k = parent
        guard += 1
    return list(reversed(out))


def random_walk(rules, decl, nprs, walks, seed):
    """Property-based, for PR counts where the product will not fit. The bound
    moves from the state count to the walk count, and it is stated."""
    rng = random.Random(seed)
    viols, n = {}, 0
    for _ in range(walks):
        st = mkstate([mkpr(rng.choice(SCOPES)) for _ in range(nprs)],
                     budget=BUDGET + 2)
        path = []
        for _ in range(60):
            n += 1
            for name, fn in INVARIANTS.items():
                if name in viols:
                    continue
                msg = fn(rules, st, decl)
                if msg:
                    viols[name] = (msg, list(path))
            succ = list(successors(rules, st))
            if not succ:
                break
            action, st = rng.choice(succ)
            path.append(action)
    return n, viols, False


# --------------------------------------------------------------------------
# THE QUESTION
# --------------------------------------------------------------------------

QUESTION = """
  THE QUESTION:  does `itil:emergency` need splitting into two labels?

  It names two facts about two different subjects:

    (1)  this change is classified an emergency        a property of the PR
    (2)  an emergency is in flight                     a property of the ESTATE

  Under the rules as they stand there is one label, so ONE WRITE ASSERTS BOTH.
  gates/preflight.sh reads it twice, differently:

      is_emg = itil:emergency on THIS pr          ->  the EXEMPTION
      emg    = itil:emergency on any OTHER pr     ->  the BLOCK

  The two readings give different verdicts iff a single write can both close
  the estate to every other change and exempt its own carrier from the closure.
  Below is the search for one, in both readings. The property is about an
  ACTION rather than a state, because the question is not "is the estate
  closed" -- it is "who closed it, and what did closing it also do".
"""


def question(decl, budget):
    print(QUESTION)
    key = "DeclaringABlockDoesNotExempt"
    out = {}
    for repair in ("none", "estate-emergency"):
        rules = Rules("none", repair)
        n, v, trunc = sweep(rules, decl, 2, budget=budget)
        out[repair] = v
        print("  emergency read as a %-7s fact   %7d states   %s: %s"
              % (rules.emergency_reading, n, key,
                 "VIOLATED" if key in v else "holds"))
        if key in v:
            msg, tr = v[key]
            print("      %s" % msg)
            for s in tr:
                print("        %s" % s)
    print()
    a, b = key in out["none"], key in out["estate-emergency"]
    if a and not b:
        for line in VERDICT.strip("\n").splitlines():
            print("  " + line)
        return 0
    if a and b:
        print("  VERDICT: splitting the label does not fix it on its own; the")
        print("  bypass survives the split, so the defect is somewhere else.")
        return 1
    print("  VERDICT: one label suffices -- no reachable state distinguishes")
    print("  the two readings.")
    return 1


VERDICT = """
VERDICT: a bare `emergency` label IS necessary.

One label cannot carry both facts, and the reason is not that the readings are
confusable -- it is that THE WRITE THAT DECLARES THE ESTATE BLOCKED IS THE
WRITE THAT EXEMPTS ITS CARRIER FROM THE BLOCK. Adding itil:emergency to a PR
does two things at once and they point in opposite directions:

   for every OTHER open PR   the estate is closed; exit 2
   for THIS PR               "the freeze and queue rules do not apply to it"

So the carrier is the remedy by construction, whatever it actually contains.
No scoping of the query fixes this: both readings read the same PR's own label
set, and the exemption must be read off the class, because that is what the
exemption is about.

The consequence is sharpest where an emergency is being handled OUTSIDE the
pipeline -- a person fixing production by hand, which is the case the rule is
written for. There is no PR to classify. To declare the estate closed you must
hang itil:emergency on some open PR, and doing so hands that PR a bypass of
every blocker in preflight. The one change that must not proceed becomes the
only one that may.

`freeze` already has exactly the shape needed: a bare estate-level label, on
any open PR, blocking everyone, classifying nobody. preflight says freeze and
emergency are ONE RULE WITH TWO CAUSES -- and gives one cause an estate label
and reads the other off a classification. The split makes preflight's own
sentence true.
"""


# --------------------------------------------------------------------------


def witness(decl, budget):
    """Hand the deciding state to TLC, so the two checkers can disagree."""
    key = "DeclaringABlockDoesNotExempt"
    n, v, _ = sweep(Rules(), decl, 2, budget=budget)
    if key not in v:
        print("no witness: the invariant holds", file=sys.stderr)
        return 1
    msg, tr = v[key]
    print("\\* WITNESS, emitted by sim/label_sim.py. TLC must reach this too.")
    print("\\* %s" % msg)
    for s in tr:
        print("\\*   %s" % s)
    print("\\* Check tla/Labels.tla with SeparateEmergency = FALSE and require")
    print("\\* DeclaringABlockDoesNotExempt to be VIOLATED; with TRUE, to hold.")
    return 0


def selftest(decl, budget):
    print("  label_sim selftest -- every rule must be able to change truth "
          "value, in one direction or the other\n")
    rc = 0
    _, base, _ = sweep(Rules(), decl, 2, budget=budget)
    print("  %-24s %-28s %s" % ("baseline", "", ""))
    for mut, inv in sorted(NEGATIVES.items()):
        sys.stdout.write("  break %-18s -> %-28s ... " % (mut, inv))
        sys.stdout.flush()
        if inv in base:
            print("BAD: already violated at baseline; nothing to break")
            rc = 1
            continue
        _, v, _ = sweep(Rules(mut, "none"), decl, 2, budget=budget)
        if inv in v:
            print("VIOLATES as required")
        else:
            print("BAD: the mutation changed nothing; %s verifies nothing" % inv)
            rc = 1
    print()
    for rep, inv in sorted(REPAIR_TESTS.items()):
        sys.stdout.write("  fix   %-18s -> %-28s ... " % (rep, inv))
        sys.stdout.flush()
        if inv not in base:
            print("BAD: not violated at baseline; nothing to fix")
            rc = 1
            continue
        _, v, _ = sweep(Rules("none", rep), decl, 2, budget=budget)
        if inv not in v:
            print("HOLDS as required")
        else:
            print("BAD: the repair changed nothing; the finding is misdiagnosed")
            rc = 1
    sys.stdout.write("\n  baseline violations == KNOWN ......................... ")
    got = set(base)
    if got == KNOWN:
        print("PASS")
    else:
        print("FAIL")
        for k in sorted(got - KNOWN):
            print("      NEW finding, not in KNOWN: %s\n        %s" % (k, base[k][0]))
        for k in sorted(KNOWN - got):
            print("      KNOWN finding no longer reachable (fixed?): %s" % k)
        rc = 1
    print("\n  both directions confirmed" if rc == 0 else "\n  selftest FAILED")
    return rc


def report(decl, rules, nprs, budget, cap, walks, seed):
    if walks:
        n, v, trunc = random_walk(rules, decl, nprs, walks, seed)
        mode = "property-based, %d walks, seed %d" % (walks, seed)
    else:
        n, v, trunc = sweep(rules, decl, nprs, cap=cap, budget=budget)
        mode = ("exhaustive up to %d human interventions" % budget
                + (" -- TRUNCATED at the state cap" if trunc else ""))
    labels, groups = decl
    print("  declaration: %d labels, %d exclusion groups" % (len(labels), len(groups)))
    print("  mutation:    %s -- %s" % (rules.m, MUTATIONS[rules.m]))
    print("  repair:      %s -- %s" % (rules.r, REPAIRS[rules.r]))
    print("  emergency:   read as a %s fact" % rules.emergency_reading)
    print("  search:      %s, %d states, %d PRs\n" % (mode, n, nprs))
    for name in INVARIANTS:
        if name in v:
            msg, tr = v[name]
            print("  VIOLATED  %s" % name)
            print("            %s" % msg)
            for s in tr:
                print("              %s" % s)
            print()
        else:
            print("  holds     %s" % name)
    print("\n  %d of %d invariants violated" % (len(v), len(INVARIANTS)))
    return v, trunc


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--prs", type=int, default=2)
    ap.add_argument("--mutate", default="none", choices=sorted(MUTATIONS))
    ap.add_argument("--repair", default="none", choices=sorted(REPAIRS))
    ap.add_argument("--budget", type=int, default=BUDGET,
                    help="human interventions the search may spend")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--question", choices=["emergency"])
    ap.add_argument("--witness", action="store_true")
    ap.add_argument("--random", type=int, default=0, metavar="WALKS")
    ap.add_argument("--seed", type=int, default=20260913)
    ap.add_argument("--cap", type=int, default=4_000_000)
    a = ap.parse_args()

    decl = declaration()
    if a.selftest:
        return selftest(decl, min(a.budget, 2))
    if a.question:
        return question(decl, a.budget)
    if a.witness:
        return witness(decl, a.budget)

    rules = Rules(a.mutate, a.repair)
    v, trunc = report(decl, rules, a.prs, a.budget, a.cap, a.random, a.seed)
    if (a.mutate == "none" and a.repair == "none" and a.prs == 2
            and not a.random and not trunc):
        return 0 if set(v) == KNOWN else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
