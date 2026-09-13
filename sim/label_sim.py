#!/usr/bin/env python3
"""label_sim.py -- drive the CURRENT label set and find where the semantics are undecided.

Not a model of what the pipeline should do. A model of what the labels, as they
are declared today, actually permit -- so that a combination nobody intended
shows up as a reachable state rather than as an incident.

Three axes, each a separate fact, which is the lesson this repo keeps relearning:

  CLASS    itil:standard | itil:normal | itil:emergency   what kind of change
  SCOPE    app | shared | pipeline                        what it can break
  STATE    requested -> scheduled -> deploy:* -> complete  where it has got to

and the estate has BLOCKERS that are not properties of the change at all:
a freeze, somebody else holding a berth, an emergency in flight.
"""
import itertools, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DECL = ROOT / "change" / "label-owners.tsv"

CLASSES = ["itil:standard", "itil:normal", "itil:emergency"]
SCOPES  = ["app", "shared", "pipeline"]
STATES  = ["", "change:requested", "change:scheduled", "deploy:staging",
           "deploy:production", "change:complete"]

# Estate-level facts. NOT properties of the change being deployed -- properties
# of the world it would deploy into.
BLOCKERS = ["none", "freeze", "berth-held", "emergency-in-flight"]

# READINESS is a fourth axis, and it belongs to NEITHER of the other three.
#
# It is not the class (what kind of change), not the scope (what it can break),
# not the state (how far it has got) and not a blocker (a fact about the
# estate). It is the AUTHOR'S OWN STATEMENT that this is not finished, and it is
# the only input to any guard here that the pipeline does not derive, measure or
# infer -- it simply believes.
#
# It was unmodelled and unread until 2026-09-13: nothing in preflight, guard 4,
# queue.sh or activate.sh looked at isDraft, so a draft could book a window,
# take the berth, deploy to staging and collect the observations that authorize
# production, while its author's marker said do not.
READY = ["draft", "ready"]

# HOW THE WINDOW WAS OBTAINED. A fifth axis, added 2026-09-13 after the
# release-coordinator workflow made the distinction load-bearing.
#
#   none        no reservation. The change may be perfect and still not deploy.
#   queued      change/schedule.sh block with no --at: the booking walks to the
#               back of the queue and takes the first free aligned slot.
#   designated  block --at <iso>: a NAMED time, the way a release calendar is
#               actually used ("the Tuesday 19:00 slot").
#
# The two booking modes differ ONLY in where they propose to start. Everything
# after that is identical, and the clash check is the reason:
#
#   A DESIGNATED SLOT DOES NOT WIN A CLASH. Wanting a particular hour is not an
#   argument about who holds the path to production. When 6PM ET collided with
#   an auto-queued reservation the coordinator CANCELLED the queued one and
#   re-booked it -- a human decision, recorded as a cancellation, visible in the
#   schedule. Had --at simply displaced it, the queued change would have lost
#   its slot with nothing in the record saying why.
#
#   DESIGNATED BOOKINGS LEAVE HOLES, and that is correct. A named hour is not a
#   preference -- it is usually the developer saying "I will be at my desk then
#   and I want to watch this go out". That is what makes automatic reslotting
#   the wrong behaviour rather than merely a rude one: moving the change moves
#   it away from the person who arranged to be present for it, and the whole
#   value of the slot was the attention, not the minutes.
#
#   So the gaps are the point. A scheduler that packed them would be optimising
#   utilisation of a resource that is not scarce (staging) at the cost of one
#   that is (a person watching).
#
#   NEITHER MODE MAY BOOK INTO THE PAST. A reservation behind the clock is
#   closed by the next reap, so handing one back is success-shaped and
#   immediately worthless.
BOOKING = ["none", "queued", "designated"]


def declared():
    """Every label the declaration knows, plus its exclusion groups."""
    labels, groups = {}, {}
    for line in DECL.read_text().splitlines():
        f = line.split("\t")
        if line.startswith("#") or len(f) < 4:
            continue
        if f[0] == "exclusive":
            groups[f[1]] = set(f[2].split())
        elif len(f) >= 6:
            labels[f[0]] = {"owner": f[1], "persistent": f[2] == "yes"}
    return labels, groups


def scope_of(cls, scope):
    """What the labeller would derive, given what the diff touched."""
    if scope == "app":      return {"app:core"}
    if scope == "shared":   return {"app:core", "app:plp", "app:pdp", "app:checkout"}
    if scope == "pipeline": return {"control-plane"}
    return set()


