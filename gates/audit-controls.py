#!/usr/bin/env python3
"""Audit the enforced controls against spec.org. Four reads, no UI visit.

  1. rulesets            repos/{r}/rulesets (+ each /rulesets/{id})
  2. workflow files      status-check names and concurrency groups (local)
  3. environments        repos/{r}/environments/{name}
  4. variables           repos/{r}/actions/variables

Three outcomes are kept distinct, because collapsing them is how an audit
lies: UNAVAILABLE (the API refused -- plan or permission), ABSENT (readable
and not configured), FINDING (configured and wrong). An audit that reports
"no findings" because it could not read anything is worse than no audit.

Runs against the live API, or against recorded JSON with --fixture, which
makes it hermetic and lets it be negative-tested.
"""
import argparse
import json
import pathlib
import subprocess
import sys

OK, FINDING, ABSENT, UNAVAIL = "ok", "FINDING", "ABSENT", "UNAVAILABLE"
GATES = {"gate-selftest", "lint", "test", "e2e"}


class Audit:
    def __init__(self):
        self.rows = []

    def add(self, status, control, detail):
        self.rows.append((status, control, detail))

    def report(self):
        width = max(len(c) for _, c, _ in self.rows)
        for status, control, detail in self.rows:
            mark = {OK: "ok  ", FINDING: "FAIL", ABSENT: "MISS", UNAVAIL: "N/A "}[status]
            print(f"{mark} {control:<{width}}  {detail}")
        f = sum(1 for s, _, _ in self.rows if s == FINDING)
        a = sum(1 for s, _, _ in self.rows if s == ABSENT)
        u = sum(1 for s, _, _ in self.rows if s == UNAVAIL)
        print(f"\n{len(self.rows) - f - a - u} ok, {f} findings, {a} absent, {u} unreadable")
        if u:
            print("NOTE: unreadable controls are NOT passes. The audit cannot "
                  "speak to them at all.", file=sys.stderr)
        return 2 if u else (1 if f or a else 0)


def gh(path, fixture=None):
    """Returns (data, error). error is a string when the read failed."""
    if fixture:
        p = pathlib.Path(fixture) / (path.replace("/", "_") + ".json")
        if not p.exists():
            return None, "no fixture"
        d = json.loads(p.read_text())
        return (None, d["message"]) if isinstance(d, dict) and "message" in d else (d, None)
    r = subprocess.run(["gh", "api", path], capture_output=True, text=True)
    if r.returncode != 0:
        try:
            return None, json.loads(r.stdout or "{}").get("message", r.stderr.strip())
        except json.JSONDecodeError:
            return None, r.stderr.strip() or "read failed"
    return json.loads(r.stdout), None


