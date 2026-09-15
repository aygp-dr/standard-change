#!/usr/bin/env python3
"""Derive the token metrics for the 2026-09-13/14 release night.

The companion to experiments/016-dora. DORA asks what the pipeline did;
this asks what it cost to drive. The standing guardrail it implements is
wharfinger #6's: RECORD COST PER UNIT.

Reads only data/usage.tsv, a snapshot captured read-only from the session
transcript by capture.sh and committed alongside this script, so the numbers
are reproducible without the 30MB transcript.

    python3 experiments/017-token-metrics/derive.py

THE COUNTING RULE, and it is the whole reason this file exists:

  A transcript writes one usage record per streaming update, not one per API
  call. 4,291 rows carry 2,171 distinct message ids. Summing rows counts the
  same call up to five times. Every field is therefore taken as the MAX within
  a message id, never the sum -- the records for one id are successive
  snapshots of one call's running total, so the last (largest) one IS the call.

  docs/time-spent.org shipped the naive sum, 2,245,451,282. It is 1.9x the
  truth. This is spec.org's defect class 2 -- superseded is not current --
  wearing different clothes: the same defect that let guard 2 count a
  superseded check run as a verdict. A number that is the sum of its own
  revisions is not a measurement of anything.

A metric that cannot be derived from the captured data prints UNDERIVABLE and
says what is missing, rather than estimating.
"""

from __future__ import annotations

import csv
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Final

DATA: Final[Path] = Path(__file__).parent / "data" / "usage.tsv"

# Units the night actually delivered. Counted from the forge, not from this
# transcript, because "what shipped" is a fact about the estate and "what it
# cost" is a fact about the driver; keeping them in one place is how the two
# get conflated. Captured 2026-09-14 from aygp-dr/standard-change.
UNITS_MERGED: Final[int] = 22
DEPLOYMENTS: Final[int] = 42

# Price is NOT measured here. Opus list rates are an input, not an observation,
# so they live in one place, marked, and every dollar figure prints the rate it
# used. [H] -- not verified against an invoice in this session.
RATE_PER_MTOK: Final[dict[str, float]] = {
    "input": 15.00,
    "cache_write": 18.75,   # 1h TTL writes are priced above 5m; see note below
    "cache_read": 1.50,
    "output": 75.00,
}


@dataclass
class Call:
    """One API call, reassembled from its successive transcript snapshots."""
    model: str = "-"
    sidechain: bool = False
    first_seen: str = ""
    last_seen: str = ""
    inp: int = 0
    cache_write: int = 0
    cache_read: int = 0
    out: int = 0
    thinking: int = 0

    @property
    def total(self) -> int:
        return self.inp + self.cache_write + self.cache_read + self.out


def load() -> tuple[dict[str, Call], int]:
    """Collapse rows to calls. Returns (calls, rows_read)."""
    calls: dict[str, Call] = defaultdict(Call)
    rows = 0
    with DATA.open() as fh:
        for r in csv.reader(fh, delimiter="\t"):
            if len(r) < 9:
                continue
            rows += 1
            mid, ts, model, side, i, cw, cr, o, th = r[:9]
            c = calls[mid]
            c.model = model
            c.sidechain = side == "true"
            c.first_seen = min(c.first_seen or ts, ts)
            c.last_seen = max(c.last_seen, ts)
            # max, never +=. See the counting rule in the docstring.
            c.inp = max(c.inp, int(i))
            c.cache_write = max(c.cache_write, int(cw))
            c.cache_read = max(c.cache_read, int(cr))
            c.out = max(c.out, int(o))
            c.thinking = max(c.thinking, int(th))
    return calls, rows


def money(c: dict[str, int]) -> float:
    return sum(c[k] / 1e6 * RATE_PER_MTOK[k] for k in RATE_PER_MTOK)


def fmt(n: int) -> str:
    return f"{n:,}"


def head(s: str) -> None:
    print(f"\n{s}\n{'-' * len(s)}")


