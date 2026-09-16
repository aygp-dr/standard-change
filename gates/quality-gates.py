#!/usr/bin/env python3
"""quality-gates.py -- synthetic per-app quality gates, and what they cost.

NOT A PROPOSAL. This is an instrument for measuring the ORGANISATIONAL cost of
a maximal gate suite: every rule here is real, runs in milliseconds, and can be
broken by an ordinary edit. Whether any of them catches a real defect is out of
scope on purpose -- the question is what it costs to keep them green.

Each rule is a THRESHOLD SOMEBODY CHOSE. That is the whole point:

  * a threshold set at today's value makes every future change a regression
  * a threshold set with slack decays until the slack is gone
  * a threshold raised to make CI green has silently redefined the standard
  * nobody remembers who chose it, and the commit that did is years back

--calibrate writes thresholds at the CURRENT measured value, with zero slack.
That is the ratchet: from that moment any change that adds a line, a branch or
a parameter fails a gate. It is the cheapest way to make releasing nearly
impossible, and it is what a team does by accident when it adopts a suite and
"fixes the baseline" in one sitting.

Exit codes follow docs/exit-codes.org: 0 clean, 1 findings, 4 could not check.
"""
import argparse
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
THRESH = os.path.join(ROOT, "gates", "quality", "thresholds.tsv")

BRANCH = re.compile(r"\b(if|else if|for|while|case|catch|\?\?|\|\||&&|\?)\b|\?")
FUNC = re.compile(r"(?:function\s+\w+|\w+\s*=\s*\([^)]*\)\s*=>|\w+\s*\([^)]*\)\s*\{)")


def apps():
    d = os.path.join(ROOT, "apps")
    return sorted(a for a in os.listdir(d) if os.path.isdir(os.path.join(d, a)))


def srcs(app):
    p = os.path.join(ROOT, "apps", app, "src")
    out = []
    for dp, _, fs in os.walk(p):
        out += [os.path.join(dp, f) for f in fs if f.endswith(".js")]
    return sorted(out)


def tests(app):
    p = os.path.join(ROOT, "apps", app, "tests")
    out = []
    for dp, _, fs in os.walk(p):
        out += [os.path.join(dp, f) for f in fs if f.endswith(".js")]
    return sorted(out)


def lines(f):
    with open(f, encoding="utf-8", errors="replace") as fh:
        return fh.read().splitlines()


# ---------------------------------------------------------------- the measures
# Each returns a NUMBER for one app. Higher is worse unless the rule is min_*.
def m_max_line_length(app):
    return max((max((len(x) for x in lines(f)), default=0) for f in srcs(app)), default=0)


def m_max_file_lines(app):
    return max((len(lines(f)) for f in srcs(app)), default=0)


def m_total_src_lines(app):
    return sum(len(lines(f)) for f in srcs(app))


def m_max_func_lines(app):
    worst = 0
    for f in srcs(app):
        depth, start = 0, None
        for i, ln in enumerate(lines(f)):
            if FUNC.search(ln) and "{" in ln and start is None:
                start, depth = i, ln.count("{") - ln.count("}")
                continue
            if start is not None:
                depth += ln.count("{") - ln.count("}")
                if depth <= 0:
                    worst = max(worst, i - start + 1)
                    start = None
    return worst


def m_max_nesting(app):
    worst = 0
    for f in srcs(app):
        d = 0
        for ln in lines(f):
            d += ln.count("{") - ln.count("}")
            worst = max(worst, d)
    return worst


def m_branches(app):
    return sum(len(BRANCH.findall(ln)) for f in srcs(app) for ln in lines(f))


def m_todo(app):
    return sum(1 for f in srcs(app) for ln in lines(f)
               if re.search(r"\b(TODO|FIXME|XXX|HACK)\b", ln))


def m_console(app):
    return sum(1 for f in srcs(app) for ln in lines(f) if "console." in ln)


def m_max_params(app):
    worst = 0
    for f in srcs(app):
        for ln in lines(f):
            for mm in re.finditer(r"\(([^()]*)\)", ln):
                a = [x for x in mm.group(1).split(",") if x.strip()]
                worst = max(worst, len(a))
    return worst


def m_magic_numbers(app):
    n = 0
    for f in srcs(app):
        for ln in lines(f):
            if re.match(r"\s*(//|\*)", ln):
                continue
            n += len([x for x in re.findall(r"(?<![\w.])\d{2,}(?![\w.])", ln)
                      if x not in ("200", "404", "500", "301", "302", "400", "403")])
    return n