def audit_rulesets(a, repo, fixture):
    data, err = gh(f"repos/{repo}/rulesets", fixture)
    if err:
        for c in ("PR required", "status checks", "required deployments",
                  "linear history", "force-push / deletion", "bypass actors",
                  "enforcement active", "target branches"):
            a.add(UNAVAIL, c, err)
        return
    if not data:
        a.add(ABSENT, "rulesets", "no rulesets defined on this repo")
        return

    full = []
    for rs in data:
        d, e = gh(f"repos/{repo}/rulesets/{rs['id']}", fixture)
        if e:
            a.add(UNAVAIL, f"ruleset {rs['id']}", e)
        else:
            full.append(d)

    for rs in full:
        name = rs.get("name", "?")
        a.add(OK if rs.get("enforcement") == "active" else FINDING,
              "enforcement active",
              f"{name}: enforcement={rs.get('enforcement')}")

        inc = rs.get("conditions", {}).get("ref_name", {}).get("include", [])
        covered = "~DEFAULT_BRANCH" in inc or "refs/heads/main" in inc
        a.add(OK if covered else FINDING, "target branches", f"{name}: include={inc}")

        bypass = rs.get("bypass_actors", [])
        bad = [b for b in bypass if b.get("bypass_mode") != "always"]
        a.add(OK if not bypass else (FINDING if bad else OK), "bypass actors",
              "empty" if not bypass else
              f"{len(bypass)} actor(s); emergency path must be named and always-mode")

        by_type = {r["type"]: r for r in rs.get("rules", [])}

        pr = by_type.get("pull_request")
        if not pr:
            a.add(ABSENT, "PR required", "no pull_request rule; direct pushes possible")
        else:
            n = pr["parameters"].get("required_approving_review_count", 0)
            # >= 1 because itil:normal touches router/gates/change/.github and
            # needs a named change authority (spec.org, Labels).
            a.add(OK if n >= 1 else FINDING, "PR required",
                  f"approvals={n}" if n >= 1 else
                  f"approvals={n}; itil:normal would reach production unreviewed")

        sc = by_type.get("required_status_checks")
        if not sc:
            a.add(ABSENT, "status checks", "gates are not the change authority")
        else:
            ctx = {c["context"] for c in sc["parameters"]["required_status_checks"]}
            missing = GATES - ctx
            a.add(OK if not missing else FINDING, "status checks",
                  "all four gates required" if not missing else f"missing {sorted(missing)}")
            strict = sc["parameters"].get("strict_required_status_checks_policy")
            a.add(OK if strict else FINDING, "strict (guard 0 at merge)",
                  "branch must be current with base" if strict else
                  "not strict; a stale branch can merge")

        dep = by_type.get("required_deployments")
        if not dep:
            a.add(ABSENT, "required deployments", "staging not required before merge")
        else:
            envs = dep["parameters"]["required_deployment_environments"]
            a.add(OK if envs else FINDING, "required deployments", f"envs={envs}")

        for t, label in (("required_linear_history", "linear history"),
                         ("non_fast_forward", "force-push blocked"),
                         ("deletion", "deletion blocked")):
            a.add(OK if t in by_type else ABSENT, label,
                  "present" if t in by_type else "not enforced")


def audit_workflows(a, root):
    wf = pathlib.Path(root) / ".github" / "workflows"
    if not wf.exists():
        a.add(ABSENT, "workflows", "no .github/workflows")
        return
    text = {p.name: p.read_text() for p in wf.glob("*.yml")}

    # NO DEPLOY WORKFLOW IS ITS OWN ANSWER, not a deploy workflow missing a
    # setting. The forge-side deploy workflows were removed (ADR 0004): they
    # ran 249 times each and deployed nothing -- deploy-production.yml was
    # `skipped` on every one of its runs and never evaluated a single step.
    #
    # Reporting "production concurrency: absent" for a workflow that is not
    # there reads as a regression in a control, and it is not: the control was
    # never in force, because the thing it constrained never ran. What IS true
    # is that the forge does not serialize production at all, and that belongs
    # in the audit under its own name rather than disguised as a missing key.
    for env in ("production", "staging"):
        wfname = f"deploy-{env}.yml"
        body = text.get(wfname)
        if body is None:
            # OK, and the detail is the whole of the claim. ABSENT would read as
            # a control that regressed, and nothing regressed: this control was
            # never in force, because deploy-production.yml was `skipped` on all
            # 249 of its runs and never evaluated a step. The design no longer
            # asserts that the forge deploys, so the forge having no deploy
            # concurrency is the design and not a gap in it. Where the gap
            # actually is -- that serialization now rests on one label and one
            # person -- is ADR 0004's Consequences, which is a document a reader
            # consults, not a row that goes green and stops being read.
            a.add(OK, f"{env} deploy workflow",
                  f"none. The forge does not deploy to {env}, so it does not "
                  f"serialize it either; the berth is change/queue.sh guard 1 "
                  f"and a person (ADR 0004)")
            continue
        a.add(OK if "concurrency" in body else ABSENT,
              f"{env} concurrency (forge)",
              "serialized" if "concurrency" in body else "absent")
        if env == "production":
            a.add(OK if "cancel-in-progress: false" in body else FINDING,
                  "production not cancellable",
                  "cancel-in-progress: false" if "cancel-in-progress: false" in body
                  else "a cancelled production deploy leaves an indeterminate estate")
    a.add(OK if "main-moved.yml" in " ".join(text) or (wf / "main-moved.yml").exists()
          else FINDING, "guard 4b installed",
          "main-moved.yml present" if (wf / "main-moved.yml").exists()
          else "no workflow withdraws a staging pass when main moves")


