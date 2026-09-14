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
    # itil:standard is the complement of itil:normal -- actions/labeler
    # cannot express "matched no other rule", so a workflow STEP must apply it.
    # Assert the step exists rather than assuming the behaviour: modelling it
    # here while the config lacked it is exactly how PRs #2 and #3 ended up
    # with app:* and no change:* at all.
    if (any(p.startswith(("apps/", "shared/", "external/")) for p in paths)
            and "itil:normal" not in got):
        if "classify standard vs normal" in WORKFLOW.read_text():
            got.add("itil:standard")
    return got


def sync_labels_enabled():
    return re.search(r"sync-labels:\s*true", WORKFLOW.read_text()) is not None


SCENARIOS = [
    ("L1",  ["apps/core/src/pages/index.js"], {"app:core", "itil:standard"}),
    ("L2",  ["apps/pdp/src/a.js", "apps/checkout/src/b.js"],
             {"app:pdp", "app:checkout", "itil:standard"}),
    ("L3",  ["apps/core/a", "apps/plp/a", "apps/pdp/a", "apps/checkout/a"],
             {"app:core", "app:plp", "app:pdp", "app:checkout", "itil:standard"}),
    ("L4",  ["router/nginx.conf.tmpl"], {"itil:normal"}),
    # An app change that also touches the control plane is BOTH: it deploys,
    # and it alters how future changes are verified. Neither fact excuses the
    # other, and the soak applies to the control-plane half.
    ("L5",  ["apps/plp/x.js", ".github/workflows/gate.yml"],
             {"app:plp", "itil:normal", "control-plane"}),
    ("L6",  ["README.org"], set()),
    ("L7",  ["apps/pdp/fixtures/catalog.json"], {"app:pdp", "itil:standard"}),
    ("L8",  ["gates/e2e.sh"], {"itil:normal", "control-plane"}),
    # control-plane is NARROWER than itil:normal. targets/ and router/ change
    # how a thing ships and are verified the ordinary way -- deploy, observe.
    # They are itil:normal and NOT control-plane.
    ("L16", ["targets/node/deploy.sh"], {"itil:normal"}),
    ("L17", ["router/server.js"], {"itil:normal"}),
    ("L18", ["change/guard4.sh"], {"itil:normal", "control-plane"}),
    ("L19", [".github/workflows/gate.yml"], {"itil:normal", "control-plane"}),
    # shared/ is imported by every app we deploy, so a change there is a change
    # to all of them and the manifest must say so. Before this rule existed,
    # editing shared/oneui.js produced NO app:* label -- the highest-blast-radius
    # change in the repo declaring it touched nothing deployable, and groups.sh
    # then returned empty so the queue refused it for entirely the wrong reason.
    ("L12", ["shared/oneui.js"],
             {"app:core", "app:plp", "app:pdp", "app:checkout", "itil:standard"}),
    # ...and mock does NOT come along. It is an external service stub under
    # external/, not something we deploy, so it does not pin our shared surface.
    ("L13", ["shared/oneui.js", "apps/core/x.js"],
             {"app:core", "app:plp", "app:pdp", "app:checkout", "itil:standard"}),
    # A shared/ change and an all-four-apps change carry the SAME labels, on
    # purpose. The label says what CI will do, not why it decided to.
    ("L15", ["apps/core/a", "apps/plp/a", "apps/pdp/a", "apps/checkout/a"],
             {"app:core", "app:plp", "app:pdp", "app:checkout", "itil:standard"}),
    # external/ is somebody else's service. Touching the stub is not a change to
    # any app of ours.
    ("L14", ["external/mock/src/server.js"], {"app:mock", "itil:standard"}),
]

# Removal scenarios: (before, after, label that must DISAPPEAR)
REMOVALS = [
    ("L9",  ["apps/pdp/a", "apps/checkout/b"], ["apps/pdp/a"], "app:checkout"),
    ("L11", ["apps/plp/x", ".github/w.yml"],   ["apps/plp/x"],  "itil:normal"),
]


# ---- the synchronize withdrawal ---------------------------------------------
#
# NOTHING IN THIS SUITE COVERED THE WITHDRAWAL. The old L12 grepped the whole
# workflow file for the string "staging:passed" and called that "the workflow
# drops stale verdicts on synchronize" -- which is satisfied by the label being
# mentioned anywhere, in any step, under any condition, with every removal
# swallowed. On #11 the withdrawal did not happen and this suite was green
# (issue #16).
#
# What the checks below assert is deliberately NOT "the withdrawal works" --
# no offline test can assert that, and the deeper repair was to stop guard 4
# depending on it (change/guard4.sh, gates/observation-test.sh). They assert the
# three properties that made the failure invisible:
#
#   it is a step, gated on synchronize, over a list that is actually complete
#   it can address the repository at all
#   it cannot report a failed withdrawal as success
#
# The instrument/recorder check is the other half: an observation that names
# no build is the thing #16 was about, so a gate that writes an observation
# LABEL must also write an observation RECORD.
OBSERVATIONS = [
    "staging:passed", "staging:failed",
    "staging:e2e", "staging:e2e-failed",
    "staging:smoke", "staging:smoke-failed",
    "staging:uat",
    "production:healthy",
    "production:e2e", "production:e2e-failed",
    "production:smoke", "production:smoke-failed",
]
RECORDERS = {"gates/e2e.sh": "e2e", "gates/smoke.sh": "smoke",
             "gates/health.sh": "healthy"}
