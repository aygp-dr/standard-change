#!/usr/bin/env python3
"""Simulate the gate suite, and what its flakiness does to the berth.

A PR run is green only if EVERY check passes, so the suite's reliability is
p**n, not p. The interesting consequence is not the pass rate: it is that a red
run holds the singleton berth (spec.org, Promotion pipeline) while the author
retries, so gate flakiness converts directly into queue starvation.

Deterministic under --seed so it can be a regression test rather than a demo.
"""
import argparse
import random
import statistics


def run_suite(n, p, rng):
    """One PR attempt. Returns (green, failed_check_indices)."""
    fails = [i for i in range(n) if rng.random() >= p]
    return (not fails), fails


def phase(label, n, p, runs, rng, berth_minutes=30):
    greens, attempts_to_green, held = 0, [], []
    tries = 0
    for _ in range(runs):
        tries += 1
        green, _ = run_suite(n, p, rng)
        if green:
            greens += 1
            attempts_to_green.append(tries)
            tries = 0
    analytic = p ** n
    empirical = greens / runs
    mean_attempts = statistics.mean(attempts_to_green) if attempts_to_green else float("inf")
    # A berth is held from first claim until a green run releases it.
    berth = mean_attempts * berth_minutes
    return {
        "label": label, "n": n, "p": p,
        "analytic": analytic, "empirical": empirical,
        "attempts": mean_attempts, "berth": berth,
        "throughput": (60 / berth) if berth else 0,
    }


def fmt(r):
    return (f"{r['label']:<28} {r['n']:>3}  {r['p']*100:>5.1f}%  "
            f"{r['analytic']*100:>6.2f}%  {r['empirical']*100:>6.2f}%  "
            f"{r['attempts']:>6.2f}  {r['berth']:>7.0f}m  {r['throughput']:>6.2f}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--runs", type=int, default=20000)
    ap.add_argument("--seed", type=int, default=20260913)
    ap.add_argument("--berth-minutes", type=int, default=30)
    ap.add_argument("--check", action="store_true",
                    help="assert the simulation matches the closed form, then exit")
    ap.add_argument("--rerun-until-green", type=int, default=0,
                    help="allow this many re-runs of failed checks only")
    args = ap.parse_args()
    rng = random.Random(args.seed)

    phases_def = [("phase 1: 5 checks @ 80%", 5, 0.80),
                  ("phase 2: 20 checks @ 95%", 20, 0.95)]
    if args.check:
        # Verify the verifier: a Monte Carlo that agrees with nothing external
        # is just asserting its own output. Tolerance is ~4 sigma of the
        # binomial standard error at this run count.
        bad = []
        for label, n, p in phases_def:
            r = phase(label, n, p, args.runs, rng, args.berth_minutes)
            se = (r["analytic"] * (1 - r["analytic"]) / args.runs) ** 0.5
            if abs(r["empirical"] - r["analytic"]) > 4 * se:
                bad.append(f"{label}: sim {r['empirical']:.4f} vs p^n "
                           f"{r['analytic']:.4f} (4se={4*se:.4f})")
        # and the closed form itself against hand-computed values
        for got, want, what in ((0.80 ** 5, 0.32768, "0.8^5"),
                                (0.95 ** 20, 0.3584859224085419, "0.95^20")):
            if abs(got - want) > 1e-12:
                bad.append(f"{what}: {got} != {want}")
        for b in bad:
            print(f"FAIL {b}")
        print("simulate-gates: closed form and simulation agree" if not bad
              else f"{len(bad)} failures")
        return 1 if bad else 0

    print(f"{'phase':<28} {'n':>3}  {'p':>6}  {'p^n':>7}  {'sim':>7}  "
          f"{'tries':>6}  {'berth':>8}  {'PR/hr':>6}")
    print("-" * 88)
    phases = phases_def
    results = [phase(l, n, p, args.runs, rng, args.berth_minutes) for l, n, p in phases]
    for r in results:
        print(fmt(r))

    a, b = results
    print()
    print(f"Moving from {a['n']} checks at {a['p']*100:.0f}% to "
          f"{b['n']} at {b['p']*100:.0f}%:")
    print(f"  per-check reliability  {a['p']*100:.0f}% -> {b['p']*100:.0f}%  "
          f"(+{(b['p']-a['p'])*100:.0f} points)")
    print(f"  suite reliability      {a['analytic']*100:.1f}% -> "
          f"{b['analytic']*100:.1f}%  ({(b['analytic']-a['analytic'])*100:+.1f} points)")
    print(f"  queue throughput       {a['throughput']:.2f} -> {b['throughput']:.2f} PR/hr")

    # What per-check reliability would 20 checks need to match 5 checks at 80%?
    need = a["analytic"] ** (1 / b["n"])
    print(f"\n  To hold the line at {a['analytic']*100:.1f}% suite-green with "
          f"{b['n']} checks, each must pass {need*100:.2f}% of the time.")
    print(f"  To reach 90% suite-green with {b['n']} checks: "
          f"{0.90 ** (1/b['n'])*100:.2f}% per check.")
    print(f"  To reach 99% suite-green with {b['n']} checks: "
          f"{0.99 ** (1/b['n'])*100:.3f}% per check.")

    print(f"\n--- re-run policy: re-run only the FAILED checks, up to k times ---")
    print(f"{'phase':<28} {'k=0':>8} {'k=1':>8} {'k=2':>8} {'k=3':>8}")
    for label, n, p in phases:
        cells = []
        for k in range(4):
            # a flaky check gets k+1 independent chances
            cells.append(f"{(1 - (1 - p) ** (k + 1)) ** n * 100:7.2f}%")
        print(f"{label:<28} " + " ".join(cells))

    print()
    print("  The ranking INVERTS. With no re-runs the two suites are within 3")
    print("  points of each other; with one re-run of failed checks only, 20 at")
    print("  95% reaches 95.1% green while 5 at 80% reaches 81.5%. A 95% flake")
    print("  recovers on retry far more reliably than an 80% one, so the answer")
    print("  is not fewer checks -- it is more checks plus granular re-run.")
    print()
    print("  The cost is that re-running is indistinguishable from flipping a")
    print("  coin until it lands. A deterministically broken check never passes")
    print("  at any k, so re-runs buy throughput against FLAKE and nothing")
    print("  against BREAKAGE -- but only while the two can be told apart. A")
    print("  suite that cannot tell them apart has stopped being an oracle")
    print("  (spec.org, Verification contract), and 'just re-run it' is the")
    print("  sound a gate makes while it decays into a formality.")
    print()
    print("  Hence: re-run FAILED CHECKS, never the whole suite. Re-running the")
    print("  suite re-rolls the checks that already passed, which is how a green")
    print("  run gets manufactured out of a genuinely red one.")
    print_balance()


