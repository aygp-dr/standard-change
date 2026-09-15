#!/usr/bin/env python3
"""walk.py -- run the end-to-end PR state machine as a Markov chain.

Reads states.tsv and transitions.tsv from this directory, normalises the
weights out of each source state, and walks the CHANGE chain from `opened`
N times. Prints the terminal distribution, the mean steps to termination, and
the visit rates for the states that exist to be counted (expired windows, the
two unnamed states, the blocked tier).

PURE COMPUTATION. No network, no forge, no estate, no clock. Nothing here
reads or writes anything outside this directory.

It FAILS LOUDLY, before walking, on:
  * a non-terminal state with no outgoing edge      (a dead end)
  * a terminal state with an outgoing edge          (not terminal)
  * an edge naming a state that is not declared
  * a state unreachable from its chain's start
  * a source state whose outgoing weights sum to <= 0
and, after walking, on any walk that hit the step cap without terminating.

Two chains, deliberately separate. Every state is a state OF A PULL REQUEST
except the three marked kind=estate, which are properties of the WORLD and
belong to no change. The estate chain is recurrent by design -- a freeze is
lifted, an emergency is cleared -- so it is checked for dead ends and
reachability and is NOT required to terminate. Merging the two would make the
estate a stage of somebody's change, which is the conflation spec.org
Nomenclature says took longest to find.

Usage:  python3 walk.py [--walks 10000] [--seed 0] [--cap 2000]
"""
import argparse
import collections
import csv
import pathlib
import random
import sys

HERE = pathlib.Path(__file__).resolve().parent
CHANGE_START = "opened"
ESTATE_START = "estate_normal"


def read_tsv(name):
    with (HERE / name).open(newline="") as fh:
        return list(csv.DictReader(fh, delimiter="\t"))


def die(msg):
    print(f"FAIL  {msg}", file=sys.stderr)
    sys.exit(1)


def load():
    states, terminal, kind = {}, set(), {}
    for row in read_tsv("states.tsv"):
        sid = row["id"].strip()
        if not sid:
            continue
        if sid in states:
            die(f"duplicate state id {sid!r}")
        states[sid] = row["name"]
        kind[sid] = row["kind"].strip()
        t = row["terminal"].strip().lower()
        if t not in ("yes", "no"):
            die(f"state {sid!r}: terminal must be yes/no, got {t!r}")
        if t == "yes":
            terminal.add(sid)

    out = collections.defaultdict(list)
    for row in read_tsv("transitions.tsv"):
        src, dst = row["from"].strip(), row["to"].strip()
        if not src:
            continue
        for s in (src, dst):
            if s not in states:
                die(f"transition {src} -> {dst} names undeclared state {s!r}")
        try:
            w = float(row["weight"])
        except ValueError:
            die(f"transition {src} -> {dst}: weight {row['weight']!r} is not a number")
        if w < 0:
            die(f"transition {src} -> {dst}: negative weight")
        out[src].append((dst, w, row["trigger_kind"].strip(), row["actor"].strip()))
    return states, terminal, kind, out


def reachable(start, out, members):
    seen, stack = {start}, [start]
    while stack:
        cur = stack.pop()
        for dst, _w, _tk, _a in out.get(cur, []):
            if dst in members and dst not in seen:
                seen.add(dst)
                stack.append(dst)
    return seen


def validate(states, terminal, kind, out):
    estate = {s for s in states if kind[s] == "estate"}
    change = {s for s in states if kind[s] != "estate"}
    problems = []

    for s in states:
        edges = out.get(s, [])
        if s in terminal and edges:
            problems.append(f"terminal state {s!r} has {len(edges)} outgoing edge(s)")
        if s not in terminal and not edges:
            problems.append(f"NON-TERMINAL DEAD END: {s!r} has no outgoing edge")
        if edges and sum(w for _d, w, _t, _a in edges) <= 0:
            problems.append(f"state {s!r}: outgoing weights sum to zero")
        for dst, _w, _tk, _a in edges:
            crossing = (s in estate) != (dst in estate)
            if crossing:
                problems.append(f"edge {s} -> {dst} crosses the change/estate boundary; "
                                "the estate is not a stage of anybody's change")

    for start, members, label in ((CHANGE_START, change, "change"),
                                  (ESTATE_START, estate, "estate")):
        if start not in states:
            problems.append(f"{label} chain start {start!r} is not declared")
            continue
        seen = reachable(start, out, members)
        for s in sorted(members - seen):
            problems.append(f"UNREACHABLE from {start!r} ({label} chain): {s!r}")

    if not (terminal & change):
        problems.append("the change chain declares no terminal state")
    if terminal & estate:
        problems.append("the estate chain declares a terminal state; it is recurrent by design")

    if problems:
        for p in problems:
            print(f"FAIL  {p}", file=sys.stderr)
        sys.exit(1)
    return change, estate