def audit_environments(a, repo, fixture):
    data, err = gh(f"repos/{repo}/environments", fixture)
    if err:
        a.add(UNAVAIL, "environment protection", err)
        return
    names = {e["name"] for e in data.get("environments", [])}
    for want in ("staging", "production"):
        if want not in names:
            a.add(ABSENT, f"environment {want}", "not defined")
            continue
        d, e = gh(f"repos/{repo}/environments/{want}", fixture)
        if e:
            a.add(UNAVAIL, f"environment {want}", e)
            continue
        rules = d.get("protection_rules", [])
        kinds = {r["type"] for r in rules}
        if want == "production":
            a.add(OK if "required_reviewers" in kinds else FINDING,
                  "production reviewers",
                  "required" if "required_reviewers" in kinds else
                  "itil:normal can reach production unreviewed")
            wait = next((r for r in rules if r["type"] == "wait_timer"), None)
            a.add(OK if not wait or wait.get("wait_timer") == 0 else FINDING,
                  "production wait_timer",
                  "0" if not wait else str(wait.get("wait_timer")))
        pol = d.get("deployment_branch_policy")
        a.add(OK if pol else FINDING, f"{want} branch policy",
              "restricted" if pol else "any branch may deploy here")


def audit_variables(a, repo, fixture):
    data, err = gh(f"repos/{repo}/actions/variables", fixture)
    if err:
        a.add(UNAVAIL, "EMERGENCY_CHANGE variable", err)
        return
    names = {v["name"] for v in data.get("variables", [])}
    a.add(OK if "EMERGENCY_CHANGE" in names else ABSENT, "EMERGENCY_CHANGE variable",
          "present (freeze fallback when the calendar is unreachable)"
          if "EMERGENCY_CHANGE" in names else "no fallback; preflight exit 4 has no override")
    # A DECLARED TARGET MUST HAVE A DIRECTORY. DEPLOY_TARGET was `github` and
    # there has never been a targets/github/, which nothing noticed because the
    # only readers were the deploy workflows and they never ran. Declared-and-
    # absent is worse than undeclared: it reads as a configured choice.
    #
    # Undeclared is now the correct state. Nothing reads the variable: the
    # target is whichever targets/<x>/deploy.sh a person invokes (ADR 0004).
    if "DEPLOY_TARGET" not in names:
        a.add(OK, "DEPLOY_TARGET variable",
              "not declared, and nothing reads it -- the target is the script "
              "you invoke (ADR 0004)")
    else:
        val = next((v.get("value") for v in data["variables"]
                    if v["name"] == "DEPLOY_TARGET"), None)
        root_ = pathlib.Path(__file__).resolve().parent.parent
        tgt = root_ / "targets" / str(val) / "deploy.sh"
        a.add(OK if val and tgt.exists() else FINDING, "DEPLOY_TARGET variable",
              f"targets/{val}/deploy.sh" if val and tgt.exists()
              else f"declared `{val}`, and targets/{val}/deploy.sh does not exist")


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--repo", default="aygp-dr/standard-change")
    p.add_argument("--root", default=str(pathlib.Path(__file__).resolve().parent.parent))
    p.add_argument("--fixture", help="directory of recorded JSON instead of the API")
    args = p.parse_args()

    a = Audit()
    audit_rulesets(a, args.repo, args.fixture)
    audit_workflows(a, args.root)
    audit_environments(a, args.repo, args.fixture)
    audit_variables(a, args.repo, args.fixture)
    return a.report()


if __name__ == "__main__":
    sys.exit(main())
