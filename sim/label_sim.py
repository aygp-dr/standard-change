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


def may_proceed(cls, scope, state, blocker, ready="ready"):
    """The rules as they stand. Returns (ok, reason)."""
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
    for cls, scope, state, blocker, ready in itertools.product(
            CLASSES, SCOPES, STATES, BLOCKERS, READY):
        rows += 1
        derived = scope_of(cls, scope) | {cls} | ({state} if state else set())
        ok, why = may_proceed(cls, scope, state, blocker, ready)

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