def main() -> None:
    calls, rows = load()
    naive = defaultdict(int)
    with DATA.open() as fh:
        for r in csv.reader(fh, delimiter="\t"):
            if len(r) < 9:
                continue
            naive["input"] += int(r[4])
            naive["cache_write"] += int(r[5])
            naive["cache_read"] += int(r[6])
            naive["output"] += int(r[7])

    true = {
        "input": sum(c.inp for c in calls.values()),
        "cache_write": sum(c.cache_write for c in calls.values()),
        "cache_read": sum(c.cache_read for c in calls.values()),
        "output": sum(c.out for c in calls.values()),
    }
    thinking = sum(c.thinking for c in calls.values())
    total = sum(true.values())
    naive_total = sum(naive.values())

    t0 = min(c.first_seen for c in calls.values())
    t1 = max(c.last_seen for c in calls.values())
    span_h = (
        datetime.fromisoformat(t1.replace("Z", "+00:00"))
        - datetime.fromisoformat(t0.replace("Z", "+00:00"))
    ).total_seconds() / 3600

    head("T0  COUNTING METHOD -- the metric about the metric")
    print(f"  transcript rows            {fmt(rows)}")
    print(f"  distinct API calls         {fmt(len(calls))}")
    print(f"  rows per call              {rows / len(calls):.2f}")
    print(f"  naive sum of rows          {fmt(naive_total)}")
    print(f"  deduped (max within id)    {fmt(total)}")
    print(f"  OVERSTATEMENT              {naive_total / total:.2f}x"
          f"  ({fmt(naive_total - total)} tokens that were never spent)")
    print("  Every number below uses the deduped count.")

    head("T1  COST PER UNIT -- wharfinger #6's standing guardrail")
    print(f"  total tokens               {fmt(total)}")
    print(f"  units merged               {UNITS_MERGED}")
    print(f"  PER UNIT                   {fmt(total // UNITS_MERGED)} tokens")
    print(f"  deployments                {DEPLOYMENTS}")
    print(f"  PER DEPLOYMENT             {fmt(total // DEPLOYMENTS)} tokens")
    print(f"  at list rates              ${money(true):,.2f} total, "
          f"${money(true) / UNITS_MERGED:,.2f} per unit  [H: rates unverified]")

    head("T2  WHAT THE SPEND WAS MADE OF")
    for k in ("cache_read", "cache_write", "input", "output"):
        print(f"  {k:<24} {fmt(true[k]):>15}  {true[k] / total * 100:5.1f}%"
              f"   ${true[k] / 1e6 * RATE_PER_MTOK[k]:>9,.2f}")
    print(f"  {'(of output: thinking)':<24} {fmt(thinking):>15}"
          f"  {thinking / true['output'] * 100:5.1f}% of output")
    print("\n  Read the table by cost, not by volume: cache_read is "
          f"{true['cache_read'] / total * 100:.1f}% of the tokens and")
    print(f"  {true['cache_read'] / 1e6 * RATE_PER_MTOK['cache_read'] / money(true) * 100:.1f}%"
          " of the money, while output is "
          f"{true['output'] / total * 100:.2f}% of the tokens and "
          f"{true['output'] / 1e6 * RATE_PER_MTOK['output'] / money(true) * 100:.1f}% of the money.")

    head("T3  CACHE EFFICIENCY -- the economic analogue of lead time")
    served = true["cache_read"]
    presented = true["cache_read"] + true["cache_write"] + true["input"]
    print(f"  context presented          {fmt(presented)}")
    print(f"  served from cache          {fmt(served)}  ({served / presented * 100:.2f}%)")
    print(f"  written to cache           {fmt(true['cache_write'])}"
          f"  ({true['cache_write'] / presented * 100:.2f}%)")
    print(f"  reuse ratio                {served / true['cache_write']:.1f} reads per write")
    print("  A long single session is the cheap shape: the estate's state was")
    print("  re-presented on every one of the", fmt(len(calls)), "calls and paid for once.")

    head("T4  DRIVING RATE")
    print(f"  wall clock                 {span_h:.1f}h  ({t0} -> {t1})")
    print(f"  calls                      {fmt(len(calls))}   ({len(calls) / span_h:.0f}/h)")
    print(f"  tokens                     {fmt(int(total / span_h))}/h")
    print(f"  output                     {fmt(int(true['output'] / span_h))}/h")
    print(f"  units                      {UNITS_MERGED / span_h:.2f}/h")

    head("T5  DELEGATED SPEND -- PARTIALLY DERIVABLE")
    side = [c for c in calls.values() if c.sidechain]
    deleg, done, running = [], 0, 0
    with (Path(__file__).parent / "data" / "delegated.tsv").open() as fh:
        next(fh)
        for line in fh:
            f = line.rstrip("\n").split("\t")
            if f[2] == "-":
                running += 1
            else:
                done += 1
                deleg.append((f[1], int(f[2]), int(f[3])))
    known = sum(t for _, t, _ in deleg)
    print(f"  sidechain calls in THIS ledger    {len(side)}")
    print("  A subagent's calls are not in the coordinator's transcript, so")
    print("  the figures above are the COORDINATOR'S cost and nothing else.")
    print("  But the dispatch record is not empty: each completed agent reports")
    print("  a total at completion. What it reports, and what it does not:")
    for name, tok, tools in deleg:
        print(f"    {name:<40} {fmt(tok):>10} tok, {tools} tool uses")
    print(f"  delegated, completed ({done})       {fmt(known)}")
    print(f"  delegated, still running ({running})    UNDERIVABLE -- no total until it stops")
    print(f"  coordinator                        {fmt(total)}")
    print(f"  ratio, as printed                  {known / (total + known) * 100:.3f}%")
    print()
    print("  DO NOT READ THAT RATIO. It is two different units divided by each")
    print("  other. The coordinator figure is 99.5% cache reads; 188,885 tokens")
    print("  for 73 tool uses over 16 minutes cannot be -- a cached agent that")
    print("  busy would show tens of millions. The reported total is almost")
    print("  certainly billable-ish tokens with cache reads excluded or counted")
    print("  once. Set against the coordinator's non-cache-read spend")
    print(f"  ({fmt(total - true['cache_read'])}), delegation is"
          f" {known / (total - true['cache_read'] + known) * 100:.1f}% -- a"
          " three-order-of-magnitude")
    print("  swing that depends entirely on which unit you picked, and NOTHING")
    print("  in the record says which one it is. That is the finding: the two")
    print("  ledgers do not share a denominator, so the sum of them is not a")
    print("  quantity. This is defect class 3 -- observation is not intent --")
    print("  and class 6: a verdict must name its build. A token count must")
    print("  name its counting rule or it cannot be added to another one.")
    print()
    print("  Two things that total CANNOT do, and both matter:")
    print("   1. It has no breakdown. One integer, no cache/input/output split,")
    print("      and those differ in price by 50x. It can be counted and cannot")
    print("      be PRICED. A cost-per-unit built on it is a volume metric")
    print("      wearing a dollar sign.")
    print("   2. It arrives only at completion. Three agents are running now and")
    print("      report nothing, so at any instant the live total is unknowable")
    print("      -- which is the read-after-write race from the guard work, in")
    print("      the ledger: 'not there' and 'not there YET' read identically.")
    print()
    print("  So the honest statement of the night's spend is a BOUND, not a")
    print("  number: at least", fmt(total + known), "tokens, coordinator priced")
    print("  and delegation not. Defect class 1 -- unreachable is not falsified.")
    print("  FIX: schema.sql makes ledger_id NOT NULL and gives subagent ledgers")
    print("  a mandatory parent, so delegated spend is a row that is missing")
    print("  rather than a number that is quietly small.")


if __name__ == "__main__":
    main()