def m_dup_blocks(app):
    seen, dup = {}, 0
    for f in srcs(app):
        ls = [x.strip() for x in lines(f) if len(x.strip()) > 20]
        for i in range(len(ls) - 4):
            k = "\n".join(ls[i:i + 5])
            if k in seen:
                dup += 1
            seen[k] = 1
    return dup


def m_min_comment_pct(app):
    tot = com = 0
    for f in srcs(app):
        for ln in lines(f):
            s = ln.strip()
            if not s:
                continue
            tot += 1
            if s.startswith(("//", "/*", "*")):
                com += 1
    return int(100 * com / tot) if tot else 0


def m_min_test_ratio(app):
    s = m_total_src_lines(app)
    t = sum(len(lines(f)) for f in tests(app))
    return int(100 * t / s) if s else 0


def m_min_test_files(app):
    return len(tests(app))


MEASURES = {
    "max_line_length": m_max_line_length,
    "max_file_lines": m_max_file_lines,
    "max_func_lines": m_max_func_lines,
    "max_nesting": m_max_nesting,
    "max_branches": m_branches,
    "max_todo": m_todo,
    "max_console": m_console,
    "max_params": m_max_params,
    "max_magic_numbers": m_magic_numbers,
    "max_dup_blocks": m_dup_blocks,
    "min_comment_pct": m_min_comment_pct,
    "min_test_ratio": m_min_test_ratio,
    "min_test_files": m_min_test_files,
}


def load():
    if not os.path.exists(THRESH):
        return None
    out = {}
    with open(THRESH, encoding="utf-8") as fh:
        for ln in fh:
            if ln.startswith("#") or not ln.strip():
                continue
            app, rule, val, owner, since = (ln.rstrip("\n").split("\t") + [""] * 5)[:5]
            out[(app, rule)] = (int(val), owner, since)
    return out


def calibrate(slack):
    rows = []
    sha = subprocess.run(["git", "-C", ROOT, "rev-parse", "--short", "HEAD"],
                         capture_output=True, text=True).stdout.strip()
    for app in apps():
        for rule, fn in MEASURES.items():
            v = fn(app)
            t = max(0, v - slack) if rule.startswith("min_") else v + slack
            rows.append((app, rule, t, "unowned", sha))
    os.makedirs(os.path.dirname(THRESH), exist_ok=True)
    with open(THRESH, "w", encoding="utf-8") as fh:
        fh.write("# thresholds.tsv -- one row per app per rule. GENERATED by\n"
                 "# gates/quality-gates.py --calibrate. Every row is a number somebody\n"
                 "# chose; `owner` is who answers for it and `since` is the build it was\n"
                 "# measured on. Both are the maintenance cost made visible: a threshold\n"
                 "# with no owner is a gate nobody can raise, lower, or retire.\n"
                 "# app\trule\tthreshold\towner\tsince\n")
        for r in rows:
            fh.write("\t".join(str(x) for x in r) + "\n")
    return len(rows)


def evaluate():
    th = load()
    if th is None:
        return None, None
    findings, total = [], 0
    for app in apps():
        for rule, fn in MEASURES.items():
            if (app, rule) not in th:
                continue
            total += 1
            limit, owner, since = th[(app, rule)]
            v = fn(app)
            bad = v < limit if rule.startswith("min_") else v > limit
            if bad:
                findings.append((app, rule, v, limit, owner, since))
    return findings, total


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--calibrate", action="store_true",
                    help="write thresholds at current values -- the ratchet")
    ap.add_argument("--slack", type=int, default=0,
                    help="headroom to leave when calibrating (default 0)")
    ap.add_argument("--report", action="store_true", help="measured values, no verdict")
    args = ap.parse_args()

    if args.calibrate:
        n = calibrate(args.slack)
        print(f"wrote {n} thresholds at slack={args.slack} -> gates/quality/thresholds.tsv")
        if args.slack == 0:
            print("slack=0: any change that adds a line, a branch or a parameter now fails.")
        return 0

    if args.report:
        print(f"{'app':<10} {'rule':<20} {'value':>7}")
        for app in apps():
            for rule, fn in MEASURES.items():
                print(f"{app:<10} {rule:<20} {fn(app):>7}")
        return 0

    findings, total = evaluate()
    if findings is None:
        print("quality: no thresholds.tsv -- run --calibrate first", file=sys.stderr)
        print("  4 is not 0: nothing was checked (docs/exit-codes.org)", file=sys.stderr)
        return 4
    for app, rule, v, limit, owner, since in findings:
        op = "<" if rule.startswith("min_") else ">"
        print(f"  FAIL {app}/{rule}: {v} {op} {limit}  (owner={owner} since={since})")
    print(f"quality: {len(apps())} apps, {total} gates, {len(findings)} finding(s)")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
