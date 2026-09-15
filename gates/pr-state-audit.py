#!/usr/bin/env python3
"""Audit every OPEN pull request for label states the pipeline forbids.

WHY. change/label-owners.tsv already declares mutual-exclusion constraints --
six `exclusive` rows naming a group, its labels and a cardinality -- and
NOTHING READS THEM. gates/label-audit.py audits the declaration against the
source tree; it never looks at a live pull request. So the constraints are
prose, and the estate has been reaching states they forbid all day:

  - two open PRs holding deploy:staging at once (scenarios.org D22, verified
    in the forge timeline at 02:51:42Z)
  - five PRs simultaneously carrying staging:uat, which one berth cannot
    produce (issue #103)
  - a change:end tombstone on a PR that is still open and still deploying

This reads the DECLARATION and applies it to the FORGE.

    python3 gates/pr-state-audit.py [--json]

Exit 0 clean, 1 findings. Read-only: it opens no PR and writes no label.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
from datetime import datetime, timezone
import sys
from collections import defaultdict
from pathlib import Path

# ---------------------------------------------------------------------------
# THE MINIMAL INVARIANTS. Five, and every one of them has been violated on
# this estate in the last twenty-four hours. They are the smallest set whose
# breach means the PR list is lying about the estate.
#
#   I1  AT MOST ONE open PR carries deploy:staging.
#       The berth. Guard 1 exists to enforce it and does not: two PRs held it
#       at 02:51:42Z (scenarios.org D22), and the lock is last-write-wins with
#       no compare-and-swap (change/lock.sh:17), so the loser is not refused --
#       it is silently erased and keeps deploying.
#
#   I2  AT MOST ONE open PR carries deploy:production.
#       The path to production is a singleton for the same reason.
#
#   I3  NO open PR carries a terminal label.
#       change:end / change:complete / change:failed / change:backed-out all
#       assert the change is finished. On an open PR that is a claim about a
#       state it is not in.
#
#   I4  NO PR is finished AND moving.
#       A terminal label beside deploy:*, change:start or change:scheduled.
#       #52 carried change:end through an entire successful deploy and merge.
#
#   I6  THE BOOKINGS AND THE LABELS AGREE.
#       One estate, one calendar: the set of PRs carrying change:scheduled
#       must equal the set holding an open window. A window with no label is
#       a slot the calendar is holding for nobody -- and `schedule.sh block`
#       queues behind it, which is how "next available" ended up four days
#       out. A label with no window is a change claiming a booking that does
#       not exist.
#
#   I5  THE DECLARED EXCLUSIVE GROUPS HOLD, per PR.
#       Six of them in label-owners.tsv -- class, lifecycle, and the four
#       verdict pairs. They are declared and nothing has ever read them.
#
# Plus two hygiene checks that are not invariants but catch the same rot:
# RETIRED/REJECTED labels still in use, and pipeline-namespace labels that no
# declaration covers.
# ---------------------------------------------------------------------------

REPO = "aygp-dr/standard-change"
DECL = Path(__file__).resolve().parent.parent / "change" / "label-owners.tsv"

# Labels that assert the change is FINISHED. An open PR carrying one is
# claiming a closure it has not reached.
TERMINAL = {"change:end", "change:complete", "change:failed", "change:backed-out",
            "change:abandoned", "change:superseded"}
# change:end is the TOMBSTONE -- it says cleanup ran. It does not say what the
# change DID. These do, and one of them must accompany it.
# The FOUR change closures. spec.org §Nomenclature, corrected 2026-09-15:
# a change completes, is backed out, is ABANDONED, or is SUPERSEDED. It is
# never `cancelled` or `expired` -- those are window results.
#
# abandoned and superseded were added to the forge and to the declaration and
# NOT ADDED HERE, so the audit went on reporting tombstone-without-closure for
# #55 while #55 carried change:abandoned. A closure code the checker does not
# know about is not a closure code -- the same defect as a label the
# declaration does not know about, one layer up.
CLOSURE = {"change:complete", "change:failed", "change:backed-out",
           "change:abandoned", "change:superseded"}
# A settle briefly holds change:end on a PR that is open, between the label
# write and the merge landing. That window is about a second. Sixty is
# generous and still catches everything that matters.
GRACE_S = 60
# Labels that assert the change is MOVING right now.
IN_FLIGHT = {"deploy:staging", "deploy:production", "staging:in-progress",
             "change:scheduled", "change:start"}
# Singletons: at most one open PR may carry these across the whole estate.
ESTATE_SINGLETON = {"deploy:staging": "the berth (guard 1)",
                    "deploy:production": "the production path"}


def decl():
    """Returns (exclusive_groups, retired, declared_names)."""
    groups, retired, names = [], {}, set()
    for line in DECL.read_text().splitlines():
        if line.startswith("#") or "\t" not in line:
            continue
        f = line.split("\t")
        if f[0] == "exclusive" and len(f) >= 4:
            groups.append((f[1], f[2].split(), f[3]))
        elif len(f) >= 2:
            names.add(f[0])
            if f[1] in ("RETIRED", "REJECTED"):
                retired[f[0]] = f[1]
    return groups, retired, names


def audit(open_prs, groups, retired, declared, booked=None):
    """The five invariants plus two hygiene checks, over a list of PR dicts.

    Split out from main() so --selftest can drive it with synthetic states and
    no network. A gate that cannot be shown rejecting its own fail fixture
    produces no verdict (spec.org, Verification contract).
    """
    findings = []

    def add(kind, detail, prs_):
        findings.append({"kind": kind, "detail": detail, "prs": sorted(prs_)})

    for lab, what in ESTATE_SINGLETON.items():
        held = [p["n"] for p in open_prs if lab in p["labels"]]
        if len(held) > 1:
            add("singleton", f"{len(held)} open PRs carry `{lab}` -- {what} admits one", held)
    # I3, with a grace window. A settle holds change:end on an open PR for about
    # a second between writing the label and the merge landing; firing on that
    # would train a reader to ignore the check. Past GRACE_S it is a real
    # finding: the change is closed and still open.
    for lab in sorted(TERMINAL):
        carry = [p["n"] for p in open_prs
                 if lab in p["labels"] and (p.get("age_s") is None or p["age_s"] > GRACE_S)]
        if carry:
            add("terminal-on-open",
                f"`{lab}` asserts the change is finished, on {len(carry)} OPEN PR(s) "
                f"idle > {GRACE_S}s", carry)

    # AND THE PART NOBODY CAN RESOLVE FROM THE LABELS. change:end is the
    # tombstone -- it records that cleanup RAN. It does not record what the
    # change did. Without a closure code beside it, an open PR carrying it is
    # unresolvable: it might need resubmitting (failed, backed-out) or merging
    # (complete), and nothing on the change says which.
    #
    # This is not theoretical. change:failed and change:backed-out DID NOT
    # EXIST on the forge until 2026-09-15, and change/abort.sh writes them with
    # `|| true` -- so every abort before then produced exactly this state.
    orphan = [p["n"] for p in open_prs
              if "change:end" in p["labels"] and not (p["labels"] & CLOSURE)
              and (p.get("age_s") is None or p["age_s"] > GRACE_S)]
    if orphan:
        add("tombstone-without-closure",
            "`change:end` with no closure code: cannot tell whether these need "
            "RESUBMITTING (failed/backed-out) or MERGING (complete)", orphan)
    for p in open_prs:
        t, f = p["labels"] & TERMINAL, p["labels"] & IN_FLIGHT
        if t and f:
            add("finished-and-moving",
                f"#{p['n']} carries {sorted(t)} (finished) and {sorted(f)} (moving)", [p["n"]])
    for name, labs, card in groups:
        for p in open_prs:
            got = sorted(p["labels"] & set(labs))
            if len(got) > 1:
                add("exclusive", f"#{p['n']} breaks `{name}` (max {card}): {got}", [p["n"]])
    # I6 -- the calendar and the labels are two records of one fact.
    if booked is not None:
        labelled = {str(p["n"]) for p in open_prs if "change:scheduled" in p["labels"]}
        orphan_window = sorted(booked - labelled, key=int)
        orphan_label = sorted(labelled - booked, key=int)
        if orphan_window:
            add("booking-without-label",
                f"{len(orphan_window)} open window(s) held by a change with no "
                f"`change:scheduled`: the calendar is holding a slot for nobody, "
                f"and `schedule.sh block` queues behind it",
                [int(n) for n in orphan_window])
        if orphan_label:
            add("label-without-booking",
                f"{len(orphan_label)} change(s) claim `change:scheduled` with no "
                f"open window on the calendar",
                [int(n) for n in orphan_label])

    for lab, why in retired.items():
        carry = [p["n"] for p in open_prs if lab in p["labels"]]
        if carry:
            add("retired", f"`{lab}` is declared {why} and is on {len(carry)} open PR(s)", carry)
    ns = ("change:", "deploy:", "staging:", "production:", "blocked:", "itil:",
          "release", "berth:", "review:", "deployed:")
    seen = defaultdict(list)
    for p in open_prs:
        for lab in p["labels"]:
            if lab.startswith(ns) and lab not in declared:
                seen[lab].append(p["n"])
    for lab, carry in sorted(seen.items()):
        add("undeclared", f"`{lab}` is on {len(carry)} open PR(s) and in no declaration", carry)
    return findings


def selftest(groups, retired, declared) -> int:
    """Each invariant gets a state that MUST be rejected, and a clean control.

    The control matters as much as the failures: an audit that refuses
    everything is as useless as one that refuses nothing.
    """
    def P(n, *labs, age=999):
        # age defaults past GRACE_S: a synthetic case is not a settle in flight.
        return {"n": n, "draft": False, "title": "", "age_s": age, "labels": set(labs)}

    cases = [
        ("I1 two PRs hold the berth", "singleton",
         [P(1, "deploy:staging"), P(2, "deploy:staging")]),
        ("I2 two PRs hold production", "singleton",
         [P(1, "deploy:production"), P(2, "deploy:production")]),
        ("I3 a tombstone on an open PR", "terminal-on-open", [P(1, "change:end")]),
        ("I4 finished and moving at once", "finished-and-moving",
         [P(1, "change:end", "deploy:staging")]),
        ("I5 two classes on one PR", "exclusive",
         [P(1, "itil:standard", "itil:normal")]),
        ("H1 a RETIRED label in use", "retired", [P(1, "staging:passed")]),
        ("H2 an undeclared pipeline label", "undeclared", [P(1, "staging:invented")]),
        ("I3b a tombstone with no closure code", "tombstone-without-closure",
         [P(1, "change:end")]),
    ]
    bad = 0
    for name, kind, state in cases:
        got = {f["kind"] for f in audit(state, groups, retired, declared)}
        ok = kind in got
        print(f"  {'ok  ' if ok else 'BAD '} {name:<38} -> {kind if ok else sorted(got) or 'nothing'}")
        bad += 0 if ok else 1
    fresh = audit([P(1, "change:end", age=5)], groups, retired, declared)
    okf = not fresh
    print(f"  {'ok  ' if okf else 'BAD '} {'GRACE: a settle in flight is not a finding':<38} -> "
          f"{'suppressed' if okf else [f['kind'] for f in fresh]}")

    clean = [P(1, "app:core", "itil:standard"), P(2, "app:plp", "itil:normal", "deploy:staging")]
    got = audit(clean, groups, retired, declared)
    ok = not got
    print(f"  {'ok  ' if ok else 'BAD '} {'CONTROL: a clean estate is accepted':<38} -> "
          f"{'no findings' if ok else [f['kind'] for f in got]}")
    bad += 0 if ok else 1
    bad += 0 if okf else 1
    print(f"  pr-state-audit self-test: {len(cases)+2} cases, {bad} wrong")
    return 1 if bad else 0


def windows():
    """PRs holding an open window, from the calendar.

    Returns None if the calendar could not be read -- which is INDETERMINATE
    and must not be reported as "no windows". An unreadable calendar and an
    empty one are different answers (spec.org defect class 1).
    """
    try:
        out = subprocess.run(["./change/schedule.sh", "list", "--open"],
                             capture_output=True, text=True, timeout=30,
                             env={**os.environ, "SCHEDULE_QUANTUM": "10"}).stdout
    except Exception:
        return None
    return {m.group(1) for line in out.splitlines()
            if (m := re.search(r"#(\d+)", line))}


def prs():
    out = subprocess.run(
        ["gh", "pr", "list", "--repo", REPO, "--state", "open", "--limit", "100",
         "--json", "number,labels,isDraft,title,updatedAt"],
        capture_output=True, text=True, check=True).stdout
    now = datetime.now(timezone.utc)
    rows = []
    for p in json.loads(out):
        age = None
        if p.get("updatedAt"):
            age = (now - datetime.fromisoformat(p["updatedAt"].replace("Z", "+00:00"))).total_seconds()
        rows.append({"n": p["number"], "draft": p["isDraft"], "title": p["title"],
                     "age_s": age, "labels": {l["name"] for l in p["labels"]}})
    return rows


def main() -> int:
    groups, retired, declared = decl()
    if "--selftest" in sys.argv:
        return selftest(groups, retired, declared)
    open_prs = prs()
    booked = windows()
    findings = audit(open_prs, groups, retired, declared, booked)
    if booked is None:
        findings.append({"kind": "calendar-unreadable",
                         "detail": "the calendar could not be read, so I6 was not "
                                   "checked -- indeterminate, not clean",
                         "prs": []})

    if "--json" in sys.argv:
        print(json.dumps({"open": len(open_prs), "findings": findings}, indent=2))
    else:
        print(f"  {len(open_prs)} open pull requests audited against "
              f"{len(declared)} declared labels and {len(groups)} exclusion groups")
        for f in findings:
            print(f"  FAIL [{f['kind']}] {f['detail']}")
            print(f"         PRs: {', '.join('#'+str(n) for n in f['prs'])}")
        print(f"  {len(findings)} finding(s)")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
