#!/usr/bin/env python3
"""Audit one or more repos for conformance to the pipeline's rules.

gates/audit-controls.py asks "are the controls this ONE repo claims actually
enforced?". This asks a different question, and the one that matters once the
model is applied to more than one repo:

    Does this repo run the pipeline at all, and does it run it correctly?

Four outcomes are kept, as ever: ok / FINDING / ABSENT / UNAVAILABLE. A repo we
cannot read is not a repo that passed.

  ./gates/audit-conformance.py                       # this repo
  ./gates/audit-conformance.py --repos a/b,c/d
  ./gates/audit-conformance.py --org aygp-dr --limit 20
"""
import argparse
import json
import subprocess
import sys

OK, FINDING, ABSENT, UNAVAIL = "ok", "FINDING", "ABSENT", "UNAVAILABLE"
MARK = {OK: "ok  ", FINDING: "FAIL", ABSENT: "MISS", UNAVAIL: "N/A "}

# The workflows the pipeline is made of. A repo missing one is not running the
# model, whatever its labels say.
WORKFLOWS = {
    "labeller.yml":           "derives app:* and change:* from the diff",
    "gate.yml":               "the change authority — produces the four check runs",
    "promote.yml":            "guard 2 before deploy:production",
    "deploy-staging.yml":     "the berth and the authorizing run",
    "deploy-production.yml":  "guards 2, 4, 4b and 5",
    "main-moved.yml":         "guard 4b when trunk moves",
}

# The labels the state machine transitions through. Named by kind, because a
# repo with request labels and no observation labels is running something else.
LABELS = {
    "release:started":  "request — the only one a person adds",
    "itil:standard":   "derived",
    "itil:normal":     "derived",
    "itil:emergency":  "request — the authorized bypass",
    "deploy:staging":    "action in flight",
    "deploy:production": "action in flight",
    "staging:passed":    "observation",
    "production:healthy": "observation",
    "blocked:queue":     "observation",
}

# Guard 2 must be evaluated on BOTH paths: promote.yml is gated on
# staging:passed, which the emergency path never reaches.
GUARD2_FILES = ["promote.yml", "deploy-production.yml"]


def gh(path, jq=None):
    cmd = ["gh", "api", path] + (["--jq", jq] if jq else [])
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        try:
            return None, json.loads(r.stdout or "{}").get("message", r.stderr.strip()[:70])
        except json.JSONDecodeError:
            return None, (r.stderr.strip() or "read failed")[:70]
    return (r.stdout.strip(), None)


def audit(repo):
    rows = []
    add = rows.append

    # -- the workflows
    listing, err = gh(f"repos/{repo}/contents/.github/workflows", ".[].name")
    if err:
        add((UNAVAIL, "workflows", err))
        present = set()
    else:
        present = set(listing.splitlines())
        for wf, why in WORKFLOWS.items():
            add((OK, f"workflow {wf}", why) if wf in present
                else (ABSENT, f"workflow {wf}", f"missing — {why}"))

    # -- guard 2 on both paths
    for f in GUARD2_FILES:
        if f not in present:
            continue
        body, e = gh(f"repos/{repo}/contents/.github/workflows/{f}", ".content")
        if e:
            add((UNAVAIL, f"guard 2 in {f}", e)); continue
        import base64
        txt = base64.b64decode(body).decode("utf-8", "replace")
        add((OK, f"guard 2 in {f}", "check-runs queried")
            if "check-runs" in txt else
            (FINDING, f"guard 2 in {f}",
             "no check-run query — guard 2 is not evaluated on this path"))

    # -- the label vocabulary
    labels, err = gh(f"repos/{repo}/labels?per_page=100", ".[].name")
    if err:
        add((UNAVAIL, "labels", err))
    else:
        have = set(labels.splitlines())
        missing = [l for l in LABELS if l not in have]
        add((OK, "label vocabulary", f"all {len(LABELS)} present") if not missing
            else (ABSENT, "label vocabulary", f"missing {', '.join(missing)}"))
        # a repo carrying deploy:* but no observation labels is running a
        # command-driven pipeline, not this one
        if "deploy:staging" in have and "production:healthy" not in have:
            add((FINDING, "label kinds",
                 "action labels without observation labels — transitions are "
                 "driven by commands, not evidence"))

    # -- every app directory needs a labeller rule, or its changes deploy
    #    unlabelled. PR #7 touched apps/mock and got itil:standard with no
    #    app:mock, because the rule was never added when the app was.
    apps, e1 = gh(f"repos/{repo}/contents/apps", ".[].name")
    cfg, e2 = gh(f"repos/{repo}/contents/.github/labeler.yml", ".content")
    if e1 or e2:
        add((UNAVAIL, "labeller covers every app", e1 or e2))
    else:
        import base64
        text = base64.b64decode(cfg).decode("utf-8", "replace")
        uncovered = [a for a in apps.splitlines() if f"app:{a}:" not in text]
        add((OK, "labeller covers every app", f"{len(apps.splitlines())} apps")
            if not uncovered else
            (FINDING, "labeller covers every app",
             f"no rule for {', '.join(uncovered)} — their changes deploy unlabelled"))

    # -- enforced controls (may legitimately be unreadable)
    rs, err = gh(f"repos/{repo}/rulesets", "length")
    add((UNAVAIL, "ruleset enforcement", err) if err else
        (OK, "ruleset enforcement", f"{rs} ruleset(s)") if rs != "0" else
        (ABSENT, "ruleset enforcement", "main is unprotected"))

    envs, err = gh(f"repos/{repo}/environments", ".total_count")
    add((UNAVAIL, "environments", err) if err else
        (OK, "environments", f"{envs} defined") if envs != "0" else
        (ABSENT, "environments", "no staging/production environment"))
    return rows


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--repos", default="aygp-dr/standard-change")
    p.add_argument("--org")
    p.add_argument("--limit", type=int, default=10)
    a = p.parse_args()

    if a.org:
        out, err = gh(f"orgs/{a.org}/repos?per_page={a.limit}", ".[].full_name")
        if err:
            out, err = gh(f"users/{a.org}/repos?per_page={a.limit}", ".[].full_name")
        if err:
            print(f"cannot list repos for {a.org}: {err}", file=sys.stderr)
            return 2
        repos = out.splitlines()
    else:
        repos = [r.strip() for r in a.repos.split(",") if r.strip()]

    worst = 0
    for repo in repos:
        rows = audit(repo)
        f = sum(1 for s, _, _ in rows if s == FINDING)
        m = sum(1 for s, _, _ in rows if s == ABSENT)
        u = sum(1 for s, _, _ in rows if s == UNAVAIL)
        print(f"\n\033[1m{repo}\033[0m  "
              f"{len(rows)-f-m-u} ok, {f} findings, {m} absent, {u} unreadable")
        width = max(len(c) for _, c, _ in rows)
        for st, ctl, detail in rows:
            print(f"  {MARK[st]} {ctl:<{width}}  {detail}")
        worst = max(worst, 2 if u else (1 if f or m else 0))
    return worst


if __name__ == "__main__":
    sys.exit(main())