def normalise(out):
    norm = {}
    for src, edges in out.items():
        total = sum(w for _d, w, _t, _a in edges)
        acc, cum = 0.0, []
        for dst, w, tk, actor in edges:
            acc += w / total
            cum.append((acc, dst, tk, actor))
        norm[src] = cum
    return norm


def step(rng, cum):
    x = rng.random()
    for acc, dst, tk, actor in cum:
        if x <= acc:
            return dst, tk, actor
    return cum[-1][1], cum[-1][2], cum[-1][3]


def walk(rng, norm, terminal, cap):
    cur, steps, visits, kinds = CHANGE_START, 0, collections.Counter([CHANGE_START]), collections.Counter()
    while cur not in terminal:
        if steps >= cap:
            return None, steps, visits, kinds
        cur, tk, _actor = step(rng, norm[cur])
        kinds[tk] += 1
        visits[cur] += 1
        steps += 1
    return cur, steps, visits, kinds


def bar(frac, width=28):
    return "#" * int(round(frac * width))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--walks", type=int, default=10000)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--cap", type=int, default=2000,
                    help="step cap; a walk that hits it is a non-termination failure")
    a = ap.parse_args()

    states, terminal, kind, out = load()
    change, estate = validate(states, terminal, kind, out)
    norm = normalise(out)

    print(f"states       {len(states)}  ({len(change)} change, {len(estate)} estate, "
          f"{len(terminal)} terminal)")
    print(f"transitions  {sum(len(v) for v in out.values())}")
    print(f"validation   no dead ends, no unreachable states, "
          f"no change/estate crossings\n")

    rng = random.Random(a.seed)
    ends, steps_total, allvisits, allkinds = collections.Counter(), 0, collections.Counter(), collections.Counter()
    hit_cap, ever = 0, collections.Counter()
    for _ in range(a.walks):
        end, steps, visits, kinds = walk(rng, norm, terminal, a.cap)
        if end is None:
            hit_cap += 1
            continue
        ends[end] += 1
        steps_total += steps
        allvisits.update(visits)
        allkinds.update(kinds)
        for s in visits:
            ever[s] += 1

    if hit_cap:
        die(f"{hit_cap}/{a.walks} walks hit the {a.cap}-step cap without terminating; "
            "the chain is not absorbing")

    n = sum(ends.values())
    print(f"TERMINAL DISTRIBUTION over {n} walks (seed {a.seed})")
    print(f"  {'closure code':<22} {'n':>6} {'share':>8}")
    for sid, c in ends.most_common():
        print(f"  {sid:<22} {c:>6} {c/n:>7.1%}  {bar(c/n)}")
    for sid in sorted(terminal & change):
        if sid not in ends:
            print(f"  {sid:<22} {0:>6} {0.0:>7.1%}  (never reached)")
    print(f"\nmean steps to termination   {steps_total/n:.2f}")
    print(f"median-ish (mean of visits) {sum(allvisits.values())/n:.2f} state visits per walk")

    watch = ["window_cancelled", "window_expired", "window_failed", "berth_orphaned",
             "deployed_not_merged", "deployed_not_merged_window_gone", "preempted",
             "prod_serving", "prod_withdrawn", "rolling_back", "blocked_queue",
             "blocked_freeze", "gates_indeterminate", "prod_unconverged",
             "preflight_abstain", "emergency_declared"]
    print("\nVISIT RATES (share of walks that reach the state at least once,"
          "\n             and mean visits per walk -- the second is the one to"
          "\n             compare against a window ledger)")
    print(f"  {'state':<34} {'reached':>8} {'visits/walk':>12}")
    for s in watch:
        print(f"  {s:<34} {ever[s]/n:>7.1%} {allvisits[s]/n:>12.2f}")

    print("\nTRIGGER KINDS, share of all transitions taken")
    tk_total = sum(allkinds.values())
    for tk, c in allkinds.most_common():
        print(f"  {tk:<16} {c/tk_total:>7.1%}")

    print("\nestate chain: recurrent, checked for dead ends and reachability, not walked.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
