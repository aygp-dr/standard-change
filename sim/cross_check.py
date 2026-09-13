#!/usr/bin/env python3
"""cross_check.py -- make the simulator and the TLA+ module disagree out loud.

docs/changing-the-pipeline.org counts the encodings of this state machine:

    tla/Concurrent.tla, gates/pbt-pipeline.py, sim/pipeline_sim.py and the
    shell scripts -- "four independent encodings of the same state machine,
    and no mechanism keeps them in agreement. They drift silently, and the
    drift is only discovered when someone runs the real thing and squints at
    the output."

This is a mechanism. For every property, it asks sim/label_sim.py and
tla/Labels.tla the same question under the same assumptions and requires the
same answer. A disagreement is a finding about one of them -- and the whole
point of the exercise is that it is not known in advance which.

It has already earned its keep twice:

  1. ClassAtMostOne. The module stated the declared cardinality over the LABEL
     SET and found it violated; the simulator stated it over preflight's
     verdict and found it holding. Both were true of different properties, and
     the simulator's was too weak -- it was hiding #2. Split into
     ClassAtMostOne and NoUndefinedClassMoves, in both.
  2. The self-grading oracle. Both encodings wired the EstateBlocks switch into
     the rule AND into the observer of the rule, so turning the rule off also
     turned off the ability to notice. Both negative runs passed, meaninglessly.
     Found in the simulator first, then looked for -- and found -- in the
     module. It is guard 5's defect in a model.

USAGE
  ./sim/cross_check.py            every property, as-is and repaired
  ./sim/cross_check.py --quick    the decisive property only
"""
from __future__ import annotations

import argparse
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TLA = ROOT / "tla"
JAR = pathlib.Path(os.environ.get(
    "TLA2TOOLS",
    pathlib.Path.home() / "ghq/github.com/aygp-dr/tla-plus-tutorial/tla2tools.jar"))

sys.path.insert(0, str(ROOT / "sim"))
import label_sim as L                                   # noqa: E402

# Each row: the property, the simulator repair that establishes it, and the
# TLA+ constant that establishes it. "as-is" means every repair off, which is
# the repository today; "repaired" means the one repair on.
#
# The two columns are what makes this a cross-check rather than two reports:
# they are the SAME assumption expressed in two languages, so the two verdicts
# have to match or one of the encodings is wrong about the pipeline.
PROPERTIES = [
    # property                      sim repair            TLA+ constant
    ("ClassAtMostOne",              "class-exclusive",    "ClassExclusive"),
    ("NoUndefinedClassMoves",       None,                 "ClassConflictRefused"),
    ("LifecycleAtMostOneActive",    "lifecycle-replaces", "LifecycleReplaces"),
    ("ClassifiedBeforeDeploy",      "class-required",     "ClassRequired"),
    ("BerthSingleton",              None,                 "BerthMutex"),
    ("OrdinaryChangeWaits",         None,                 "EstateBlocks"),
    ("DeclaringABlockDoesNotExempt", "estate-emergency",  "SeparateEmergency"),
    ("EmergencyNeverWaits",         "emergency-preempts", "EmergencyPreempts"),
    ("ControlPlaneSoaks",           "soak",               "Soak"),
]

# Constants whose TRUE value the simulator ALWAYS assumes, because the scripts
# implement them: they are rules preflight and queue.sh really have. The
# "as-is" TLA+ run must therefore leave these TRUE while flipping the rest.
ALWAYS_ON = {"ClassConflictRefused", "BerthMutex", "EstateBlocks"}


def tlc(constants, invariant, tag):
    """Run TLC on Labels.tla with one invariant and one constant assignment."""
    cfg = TLA / ("X%s.cfg" % tag)
    mod = TLA / ("X%s.tla" % tag)
    base = (TLA / "Labels.cfg").read_text()
    body = []
    for line in base.splitlines():
        m = re.match(r"\s*(\w+)\s*=\s*(TRUE|FALSE)\s*(\\\*.*)?$", line)
        if m and m.group(1) in constants:
            body.append("    %s = %s" % (m.group(1), constants[m.group(1)]))
        elif line.strip().startswith("INVARIANT"):
            body.append("INVARIANT %s" % invariant)
        else:
            body.append(line)
    cfg.write_text("\n".join(body) + "\n")
    mod.write_text((TLA / "Labels.tla").read_text()
                   .replace("MODULE Labels", "MODULE X%s" % tag))
    try:
        out = subprocess.run(
            ["java", "-XX:+UseParallelGC", "-cp", str(JAR), "tlc2.TLC",
             "-cleanup", "X%s" % tag],
            cwd=TLA, capture_output=True, text=True, timeout=900).stdout
    finally:
        for f in (cfg, mod):
            f.unlink(missing_ok=True)
        for f in TLA.glob("X%s_TTrace_*" % tag):
            f.unlink(missing_ok=True)
    if "Invariant %s is violated" % invariant in out:
        return True
    if "No error has been found" in out:
        return False
    raise RuntimeError("TLC said neither: %s" % out[-600:])