def emergency_pressure(berth_wait_h, patience_h=4.0, base_rate=0.05):
    """Fraction of changes that route to change:emergency as the queue slows.

    Over-protecting the queue does not trade safety for speed -- it trades
    safety for safety. change:emergency is the ONE label that bypasses
    staging, so every hour of avoidable berth wait pushes changes onto the
    path with fewer checks. Logistic in wait/patience; base_rate is the
    genuinely-urgent floor.
    """
    import math
    return base_rate + (1 - base_rate) / (1 + math.exp(-(berth_wait_h - patience_h)))


def print_balance():
    print("\n--- the balance: queue friction converts into emergency traffic ---")
    print(f"{'mean berth wait':>16}  {'emergency share':>16}  {'changes bypassing staging':>26}")
    for h in (0.5, 1, 2, 4, 8, 16):
        e = emergency_pressure(h)
        bar = "#" * int(e * 40)
        print(f"{h:>14.1f}h  {e*100:>15.1f}%  {bar}")
    print()
    print("  The queue and the calendar are INSTRUMENTS. Production is the")
    print("  objective. Every minute the berth is held for a reason unrelated")
    print("  to production safety is pure cost -- and past roughly a working")
    print("  half-day of wait, it stops being merely cost: changes start")
    print("  routing to change:emergency, which is the one path that skips")
    print("  staging entirely. Tighten the queue far enough and you have")
    print("  optimised your way to LESS production safety, through the only")
    print("  door you left open.")


if __name__ == "__main__":
    import sys
    sys.exit(main() or 0)
