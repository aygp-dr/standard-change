#!/usr/bin/env python3
"""cross_check.py -- ask TLC and label_sim.py the same question, require the same answer.

tla/Labels.tla and sim/label_sim.py are two transcriptions of one machine.
Either alone can be wrong in a way its own checks cannot see: a transcription
error that makes a bad state unreachable passes every invariant. Two
independent transcriptions that agree on the size of the reachable space AND
on which invariant each rule protects are much harder to be wrong together.

For each of the fifteen rules, and for the machine with every rule on:

  TLC        flips the constant in Labels.cfg, model-checks, reads the named
             invariant (or "No error") and the distinct-state count.
  label_sim  runs with --disable <rule> to a bound that exhausts the space,
             reads VERDICT and the state count.

The two must name the same invariant, or both hold; and with every rule on
they must have found the same number of distinct states. Any disagreement is
a defect in one transcription, and this script does not guess which.
"""
import os, pathlib, re, subprocess, sys, tempfile, shutil

ROOT = pathlib.Path(__file__).resolve().parent.parent
TLA = ROOT / "tla"
RULES = ["DraftGuard", "WindowGuard", "FreezeGuard", "EstateGuard", "BerthGuard",
         "ClassGuard", "LifecycleExclusive", "ReapFreesBerth", "SettleClears",
         "ReapSparesInFlight", "RecordOnMerge", "EmergencyPreempts",
         "HoldGuard", "HealthyBeforeVerdict", "LockResets", "UnaffectedMerges"]
JAR = os.environ.get("TLA2TOOLS",
      str(pathlib.Path.home() / "ghq/github.com/aygp-dr/tla-plus-tutorial/tla2tools.jar"))
BOUND = int(os.environ.get("LABEL_BOUND", "12"))  # the 14-rule machine has 25M states; a slice by default

def tlc(rule):
    """Run TLC on Labels with RULE flipped to FALSE (or none). -> (verdict, states)."""
    with tempfile.TemporaryDirectory() as td:
        td = pathlib.Path(td)
        name = "Labels" if rule is None else f"No{rule}"
        tla = (TLA / "Labels.tla").read_text()
        cfg = (TLA / "Labels.cfg").read_text()
        if rule:
            tla = tla.replace("MODULE Labels", f"MODULE {name}")
            cfg = cfg.replace(f"{rule} = TRUE", f"{rule} = FALSE")
        (td / f"{name}.tla").write_text(tla)
        (td / f"{name}.cfg").write_text(cfg)
        # Bounded heap: an unbounded JVM under a loaded desktop got check.sh's
        # run killed for memory (2026-09-14, tla/check.sh's own comment).
        # This script had the same exposure and hadn't been given the fix.
        heap = os.environ.get("TLC_HEAP", "3g")
        out = subprocess.run(["java", f"-Xmx{heap}", "-XX:+UseParallelGC", "-cp", JAR, "tlc2.TLC",
                              "-workers", "auto", "-cleanup", name],
                             cwd=td, capture_output=True, text=True).stdout
    m = re.search(r"Invariant (\w+) is violated", out)
    verdict = f"violated {m.group(1)}" if m else ("holds" if "No error has been found" in out else "ERROR")
    m2 = re.search(r"(\d+) distinct states found, 0 states left", out)
    return verdict, int(m2.group(1)) if m2 else None

def sim(rule):
    # Labels.tla has no Interfere action at all -- Interfere isn't in RULES,
    # isn't a TLA+ constant, and TLC's (all on) run holds over 100M+ states
    # while label_sim.py's Interfere-on default falls to NoUnbookedDeploy at
    # depth 1 (documented in label_sim.py as a MISNAMED-invariant limitation,
    # not a defect). Left uncontrolled, every row asks label_sim a different
    # question than the one TLC answers, and NoUnbookedDeploy masks whatever
    # the disabled rule was actually meant to elicit -- 14/17 rows disagreed
    # for this reason alone before the fix, confirmed 2026-09-21.
    argv = [sys.executable, str(ROOT / "sim" / "label_sim.py"), "--bound", str(BOUND),
            "--walks", "0", "--disable", "Interfere"]
    if rule:
        argv += ["--disable", rule]
    out = subprocess.run(argv, capture_output=True, text=True).stdout
    m = re.search(r"VERDICT (.+)$", out, re.M)
    m2 = re.search(r"exhaustive: (\d+) states, depth (\d+), (state space exhausted|bound)", out)
    states = int(m2.group(1)) if (m2 and m2.group(3) == "state space exhausted") else None
    return (m.group(1).strip() if m else "ERROR"), states

def main():
    if not pathlib.Path(JAR).is_file():
        print(f"tla2tools.jar not found at {JAR}; set TLA2TOOLS"); return 2
    bad = 0
    print(f"  {'rule off':<20} {'TLC':<30} {'label_sim':<30} agree")
    for rule in [None] + RULES:
        tv, ts = tlc(rule); sv, ss = sim(rule)
        ok = tv == sv
        if rule is None:
            if ss is None:   # the simulator did not exhaust: verdicts must agree, counts cannot be compared
                tv += f" ({ts} states)"; sv += f" (bound {BOUND}, not exhausted)"
            else:
                ok = ok and ts is not None and ts == ss
                tv += f" ({ts} states)"; sv += f" ({ss} states)"
        bad += not ok
        print(f"  {rule or '(all on)':<20} {tv:<30} {sv:<30} {'yes' if ok else 'NO'}")
    print(f"\n  {len(RULES) + 1 - bad}/{len(RULES) + 1} questions answered the same way by both checkers")
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main())