def sim_violations(repair, budget):
    _, v, trunc = L.sweep(L.Rules("none", repair or "none"), L.declaration(),
                          2, budget=budget)
    if trunc:
        raise RuntimeError("simulator hit the state cap; the run proves nothing")
    return set(v)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--budget", type=int, default=2)
    a = ap.parse_args()
    if not JAR.exists():
        print("tla2tools.jar not found; set TLA2TOOLS", file=sys.stderr)
        return 1

    rows = ([p for p in PROPERTIES if p[0] == "DeclaringABlockDoesNotExempt"]
            if a.quick else PROPERTIES)

    print("  sim/label_sim.py vs tla/Labels.tla -- the same question, twice\n")
    print("  %-30s %-22s %-22s %s" % ("property", "AS-IS (sim / tla)",
                                      "REPAIRED (sim / tla)", ""))
    print("  " + "-" * 88)

    asis_sim = sim_violations(None, a.budget)
    asis_const = {c: ("TRUE" if c in ALWAYS_ON else "FALSE")
                  for _, _, c in PROPERTIES}

    rc, n = 0, 0
    for prop, repair, const in rows:
        n += 1
        s_asis = prop in asis_sim
        t_asis = tlc(asis_const, prop, "a%d" % n)
        if repair:
            s_rep = prop in sim_violations(repair, a.budget)
            c = dict(asis_const)
            c[const] = "TRUE"
            t_rep = tlc(c, prop, "r%d" % n)
        else:
            # No repair: the rule is already in the scripts, so the meaningful
            # second column is the MUTATION -- turn the rule off and require
            # both to notice. Same shape, opposite direction.
            mut = {"NoUndefinedClassMoves": "no-class-conflict",
                   "BerthSingleton": "no-berth-mutex",
                   "OrdinaryChangeWaits": "no-freeze"}[prop]
            _, v, _ = L.sweep(L.Rules(mut, "none"), L.declaration(), 2,
                              budget=a.budget)
            s_rep = prop in set(v)
            # FROM THE AS-IS BASELINE, not from all-repairs-on. The constants
            # are NOT independent and mutating from the wrong baseline
            # manufactures a disagreement: with ClassExclusive = TRUE no PR can
            # ever carry two classes, so switching off preflight's refusal of a
            # two-class change leaves nothing for it to refuse and the module
            # reports `holds` while the simulator -- which mutates from as-is --
            # reports VIOL. That is the third time this project has hit the
            # coupling; tla/check.sh records the first, between Guard4b and
            # ProdFirst, in a comment at the top of the file.
            c = dict(asis_const)
            c[const] = "FALSE"
            t_rep = tlc(c, prop, "m%d" % n)

        def cell(s, t):
            return "%-9s %-9s" % ("VIOL" if s else "holds",
                                  "VIOL" if t else "holds")
        ok = (s_asis == t_asis) and (s_rep == t_rep)
        print("  %-30s %-22s %-22s %s"
              % (prop, cell(s_asis, t_asis), cell(s_rep, t_rep),
                 "agree" if ok else "*** DISAGREE ***"))
        if not ok:
            rc = 1

    print()
    if rc:
        print("  DISAGREEMENT. One of the two encodings is wrong about the")
        print("  pipeline, and which one is not decided by this table -- read")
        print("  the counterexample and the scripts. Historically in this")
        print("  project the implementation was right about half the time.")
    else:
        print("  the simulator and the model agree on every property, in both")
        print("  directions. That is not proof either is right about the shell")
        print("  scripts -- it is the removal of one of the four ways they")
        print("  could silently drift (docs/changing-the-pipeline.org).")
    return rc


if __name__ == "__main__":
    sys.exit(main())
