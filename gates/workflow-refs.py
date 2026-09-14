#!/usr/bin/env python3
"""Does every script a workflow invokes exist?

THE DEFECT THIS EXISTS FOR. .github/workflows/deploy-staging.yml and
deploy-production.yml called change/lock.sh, change/pir.sh and
targets/*/rollback.sh. None of the three has ever existed in this repository.
deploy-production.yml also resolved its deploy script through
`targets/${{ vars.DEPLOY_TARGET }}/`, and the repository variable is set to
`github`, for which there is no targets/ directory either.

Nothing noticed, for a reason worth stating plainly: deploy-production.yml ran
249 times and every single run was `skipped`, so not one step was ever
evaluated. deploy-staging.yml ran 249 times -- 10 failures, 239 skipped, zero
successes -- and died at step 2 on a permissions error, four steps before the
first missing script. A workflow that never gets far enough to fail is
indistinguishable from one that works, and both look the same on the Actions
page.

That makes it the repo's seventh defect class -- a check that cannot fail
produces no verdict -- applied to the pipeline's own config: the config was
never executed, so it was never judged, and it was cited as evidence that the
pipeline exists.

WHAT IT CHECKS. For every workflow, every `./path/to/script` appearing in a
`run:` line must resolve to a file in the tree. A `${{ ... }}` inside such a
path is expanded from .github/config/variables.json when the expression is a
`vars.X` lookup, because that file is the declaration of what those variables
are; an expression it cannot resolve is reported as unresolvable rather than
skipped. Skipping it is how `targets/${{ vars.DEPLOY_TARGET }}/deploy.sh`
stayed invisible.

WHAT IT DOES NOT CHECK. Whether the arguments are right. That is a harder
problem and this gate does not pretend to it -- see the ADR for the separate
finding that both deploy workflows passed `$(./change/groups.sh "$PR")`, a
GROUP LIST, where deploy.sh's second argument is a SHA.

  ./gates/workflow-refs.py             check .github/workflows
  ./gates/workflow-refs.py --selftest  run against the fail/ fixture, which
                                       MUST be rejected, and the pass/ one,
                                       which must not be
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
VARS = ROOT / ".github" / "config" / "variables.json"

# `./x/y.sh`, `./x/y.py`, and the ${{ }} expressions that can appear inside one.
REF = re.compile(r"\.(?:/[\w.\-]+|/\$\{\{[^}]*\}\})+")
EXPR = re.compile(r"\$\{\{\s*([^}]*?)\s*\}\}")


def declared_vars(path=None):
    path = path or VARS
    if not path.exists():
        return {}
    data = json.loads(path.read_text())
    return {v["name"]: v["value"] for v in data.get("variables", [])}


def expand(ref, variables):
    """Substitute ${{ vars.X }}. Returns (expanded, unresolved-expression)."""
    unresolved = None

    def sub(m):
        nonlocal unresolved
        expr = m.group(1)
        if expr.startswith("vars.") and expr[5:] in variables:
            return variables[expr[5:]]
        unresolved = expr
        return "<?>"

    return EXPR.sub(sub, ref), unresolved


def scan(wf_dir, variables):
    findings = []
    for p in sorted(wf_dir.glob("*.yml")):
        text = p.read_text()
        for lineno, line in enumerate(text.splitlines(), 1):
            # Only `run:` bodies invoke scripts. A path inside a comment is
            # prose, and a gate that reads prose as code is the trap
            # gates/label-audit.py fell into.
            if line.lstrip().startswith("#"):
                continue
            for ref in REF.findall(line):
                if not ref.endswith((".sh", ".py", ".mjs")):
                    continue
                expanded, unresolved = expand(ref, variables)
                if unresolved is not None:
                    findings.append(
                        f"{p.name}:{lineno}: `{ref}` contains `{unresolved}`, "
                        f"which is not declared in .github/config/variables.json. "
                        f"An unresolvable path cannot be checked, and an "
                        f"unchecked path is how three missing scripts survived.")
                    continue
                target = ROOT / expanded.lstrip("./")
                if not target.exists():
                    findings.append(
                        f"{p.name}:{lineno}: `{ref}` -> `{expanded}` does not "
                        f"exist. The workflow cannot run past this line.")
    return findings


def main(argv):
    variables = declared_vars()
    if "--selftest" in argv:
        # BOTH DIRECTIONS. A gate that has never rejected anything is one
        # nobody has tested (spec.org, Verification contract).
        # THE FIXTURES DECLARE THEIR OWN VARIABLES. Reading the live
        # .github/config/variables.json here would couple the gate's negative
        # test to the repository's current configuration -- and it did: removing
        # DEPLOY_TARGET from that file (it named a targets/ directory that has
        # never existed) silently moved the fail/ fixture from the
        # "declared, and the directory is missing" branch to the "undeclared"
        # one, so a shape the gate is about stopped being exercised without
        # anything going red.
        fx = ROOT / "gates" / "fixtures" / "workflows"
        fxvars = declared_vars(fx / "variables.json")
        bad = scan(fx / "fail", fxvars)
        good = scan(fx / "pass", fxvars)
        rc = 0
        # EACH SHAPE, NOT MERELY A NON-EMPTY LIST. "the fixture was rejected"
        # is satisfied by catching one of the three and losing the other two,
        # which is how a suite goes on passing while the check it is about
        # quietly narrows. Deleting the target-exists branch, or the
        # unresolvable-expression branch, must each fail this.
        WANT = {
            "a script that has never existed":
                "`./change/lock.sh` -> `./change/lock.sh` does not exist",
            "an undeclared ${{ }} expression":
                "contains `env.NOT_DECLARED`",
            "a declared variable with no directory behind it":
                "-> `./targets/github/rollback.sh` does not exist",
        }
        joined = "\n".join(bad)
        missed = [k for k, needle in WANT.items() if needle not in joined]
        if missed:
            print("  FAIL workflow-refs: the fail/ fixture was not fully "
                  "rejected. Shapes this gate no longer catches:")
            for m in missed:
                print(f"    {m}")
            print("    A gate that catches some of what it is about produces "
                  "no verdict on the rest.")
            rc = 1
        else:
            print(f"  workflow-refs: rejects the fail/ fixture "
                  f"({len(bad)} findings, all three shapes)")
        if good:
            print("  FAIL workflow-refs: the pass/ fixture was rejected:")
            for f in good:
                print(f"    {f}")
            rc = 1
        else:
            print("  workflow-refs: accepts the pass/ fixture")
        return rc

    findings = scan(ROOT / ".github" / "workflows", variables)
    for f in findings:
        print(f"FAIL {f}")
    n = len(list((ROOT / ".github" / "workflows").glob("*.yml")))
    print(f"  workflow-refs: {n} workflows, {len(findings)} finding(s)")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
