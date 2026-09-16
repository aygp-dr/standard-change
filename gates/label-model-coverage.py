#!/usr/bin/env python3
"""Every declared label must exist in a MODEL before it exists in the pipeline.

THE RULE, stated by the reviewer on 2026-09-15:

    We should be able to prototype the addition or removal of any label by
    first changing the simulator and the TLA+, and require that before
    changing the underlying pipeline and shell scripts.

WHY IT IS WORTH A GATE. Every label defect this repository has produced came
from a label that existed in the shell scripts and in nobody's model:

  - change:emergency was written in spec.org 23 times and declared nowhere;
    gates/preflight.sh matches with `grep -cx`, so a change labelled the way
    the spec specified would not have matched the code that read it.
  - change:failed and change:backed-out were owned by change/abort.sh and DID
    NOT EXIST ON THE FORGE, so every abort silently failed to record its
    outcome (`|| true`).
  - staging:deployed, staging:healthy, production:deployed, change:end and
    staging:hold were live on the forge for hours before any declaration.
  - hold:staging is declared REJECTED and is still enforced in three scripts.

A model is cheap to change and refuses loudly. A shell script is expensive to
change and fails open. Putting the model first is not ceremony; it is choosing
which artifact discovers the mistake.

    python3 gates/label-model-coverage.py            audit
    python3 gates/label-model-coverage.py --selftest both directions

Exit 0 clean, 1 findings.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DECL = ROOT / "change" / "label-owners.tsv"
MODELS = [ROOT / "sim" / "label_sim.py", ROOT / "sim" / "pipeline_sim.py",
          ROOT / "tla" / "Labels.tla", ROOT / "tla" / "StandardChange.tla"]

# A label whose whole job is to be absent from the running pipeline. A model
# need not carry it, and requiring one would be asking the model to represent
# a thing the pipeline is forbidden to produce.
TOMBSTONE_OWNERS = {"RETIRED", "REJECTED"}


def declared() -> list[tuple[str, str]]:
    out = []
    for line in DECL.read_text().splitlines():
        if line.startswith("#") or "\t" not in line:
            continue
        f = line.split("\t")
        if f[0] == "exclusive" or len(f) < 2:
            continue
        out.append((f[0], f[1]))
    return out


def model_text() -> str:
    return "\n".join(p.read_text() for p in MODELS if p.exists())


def ident(label: str) -> list[str]:
    """The spellings a model may legitimately use for one label.

    TLA+ cannot contain a colon in an identifier, so `staging:e2e` is
    `stagingE2e` or `StagingE2E` there. Accepting only the literal string
    would fail every TLA model by construction -- a check that cannot pass is
    as useless as one that cannot fail.
    """
    ns, _, rest = label.partition(":")
    parts = re.split(r"[-_]", rest) if rest else []
    camel = ns + "".join(p.capitalize() for p in parts)
    if not rest:
        return [label, ns]
    # A model may also name the state BARE inside a set keyed by namespace --
    # `Lifecycle == {"requested", "scheduled", "abandoned"}` in TLA, and
    # LIFE_LABELS in the simulator. That is the natural form in both and
    # demanding the prefixed spelling would fail every well-written model.
    # Quoted, so a bare word in prose does not count.
    bare = f'"{rest}"'
    return [label, camel, camel[0].upper() + camel[1:], bare]


def audit(labels, text):
    missing = []
    for lab, owner in labels:
        if owner in TOMBSTONE_OWNERS:
            continue
        if lab.endswith("*"):          # a glob: look for the namespace
            if lab.rstrip(":*") not in text:
                missing.append((lab, owner))
            continue
        if not any(s in text for s in ident(lab)):
            missing.append((lab, owner))
    return missing


def selftest() -> int:
    labs = [("staging:e2e", "gates/e2e.sh"), ("itil:standard", "labeller")]
    bad = 0
    cases = [
        ("a label present literally is accepted", labs[:1], "staging:e2e appears here", 0),
        ("a label present in TLA camelCase is accepted", labs[:1], "stagingE2e == TRUE", 0),
        ("a label in NO model is reported", labs[:1], "nothing relevant", 1),
        ("a tombstoned label is not required", [("staging:passed", "RETIRED")], "", 0),
        ("two missing labels are both reported", labs, "nothing", 2),
    ]
    for name, l, txt, want in cases:
        got = len(audit(l, txt))
        ok = got == want
        print(f"  {'ok  ' if ok else 'BAD '} {name:<46} -> {got} missing, wanted {want}")
        bad += 0 if ok else 1
    print(f"  label-model-coverage self-test: {len(cases)} cases, {bad} wrong")
    return 1 if bad else 0


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()
    labs = declared()
    missing = audit(labs, model_text())
    live = [l for l, o in labs if o not in TOMBSTONE_OWNERS]
    print(f"  {len(live)} live labels declared; {len(MODELS)} model files read")
    for lab, owner in missing:
        print(f"  FAIL {lab:<24} owner={owner:<22} in no model")
    print(f"  {len(missing)} label(s) in the pipeline and in no model")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
