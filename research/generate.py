#!/usr/bin/env python3
"""generate.py -- the appendix tables the paper cites and never showed.

Writes research/appendix/{label-table,scenario-index,issue-index}.org from
change/label-owners.tsv, scenarios.org and the forge, so the numbers in the
paper come from the tree at build time and not from memory (L7 review,
2026-09-15: four disagreeing rule counts, D21 cited before it is listed).
"""
import csv, pathlib, re, subprocess, datetime
ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "research" / "appendix"; OUT.mkdir(exist_ok=True)
today = datetime.date.today().isoformat()
sha = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()

# 1. the label table
rows = []
for line in (ROOT / "change" / "label-owners.tsv").read_text().splitlines():
    if not line or line.startswith("#"): continue
    f = line.split("\t")
    if len(f) < 6: continue
    label, owner, persistent, hadd, hclear, desc = f[0], f[1], f[2], f[3], f[4], f[5]
    desc = re.sub(r"\s+", " ", desc.split(". ")[0])[:110]
    rows.append(f"| ={label}= | {owner} | {persistent} | {hadd} | {hclear} | {desc} |")
(OUT / "label-table.org").write_text(
f"""#+TITLE: The label table, as declared
#+DATE: {today}

Generated from =change/label-owners.tsv= at ={sha}= by =research/generate.py=.
{len(rows)} labels. A label with no row here has no owner and cannot be trusted
(=findings/label-ownership.org=). Columns: persistent (survives settlement),
a person may add, a person may clear; the first sentence of the declaration.

| label | writer | persistent | person adds | person clears | says |
|-------+--------+------------+-------------+---------------+------|
""" + "\n".join(rows) + "\n")

# 2. the scenario index
scen = []
for m in re.finditer(r"^\*+ ((?:L|D)\d+)\s*[-–—:]*\s*(.*)$", (ROOT / "scenarios.org").read_text(), re.M):
    scen.append(f"| {m.group(1)} | {m.group(2).strip()[:120]} |")
(OUT / "scenario-index.org").write_text(
f"""#+TITLE: The scenario index
#+DATE: {today}

Generated from =scenarios.org= at ={sha}=. L-scenarios are the lifecycle
catalogue; D-scenarios are the defect and run reports. The paper cites them by
id; this is the one-line meaning of each.

| id | scenario |
|----+----------|
""" + "\n".join(scen) + "\n")

# 3. the issue index
try:
    js = subprocess.run(["gh", "issue", "list", "--repo", "aygp-dr/standard-change", "--state", "all", "--limit", "300",
                         "--json", "number,state,title"], capture_output=True, text=True, timeout=60).stdout
    import json
    issues = sorted(json.loads(js), key=lambda x: x["number"])
    irows = [f"| #{i['number']} | {i['state'].lower()} | {i['title'][:110].replace('—', '--').replace('|', '\\vert')} |" for i in issues]
except Exception as e:
    irows = [f"| - | - | issue index not generated: {e} |"]
(OUT / "issue-index.org").write_text(
f"""#+TITLE: The issue index
#+DATE: {today}

Generated from the forge at build time. The paper cites issues by number; a
reader elsewhere has no tracker, so this is the one-line meaning of each.

| issue | state | title |
|-------+-------+-------|
""" + "\n".join(irows) + "\n")
print(f"appendix: {len(rows)} labels, {len(scen)} scenarios, {len(irows)} issues at {sha}")