WITHDRAWAL_IDS = ["W1", "W2", "W3", "W4", "W5", "W6"]


def withdrawal_step():
    """The text of the 'withdraw ... on a new push' step, and nothing else.

    Scoped on purpose: the previous check searched the whole file, so a
    mention in a comment satisfied it.
    """
    text = WORKFLOW.read_text()
    m = re.search(r"^      - name: withdraw[^\n]*\n(.*?)(?=^      - |\Z)",
                  text, re.S | re.M)
    return m.group(1) if m else None


def withdrawal_checks():
    fails = []
    step = withdrawal_step()

    # W1 -- the step exists and only runs on a push to the head.
    if step is None:
        return [f"{sid}: there is no 'withdraw ... on a new push' step in "
                f".github/workflows/labeller.yml" for sid in WITHDRAWAL_IDS]
    if "github.event.action == 'synchronize'" not in step:
        fails.append("W1: the withdrawal step is not gated on synchronize")

    # W2 -- it withdraws every observation, not a subset. production:healthy
    # was missing while gates/production-first.sh asserted in prose that this
    # step withdrew it on every push.
    missing = [l for l in OBSERVATIONS if l not in step]
    if missing:
        fails.append(f"W2: the withdrawal misses {' '.join(missing)}. A guard "
                     f"reading one of those reads a fact about an older build")

    # W3 -- a removal that fails must not report success. `|| true` on a label
    # removal turns "I could not withdraw a stale verdict" into a green step;
    # the same defect as merge-on-healthy recording unreachable as false.
    if re.search(r"--remove-label[^\n]*\|\|\s*true", step):
        fails.append("W3: a removal in the withdrawal step is swallowed by "
                     "`|| true`. An unwithdrawn stale verdict must be loud")

    # W4 -- this job never checks out, so `gh pr edit` has no repository to
    # resolve from git. Without --repo every removal fails, and with W3's
    # `|| true` it failed silently.
    if not re.search(r"gh pr edit[^\n]*--repo", step):
        fails.append("W4: `gh pr edit` in the withdrawal step has no --repo, "
                     "and this job has no checkout to infer one from")

    # W5 -- the step's exit status must depend on the removals.
    if not re.search(r"exit \$?\{?rc", step):
        fails.append("W5: the withdrawal step cannot fail; its exit status "
                     "does not depend on whether the removals succeeded")

    # W6 -- an instrument that writes an observation label must also write the
    # record that names the build it measured.
    for path, inst in RECORDERS.items():
        src = (ROOT / path).read_text()
        if "--add-label" not in src:
            continue
        if not re.search(r"evidence\.sh\"?\s+record\b", src):
            fails.append(f"W6: {path} writes an observation label but records "
                         f"no observation naming the build it measured")
        elif re.search(r"evidence\.sh\"?\s+record[^\n]*\|\|\s*true", src):
            fails.append(f"W6: {path} swallows a failure to record its "
                         f"observation. An unrecorded measurement is not one")
    return fails


def groups_from_stdin():
    """--groups: read changed paths on stdin, print the app groups they deploy.

    THE POINT IS THAT THERE IS ONLY ONE GLOB ENGINE. gates/production-first.sh
    has to know what a change deploys BEFORE the labeller has labelled anything
    (issue #29): the check runs on `opened`, actions/labeler writes the labels
    seconds later, and a label written by GITHUB_TOKEN cannot trigger the
    re-run that would correct the verdict. So the guard must derive the answer
    from the diff itself.

    Deriving it a second time, by hand, in shell, is how two readers of the
    same rule end up disagreeing -- the defect change/groups.sh's own header
    warns about. So the derivation is done HERE, by the same load_rules() /
    label_for() the labeller's oracle uses, against the same
    .github/labeler.yml the labeller runs. Change a glob and both move
    together, or SCENARIOS fails.

    Output is one group per line, sorted, `app:` stripped -- the shape
    change/groups.sh already returns.
    """
    paths = [l.strip() for l in sys.stdin if l.strip()]
    got = label_for(load_rules(), paths)
    for label in sorted(got):
        if label.startswith("app:"):
            print(label[len("app:"):])
    return 0


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

    fails += withdrawal_checks()

    for f in fails:
        print(f"FAIL {f}")
    print(f"{len(SCENARIOS) + len(REMOVALS) + 1 + len(WITHDRAWAL_IDS) - len(fails)} "
          f"passed, {len(fails)} failed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(groups_from_stdin() if "--groups" in sys.argv[1:] else main())