def may_proceed(cls, scope, state, blocker, ready="ready", booking="queued"):
    """The rules as they stand. Returns (ok, reason)."""
    # NO WINDOW, NO DEPLOYMENT -- and no exemption, not even for an emergency.
    # An emergency is exempt from the FREEZE and the QUEUE rules; it is not
    # exempt from being on the calendar, because the calendar is what tells
    # everyone else that the one path to production is occupied. An emergency
    # that skipped it would collide with whatever was already deploying.
    if booking == "none" and state.startswith("deploy:"):
        return False, "no window: the change schedule has no reservation for this"
    # FIRST, AND WITH NO EXEMPTION. A draft is refused before the class is even
    # consulted, because the class cannot rescue it: itil:emergency is a
    # statement about the change's URGENCY, and draft is a statement about its
    # READINESS. An urgent unfinished change is still unfinished, and an
    # emergency that needs to ship is one `gh pr ready` away -- an act by the
    # author, which is exactly who should decide.
    if ready == "draft":
        return False, "draft: the author says it is not ready"
    if blocker == "freeze" and cls != "itil:emergency":
        return False, "freeze: only an emergency proceeds"
    if blocker == "emergency-in-flight" and cls != "itil:emergency":
        return False, "an emergency is in flight; ordinary changes wait"
    if blocker == "berth-held" and state in ("deploy:staging",):
        return False, "guard 1: one change holds staging"
    if scope == "pipeline" and state == "change:complete":
        # docs/changing-the-pipeline.org: proven by USE, not by its own merge.
        return True, "PROVISIONAL -- a pipeline change is not proven at merge"
    return True, "proceeds"


def main():
    labels, groups = declared()
    print(f"  declaration: {len(labels)} labels, {len(groups)} exclusion groups\n")

    findings, rows = [], 0
    for cls, scope, state, blocker, ready, booking in itertools.product(
            CLASSES, SCOPES, STATES, BLOCKERS, READY, BOOKING):
        rows += 1
        derived = scope_of(cls, scope) | {cls} | ({state} if state else set())
        ok, why = may_proceed(cls, scope, state, blocker, ready, booking)

        # 6. A DEPLOYMENT WITHOUT A RESERVATION. The two booking modes must be
        #    indistinguishable here: if `designated` could reach an environment
        #    on a path `queued` could not, --at would be a bypass wearing a
        #    calendar's clothes.
        if booking == "none" and ok and state.startswith("deploy:"):
            findings.append(
                f"UNBOOKED DEPLOY: reached {state} with no window ({cls}/{scope})")
        if ok and state.startswith("deploy:"):
            other = "queued" if booking == "designated" else "designated"
            ok2, _ = may_proceed(cls, scope, state, blocker, ready, other)
            if not ok2:
                findings.append(
                    f"BOOKING MODE IS A BYPASS: {booking} reaches {state} where "
                    f"{other} does not ({cls}/{scope}) -- naming an hour is not "
                    f"an argument about who holds the path to production")

        # 5. A DRAFT MUST NOT REACH AN ENVIRONMENT. The states that mean "it is
        #    out there" are the deploy:* pair; reaching either while the author
        #    says draft means the pipeline overrode the one signal it does not
        #    have to interpret.
        if ready == "draft" and ok and state.startswith("deploy:"):
            findings.append(
                f"DRAFT DEPLOYED: a draft reached {state} ({cls}/{scope}) -- the "
                f"author marked it not ready and nothing downstream re-asks")

        # 1. every derived label must be declared
        for l in derived:
            if l in ("app:core", "app:plp", "app:pdp", "app:checkout"):
                l = "app:*"
            if l and l not in labels:
                findings.append(f"undeclared label '{l}' reachable via {cls}/{scope}/{state}")

        # 2. no state may hold two members of an exclusion group
        for g, members in groups.items():
            both = members & derived
            if len(both) > 1:
                findings.append(f"{cls}/{scope}/{state}: holds {sorted(both)} from group '{g}'")

        # 3. THE ONE THE OWNER ASKED ABOUT. An emergency is BOTH a classification
        #    of one change and a blocker on every other change. One label is
        #    carrying two facts, and they are about different subjects.
        if cls == "itil:emergency" and blocker == "emergency-in-flight":
            findings.append(
                f"AMBIGUOUS: itil:emergency on this change, and an emergency in "
                f"flight elsewhere -- the same label names both, so 'is there an "
                f"emergency?' cannot distinguish 'am I one' from 'is one running'")

        # 4. a pipeline change that reaches complete is not proven
        if scope == "pipeline" and state == "change:complete" and "PROVISIONAL" not in why:
            findings.append(f"pipeline change complete with no soak: {cls}")

    uniq = sorted(set(findings))
    for f in uniq:
        print(f"  FINDING  {f}")
    print(f"\n  {rows} states explored, {len(uniq)} distinct finding(s)")
    return 1 if uniq else 0


if __name__ == "__main__":
    sys.exit(main())
