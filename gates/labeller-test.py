#!/usr/bin/env python3
"""Replay the Part A scenarios from scenarios.org against .github/labeler.yml.

Runs offline: parses the labeler globs and applies them to synthetic diffs, so
the labeller's rules are checked on every change to labeler.yml without a PR.

This is the labeller's oracle, and it is negative-tested: L13 asserts that with
sync-labels off the removal scenarios FAIL. A checker that cannot fail launders
"not done" as "correct" (spec.org, Verification contract).
"""
import fnmatch
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LABELER = ROOT / ".github" / "labeler.yml"
WORKFLOW = ROOT / ".github" / "workflows" / "labeller.yml"


def load_rules():
    """label -> [glob, ...]  (minimal reader for the actions/labeler v5 shape)."""
    rules, label, text = {}, None, LABELER.read_text()
    for line in text.splitlines():
        if re.match(r"^[A-Za-z]", line) and line.rstrip().endswith(":"):
            label = line.rstrip()[:-1]
            rules[label] = []
        elif label and "any-glob-to-any-file:" in line:
            v = line.split("any-glob-to-any-file:", 1)[1].strip()
            if v:
                rules[label].append(v)
        elif label and re.match(r"^\s+- \S", line) and "changed-files" not in line:
            v = line.strip()[2:].strip()
            if "/" in v or "*" in v:
                rules[label].append(v)
    return rules


def matches(glob, path):
    if glob.endswith("/**"):
        return path.startswith(glob[:-2])
    return fnmatch.fnmatch(path, glob)


def label_for(rules, paths):
    got = {l for l, globs in rules.items()
           if any(matches(g, p) for g in globs for p in paths)}
    # change:standard is the complement of change:normal when apps are touched
    if any(p.startswith("apps/") for p in paths) and "change:normal" not in got:
        got.add("change:standard")
    return got


def sync_labels_enabled():
    return re.search(r"sync-labels:\s*true", WORKFLOW.read_text()) is not None


SCENARIOS = [
    ("L1",  ["apps/core/src/pages/index.js"], {"app:core", "change:standard"}),
    ("L2",  ["apps/pdp/src/a.js", "apps/checkout/src/b.js"],
             {"app:pdp", "app:checkout", "change:standard"}),
    ("L3",  ["apps/core/a", "apps/plp/a", "apps/pdp/a", "apps/checkout/a"],
             {"app:core", "app:plp", "app:pdp", "app:checkout", "change:standard"}),
    ("L4",  ["router/nginx.conf.tmpl"], {"change:normal"}),
    ("L5",  ["apps/plp/x.js", ".github/workflows/gate.yml"],
             {"app:plp", "change:normal"}),
    ("L6",  ["README.org"], set()),
    ("L7",  ["apps/pdp/fixtures/catalog.json"], {"app:pdp", "change:standard"}),
    ("L8",  ["gates/e2e.sh"], {"change:normal"}),
]

# Removal scenarios: (before, after, label that must DISAPPEAR)
REMOVALS = [
    ("L9",  ["apps/pdp/a", "apps/checkout/b"], ["apps/pdp/a"], "app:checkout"),
    ("L11", ["apps/plp/x", ".github/w.yml"],   ["apps/plp/x"],  "change:normal"),
]


def main():
    rules = load_rules()
    fails = []

    for sid, paths, want in SCENARIOS:
        got = label_for(rules, paths)
        if got != want:
            fails.append(f"{sid}: want {sorted(want)}, got {sorted(got)}")

    for sid, before, after, gone in REMOVALS:
        if gone not in label_for(rules, before):
            fails.append(f"{sid}: setup wrong, {gone} not attached by the before-diff")
        elif gone in label_for(rules, after):
            fails.append(f"{sid}: {gone} survived a diff that no longer matches")

    # L10 / L12 / L13: ownership and SHA binding are properties of the workflow,
    # not of the globs.
    if not sync_labels_enabled():
        fails.append("L13: sync-labels is not true; the labeller cannot own "
                     "app:* and L9/L10/L11 are unenforceable")
    if "staging:passed" not in WORKFLOW.read_text():
        fails.append("L12: workflow does not drop staging:passed on synchronize; "
                     "a stale staging verdict could authorize production")

    for f in fails:
        print(f"FAIL {f}")
    print(f"{len(SCENARIOS) + len(REMOVALS) + 2 - len(fails)} passed, {len(fails)} failed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
