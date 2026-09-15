#!/usr/bin/env python3
"""Merge the five lens models into one label vocabulary and one weighted graph.

Five engineers modelled the same pipeline from five lenses (deployments,
environments, gating, protection, end-to-end). Each produced states.tsv,
transitions.tsv and labels.tsv on a shared schema. This merges them.

TWO THINGS IT WILL NOT DO:

  1. It does not resolve disagreements by voting. Where the five classify a
     label differently -- app:* is `observation` to the environments lens and
     `classification` to the gating lens -- the disagreement is REPORTED, with
     who said what. A merge that silently takes the majority manufactures a
     consensus that was never reached, which is the same defect as a verdict
     that does not name its instrument.

  2. It does not drop weight-0 edges. A 0.0 weight here means "this edge is in
     the code and has never been traversed" -- guard 0's BEHIND path, guard 6's
     484 runs. Deleting it would assert the guard does not exist; re-weighting
     it would assert it fires. It stays, at zero.

    python3 experiments/021-state-machines/merge.py
"""
from __future__ import annotations

import csv
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).parent
LENSES = ["deployments", "environments", "gating", "protection", "end-to-end"]
SEMANTIC_ORDER = ["intent", "classification", "state", "observation", "estate"]

# THE CORE IS THREE NAMESPACES. Stated by the reviewer on 2026-09-14 and it is
# the most useful simplification anyone has made to this vocabulary:
#
#   app:*      WHAT moves          -- the deploy unit, and so the blast radius
#   itil:*     WHICH RULES apply   -- standard (pre-authorised) / normal
#                                     (assessed) / emergency (override)
#   release:*  GO                  -- the intent to ship, now
#
# Everything else is one of four supporting roles. They are not noise and not
# deletable -- an audit trail is how a PIR is possible at all -- but none of
# them carries semantics a person has to choose. They are consequences.
ROLES = {
    "core":       ("app:", "itil:", "release"),
    "audit":      ("staging:", "production:", "change:complete", "change:failed",
                   "change:backed-out", "deployed:", "change:backfill-owed"),
    "gatekeeping":("blocked:", "deploy:", "change:scheduled", "change:requested"),
    "estate":     ("freeze", "emergency"),
    "override":   ("labeler:skip", "hold:staging", "itil:emergency", "review:proxy"),
}


def role_of(label: str) -> str:
    """Longest-prefix wins, and core wins ties -- itil:emergency is BOTH a
    classification and the override, and the override reading is the one that
    changes behaviour, so it is listed under override and noted in core."""
    best, blen = "other", -1
    for role, prefixes in ROLES.items():
        for pre in prefixes:
            if label.startswith(pre) and len(pre) > blen:
                best, blen = role, len(pre)
    return best


def read(lens: str, name: str) -> list[dict]:
    p = ROOT / lens / f"{name}.tsv"
    if not p.exists():
        return []
    with p.open() as fh:
        return [r for r in csv.DictReader(fh, delimiter="\t") if r.get(list(r)[0])]


