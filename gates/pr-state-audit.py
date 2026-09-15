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
import subprocess
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
TERMINAL = {"change:end", "change:complete", "change:failed", "change:backed-out"}
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


def prs():
    out = subprocess.run(
        ["gh", "pr", "list", "--repo", REPO, "--state", "open", "--limit", "100",
         "--json", "number,labels,isDraft,title"],
        capture_output=True, text=True, check=True).stdout
    return [{"n": p["number"], "draft": p["isDraft"], "title": p["title"],
             "labels": {l["name"] for l in p["labels"]}} for p in json.loads(out)]


def main() -> int:
    groups, retired, declared = decl()
    open_prs = prs()
    findings = []

    def add(kind, detail, prs_):
        findings.append({"kind": kind, "detail": detail, "prs": sorted(prs_)})

    # 1. ESTATE SINGLETONS. More than one open PR holding the berth is guard 1
    #    violated, not merely unenforced.
    for lab, what in ESTATE_SINGLETON.items():
        held = [p["n"] for p in open_prs if lab in p["labels"]]
        if len(held) > 1:
            add("singleton", f"{len(held)} open PRs carry `{lab}` -- {what} admits one", held)

    # 2. TERMINAL ON AN OPEN PR. A tombstone says cleanup ran and the record is
    #    closed. On an open PR it is a claim about a state the change is not in.
    for lab in sorted(TERMINAL):
        carry = [p["n"] for p in open_prs if lab in p["labels"]]
        if carry:
            add("terminal-on-open",
                f"`{lab}` asserts the change is finished, on {len(carry)} OPEN PR(s)", carry)

    # 3. TERMINAL AND IN-FLIGHT TOGETHER on one PR: finished and moving at once.
    for p in open_prs:
        t, f = p["labels"] & TERMINAL, p["labels"] & IN_FLIGHT
        if t and f:
            add("finished-and-moving",
                f"#{p['n']} carries {sorted(t)} (finished) and {sorted(f)} (moving)", [p["n"]])

    # 4. DECLARED EXCLUSIVE GROUPS, applied per PR.
    for name, labs, card in groups:
        for p in open_prs:
            got = sorted(p["labels"] & set(labs))
            if len(got) > 1:
                add("exclusive", f"#{p['n']} breaks `{name}` (max {card}): {got}", [p["n"]])

    # 5. RETIRED / REJECTED labels still present.
    for lab, why in retired.items():
        carry = [p["n"] for p in open_prs if lab in p["labels"]]
        if carry:
            add("retired", f"`{lab}` is declared {why} and is on {len(carry)} open PR(s)", carry)

    # 6. UNDECLARED labels in a pipeline namespace.
    ns = ("change:", "deploy:", "staging:", "production:", "blocked:", "itil:",
          "release", "berth:", "review:", "deployed:")
    seen = defaultdict(list)
    for p in open_prs:
        for lab in p["labels"]:
            if lab.startswith(ns) and lab not in declared:
                seen[lab].append(p["n"])
    for lab, carry in sorted(seen.items()):
        add("undeclared", f"`{lab}` is on {len(carry)} open PR(s) and in no declaration", carry)

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
