#!/usr/bin/env python3
"""tally.py -- what a review costs, per agent, from the agents' own transcripts.

Companion to experiments/026-mainline-review (the review) and
experiments/017-token-metrics (the counting rule). One usage record per
streaming update, so every field is the MAX within a message id; the sum of
rows would count one call up to five times (017 F1).

    python3 experiments/027-review-cost/tally.py <label>=<transcript.jsonl|task.output> ...

Prints an org table: label, model, calls (distinct message ids), tool uses,
tokens by kind, and the cost at the rates in RATES (USD per million; edit
them when they change, they are not fetched).
"""
import collections, json, sys
RATES = {  # USD per 1M tokens: (input, output, cache read, cache write); Sonnet-class rows are approximate
    "opus":   (15.0, 75.0, 1.50, 18.75),
    "sonnet": ( 3.0, 15.0, 0.30,  3.75),
    "haiku":  ( 1.0,  5.0, 0.10,  1.25),
    "fable":  (15.0, 75.0, 1.50, 18.75),
}
def rate_for(model):
    m = (model or "").lower()
    for k in RATES:
        if k in m: return RATES[k]
    return RATES["opus"]
def tally(path):
    best, tools, model = {}, 0, None
    with open(path, errors="replace") as f:
        for line in f:
            try: d = json.loads(line)
            except Exception: continue
            m = d.get("message") if isinstance(d, dict) else None
            if not isinstance(m, dict): continue
            model = m.get("model") or model
            for c in (m.get("content") or []):
                if isinstance(c, dict) and c.get("type") == "tool_use": tools += 1
            u, mid = m.get("usage"), m.get("id")
            if not isinstance(u, dict) or not mid: continue
            cur = best.setdefault(mid, collections.Counter())
            for k in ("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"):
                v = u.get(k) or 0
                if isinstance(v, (int, float)) and v > cur[k]: cur[k] = int(v)
    t = collections.Counter()
    for c in best.values(): t.update(c)
    r = rate_for(model)
    usd = (t["input_tokens"]*r[0] + t["output_tokens"]*r[1] + t["cache_read_input_tokens"]*r[2] + t["cache_creation_input_tokens"]*r[3]) / 1e6
    return model, len(best), tools, t, usd
def main(args):
    print("| agent | model | calls | tool uses | input | output | cache read | cache write | total | USD |")
    print("|-------+-------+-------+-----------+-------+--------+------------+-------------+-------+-----|")
    grand = collections.Counter(); gusd = 0.0
    for a in args:
        label, path = a.split("=", 1) if "=" in a else (a, a)
        model, calls, tools, t, usd = tally(path)
        total = sum(t.values()); grand.update(t); gusd += usd
        print(f"| {label} | {model or '?'} | {calls} | {tools} | {t['input_tokens']:,} | {t['output_tokens']:,} | {t['cache_read_input_tokens']:,} | {t['cache_creation_input_tokens']:,} | {total:,} | {usd:.2f} |")
    print(f"| all | | | | {grand['input_tokens']:,} | {grand['output_tokens']:,} | {grand['cache_read_input_tokens']:,} | {grand['cache_creation_input_tokens']:,} | {sum(grand.values()):,} | {gusd:.2f} |")
if __name__ == "__main__":
    if len(sys.argv) < 2: print(__doc__); sys.exit(2)
    main(sys.argv[1:])