def main() -> None:
    # ---- labels -----------------------------------------------------------
    sem: dict[str, dict[str, list[str]]] = defaultdict(lambda: defaultdict(list))
    owner: dict[str, set] = defaultdict(set)
    present = [l for l in LENSES if (ROOT / l / "labels.tsv").exists()]
    for lens in present:
        for r in read(lens, "labels"):
            lab = (r.get("label") or "").strip()
            if not lab:
                continue
            sem[lab][(r.get("semantics") or "?").strip()].append(lens)
            owner[lab].add((r.get("owner") or "?").strip())

    # ---- transition weight, per label ------------------------------------
    # How much of the machine's movement does each label drive? Summed over
    # lenses and normalised, so a label that triggers many heavy edges reads
    # heavier than one that triggers a single rare edge.
    lab_weight: dict[str, float] = defaultdict(float)
    lab_edges: dict[str, int] = defaultdict(int)
    edges: list[tuple] = []
    for lens in present:
        for r in read(lens, "transitions"):
            try:
                wt = float(r.get("weight") or 0)
            except ValueError:
                wt = 0.0
            trig = (r.get("trigger") or "").strip()
            kind = (r.get("trigger_kind") or "").strip()
            edges.append((lens, r.get("from"), r.get("to"), trig, kind, wt))
            if kind in ("label_add", "label_remove"):
                for lab in sem:
                    if lab and lab in trig:
                        lab_weight[lab] += wt
                        lab_edges[lab] += 1

    total = sum(lab_weight.values()) or 1.0

    # ---- report -----------------------------------------------------------
    print(f"=== merged from {len(present)} lenses: {', '.join(present)}")
    print(f"    {len(sem)} distinct labels, {len(edges)} transitions total")

    print("\n=== DISAGREEMENTS (reported, never voted on)")
    dis = {l: v for l, v in sem.items() if len(v) > 1}
    if not dis:
        print("    none")
    for lab, v in sorted(dis.items()):
        parts = "; ".join(f"{s} ({','.join(ls)})" for s, ls in sorted(v.items()))
        print(f"    {lab:<24} {parts}")

    print("\n=== THE CORE THREE, and what each one answers")
    core_q = {"app:": "WHAT moves (deploy unit, blast radius)",
              "itil:": "WHICH RULES apply",
              "release": "GO -- the intent to ship"}
    for pre, q in core_q.items():
        rows = sorted(((l, lab_weight[l], lab_edges[l]) for l in sem
                       if l.startswith(pre)), key=lambda t: -t[1])
        tot = sum(r[1] for r in rows)
        print(f"\n  {pre:<10} {q}    [{tot/total:.1%} of label-driven movement]")
        for lab, w, n in rows:
            print(f"      {lab:<24} {w/total:6.2%}  ({n:2d} edges)")

    print("\n=== THE SUPPORTING ROLES -- consequences, not choices")
    byrole = defaultdict(list)
    for l in sem:
        byrole[role_of(l)].append(l)
    blurb = {"audit": "the trail a PIR is written from",
             "gatekeeping": "who may move, and when",
             "estate": "properties of the WORLD, not of a change",
             "override": "how a person gets past a refusal, on the record",
             "other": "unclassified"}
    for role in ("override", "gatekeeping", "estate", "audit", "other"):
        labs = sorted(byrole.get(role, []))
        if not labs:
            continue
        w = sum(lab_weight[l] for l in labs)
        print(f"\n  {role.upper():<12} {w/total:6.1%}  -- {blurb[role]}")
        print("      " + ", ".join(labs))

    # ---- mermaid ----------------------------------------------------------
    out = ROOT / "LABELS.mmd"
    L = ["flowchart TB",
         "  %% Merged from five lens models. Weight = share of label-driven",
         "  %% transition mass. The CORE THREE are what a person chooses;",
         "  %% everything else is a consequence of those choices."]
    def nid(lab):
        return "N" + "".join(ch if ch.isalnum() else "_" for ch in lab)

    L.append('  subgraph CORE["the core three -- what a person chooses"]')
    L.append("    direction LR")
    for pre, title in (("app:", "app: WHAT moves"),
                       ("itil:", "itil: WHICH RULES"),
                       ("release", "release: GO")):
        L.append(f'    subgraph S{nid(pre)}["{title}"]')
        L.append("      direction TB")
        for lab in sorted((l for l in sem if l.startswith(pre)),
                          key=lambda l: -lab_weight[l]):
            L.append(f'      {nid(lab)}["{lab}<br/>{lab_weight[lab]/total:.1%}"]')
        L.append("    end")
    L.append("  end")

    for role in ("gatekeeping", "estate", "audit", "override"):
        labs = sorted((l for l in sem if role_of(l) == role),
                      key=lambda l: -lab_weight[l])
        if not labs:
            continue
        w = sum(lab_weight[l] for l in labs) / total
        L.append(f'  subgraph R{role}["{role} -- {w:.0%} (a consequence)"]')
        L.append("    direction TB")
        for lab in labs:
            L.append(f'    {nid(lab)}["{lab}<br/>{lab_weight[lab]/total:.1%}"]')
        L.append("  end")

    L.append("  CORE ==>|decides| Rgatekeeping")
    L.append("  Rgatekeeping ==>|permits| Raudit")
    L.append("  Restate -.->|blocks everything, including its declarer| Rgatekeeping")
    L.append("  Roverride -.->|gets past a refusal, on the record| Rgatekeeping")
    out.write_text("\n".join(L) + "\n")
    print(f"\n=== wrote {out.relative_to(ROOT.parent.parent)}  ({len(L)} lines)")


if __name__ == "__main__":
    main()
