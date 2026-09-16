#!/usr/bin/env python3
"""walk.py -- the chain must be RUNNABLE, and this is what says so.

Reads states.tsv and transitions.tsv beside it and asserts the three
structural properties the model claims, then runs weighted random walks from
the initial state and reports where they end up.

  1. no non-terminal dead end   every non-terminal state has an outgoing edge
  2. no accidental orphan       every state is reachable from an initial state
  3. it terminates              N walks from G01 all reach a terminal state

Property 2 is reported in two tiers, because weight 0.0 is load-bearing here:

  reachable            some path of positive-weight edges leads here
  hypothesis-only      reachable ONLY through an edge measured as never taken

A hypothesis-only state is not an error. It is this model's way of saying
"the code contains this edge and nothing has ever traversed it" -- guard 0's
BEHIND refusal and guard 6's production-first refusal are exactly that
(spec.org, The defect taxonomy, class 7; scenarios.org D17). Pass
--counterfactual to give every 0.0 edge an epsilon weight and walk the
pipeline as its authors believed it behaved.

  ./walk.py                    structure + 20000 walks
  ./walk.py --counterfactual   the same, with the never-taken edges enabled
"""
import csv
import pathlib
import random
import sys
from collections import defaultdict

HERE = pathlib.Path(__file__).resolve().parent
INITIAL = {"G01": "pull request", "E01": "estate"}
EPSILON = 0.02


def load():
    with (HERE / "states.tsv").open() as f:
        states = {r["id"]: r for r in csv.DictReader(f, delimiter="\t")}
    with (HERE / "transitions.tsv").open() as f:
        edges = list(csv.DictReader(f, delimiter="\t"))
    return states, edges


def main():
    counterfactual = "--counterfactual" in sys.argv
    states, edges = load()
    bad = []

    out = defaultdict(list)
    for e in edges:
        for side in ("from", "to"):
            if e[side] not in states:
                bad.append(f"edge {e['from']}->{e['to']} names unknown state {e[side]}")
        w = float(e["weight"])
        if counterfactual and w == 0.0:
            w = EPSILON
        out[e["from"]].append((e["to"], w))

    # 1. no non-terminal dead end
    for sid, s in states.items():
        terminal = s["terminal"] == "yes"
        live = [w for _, w in out[sid] if w > 0]
        if terminal and out[sid]:
            bad.append(f"{sid} is terminal and has outgoing edges")
        if not terminal and not out[sid]:
            bad.append(f"{sid} is a non-terminal DEAD END")
        elif not terminal and not live:
            bad.append(f"{sid} can only be left by an edge measured as never taken")

    # 2. reachability, in two tiers
    def reach(roots, positive_only):
        seen, stack = set(roots), list(roots)
        while stack:
            cur = stack.pop()
            for dst, w in out[cur]:
                if positive_only and w <= 0:
                    continue
                if dst not in seen:
                    seen.add(dst)
                    stack.append(dst)
        return seen

    live_reach = reach(INITIAL, True)
    any_reach = reach(INITIAL, False)
    hypothesis_only = sorted(any_reach - live_reach)
    orphans = sorted(set(states) - any_reach)
    for o in orphans:
        bad.append(f"{o} is unreachable from every initial state")

    # 3. it terminates
    terminals = {sid for sid, s in states.items() if s["terminal"] == "yes"}
    rng = random.Random(20260914)
    ends, lengths, stuck = defaultdict(int), [], 0
    N = 20000
    for _ in range(N):
        cur, n = "G01", 0
        while cur not in terminals and n < 10000:
            choices = [(d, w) for d, w in out[cur] if w > 0]
            total = sum(w for _, w in choices)
            r, acc = rng.random() * total, 0.0
            for d, w in choices:
                acc += w
                if r <= acc:
                    cur = d
                    break
            n += 1
        if cur in terminals:
            ends[cur] += 1
            lengths.append(n)
        else:
            stuck += 1
    if stuck:
        bad.append(f"{stuck}/{N} walks did not reach a terminal state")

    print(f"states {len(states)}  transitions {len(edges)}"
          f"  counterfactual={counterfactual}")
    print(f"reachable by positive-weight edges: {len(live_reach)}")
    print("hypothesis-only (the edge exists and has never been taken): "
          + (", ".join(hypothesis_only) or "none"))
    if lengths:
        lengths.sort()
        print(f"walks {len(lengths)}  steps min {lengths[0]} "
              f"median {lengths[len(lengths)//2]} max {lengths[-1]}")
    for t in sorted(ends, key=lambda k: -ends[k]):
        print(f"  {t:<5} {states[t]['name']:<16} {ends[t]*100.0/N:5.1f}%")
    for b in bad:
        print("FAIL " + b)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
