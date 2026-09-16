#!/usr/bin/env python3
"""staging_entry_sim.py -- what gate flakiness costs the singleton staging berth.

Two models over one measured input, and they answer different questions.

  PER-CHECK   entry into staging is a CONJUNCTIVE chain: every check must pass,
              so a PR's odds are (1-f)**n, and n is not a constant -- it is set
              by the PR's app:* labels, because deploy installs the groups and
              e2e probes their routes. n is therefore a random variable with
              the distribution MEASURED from this repo's own 87 PRs.

  PER-BERTH   the berth (spec.org, Promotion pipeline) is a singleton. A change
              carrying release:start claims it opportunistically -- no calendar,
              "if it's free I'm deploying". What a red run does to the QUEUE
              depends on a policy choice this repo has never stated:

                HOLD     the author keeps the berth while debugging.
                         sim/simulate-gates.py assumes this ("a red run holds
                         the singleton berth while the author retries, so gate
                         flakiness converts directly into queue starvation").
                RELEASE  a red run frees the berth immediately; the author
                         debugs off-berth and re-queues behind everyone else.

The interesting quantity is not either throughput. It is the RATIO, which has a
closed form with no queueing theory in it at all -- see throughput_closed_form.

Every number printed as "analytic" is derived independently of the simulation.
--check asserts they agree, so the Monte Carlo is verified rather than trusted.
"""
import argparse
import heapq
import random
import statistics

# ---------------------------------------------------------------- measured input
#
# 87 PRs, every state, read 2026-09-15:
#   gh pr list --state all --limit 400 --json number,labels,state
#   jq -r '.[]|[.labels[].name|select(startswith("app:"))|ltrimstr("app:")]|sort|join("+")'
#
# This is the distribution IN PRACTICE, not a guess. It is strikingly bimodal:
# single-app changes dominate, and then there is a cluster that touches all four
# or all five at once. Nothing sits in between (one PR, ever, touched exactly
# two). That shape is the whole reason the mean is the wrong summary.
GROUP_SETS = [
    (("pdp",),                                    16),
    (("core",),                                   14),
    (("checkout",),                               13),
    (("plp",),                                    10),
    (("checkout", "core", "pdp", "plp"),           7),
    (("mock",),                                    2),
    (("checkout", "core", "mock", "pdp", "plp"),   2),
    (("pdp", "plp"),                               1),
    ((),                                          22),   # not a unit -- see below
]

# router/routes.json: what gates/e2e.sh actually probes, per app.
ROUTES = {"core": 8, "checkout": 3, "plp": 2, "mock": 2, "pdp": 1}

# .github/workflows/deploy-staging.yml, the steps between claim and verdict:
#   queue.sh claim (guards 0,1) | preflight (guard 3) | lock.sh acquire
#   schedule.sh block | deploy.sh | authorizing e2e
FIXED_STEPS = 6
# .github/workflows/gate.yml jobs -- the four names guard 4 requires green.
GATE_RUNS = 4


def check_count(groups, spec_shape=True):
    """Checks a PR must clear to enter staging.

    spec_shape=True  is spec.org:1574 and docs/deployment-targets.org:102 --
                     `deploy.sh <env> <groups...>`: work scales with the change.
    spec_shape=False is what targets/*/deploy.sh and gates/e2e.sh actually do --
                     both ignore the groups and process the whole estate, so n
                     is CONSTANT and a one-line change pays the same toll as a
                     five-app one.
    """
    if not spec_shape:
        return FIXED_STEPS + GATE_RUNS + len(ROUTES) + sum(ROUTES.values())
    return (FIXED_STEPS + GATE_RUNS + len(groups)
            + sum(ROUTES[g] for g in groups))


def population(units_only=True):
    """(groups, weight) pairs. units_only drops the 22 PRs with no app:* label.

    CLAUDE.md: "A unit is one pull request carrying at least one app:* label."
    A PR with none is not a unit and never enters staging, so conditioning on
    k>=1 is not a convenience -- the unconditional distribution describes a
    population that includes 22 changes which cannot reach the berth at all.
    """
    return [(g, w) for g, w in GROUP_SETS if not (units_only and not g)]


# ------------------------------------------------------------ per-check analytic
def analytic_pass_rate(f, spec_shape=True, units_only=True):
    """E[(1-f)**n] over the measured label distribution."""
    pop = population(units_only)
    tot = sum(w for _, w in pop)
    return sum(w * (1 - f) ** check_count(g, spec_shape) for g, w in pop) / tot


def mean_checks(spec_shape=True, units_only=True):
    pop = population(units_only)
    tot = sum(w for _, w in pop)
    return sum(w * check_count(g, spec_shape) for g, w in pop) / tot


def implied_per_check(target_pr_failure, spec_shape=True, units_only=True):
    """Per-check failure rate f such that the per-PR failure rate is the target.

    Bisection, because E[(1-f)**n] over a mixture has no closed inverse.
    """
    lo, hi = 0.0, 1.0
    for _ in range(200):
        mid = (lo + hi) / 2
        if 1 - analytic_pass_rate(mid, spec_shape, units_only) < target_pr_failure:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2


# ------------------------------------------------------------- berth closed form
def throughput_closed_form(f, hold, debug):
    """Greens per minute under each policy, and the ratio. No simulation.

    Attempts to green are Geometric(1-f), so E[attempts] = 1/(1-f).

      RELEASE  the berth is occupied only during attempts; debugging is
               off-berth.   berth-minutes per green = hold / (1-f)
      HOLD     every FAILED attempt additionally pins the berth for `debug`.
               E[failures per green] = f/(1-f).
               berth-minutes per green = hold + (f/(1-f)) * (hold + debug)

    The ratio collapses -- the queue, the arrival process and the backlog all
    cancel:

        RELEASE / HOLD  =  1 + f * debug / hold

    which is why this is worth stating as a rule rather than a chart: releasing
    the berth on red buys you a factor that depends ONLY on the failure rate and
    on how long debugging takes relative to a deploy. It never costs throughput.
    """
    per_green_release = hold / (1 - f)
    per_green_hold = hold + (f / (1 - f)) * (hold + debug)
    return {
        "release": 1 / per_green_release,
        "hold": 1 / per_green_hold,
        "ratio": per_green_hold / per_green_release,
        "ratio_identity": 1 + f * debug / hold,
    }


# ------------------------------------------------------------------ berth sim
def simulate_berth(n_prs, f, hold, debug, policy, rng, horizon=None):
    """Discrete-event: N backlogged PRs contend for one berth.

    Saturated on purpose. Every PR carries release:start and takes the berth the
    moment it is free -- the "if it's free I'm deploying" regime, no calendar,
    no window. That is the worst case for the berth and the only regime where
    the policy difference is visible rather than absorbed by idle time.
    """
    ready = list(range(n_prs))          # PRs eligible to claim the berth now
    rng.shuffle(ready)
    sleeping = []                       # (wake_time, pr) -- debugging off-berth
    attempts = [0] * n_prs
    done_at = [None] * n_prs
    now = 0.0
    busy_until = 0.0
    greens = 0
    berth_busy = 0.0

    while (ready or sleeping) and (horizon is None or now < horizon):
        if not ready:
            now = max(now, sleeping[0][0])
        while sleeping and sleeping[0][0] <= now:
            ready.append(heapq.heappop(sleeping)[1])
        if not ready:
            continue
        now = max(now, busy_until)
        pr = ready.pop(0)
        attempts[pr] += 1
        green = rng.random() >= f
        if green:
            busy_until = now + hold
            berth_busy += hold
            greens += 1
            done_at[pr] = busy_until
        elif policy == "release":
            busy_until = now + hold          # the attempt itself still ran
            berth_busy += hold
            heapq.heappush(sleeping, (busy_until + debug, pr))
        else:                                # hold: berth pinned through debug
            busy_until = now + hold + debug
            berth_busy += hold + debug
            heapq.heappush(sleeping, (busy_until, pr))

    finished = [d for d in done_at if d is not None]
    return {
        "greens": greens,
        "makespan": busy_until,
        "throughput": greens / busy_until if busy_until else 0.0,
        "utilisation": berth_busy / busy_until if busy_until else 0.0,
        "mean_attempts": statistics.mean([a for a, d in zip(attempts, done_at) if d]) if finished else 0.0,
        "mean_latency": statistics.mean(finished) if finished else 0.0,
        "p95_latency": (sorted(finished)[int(0.95 * len(finished)) - 1] if finished else 0.0),
    }


# --------------------------------------------------------------------- reporting
def hr(c="-"):
    print(c * 78)


def report(args, rng):
    print(__doc__.split("\n")[0])
    hr("=")

    print("\n1. THE MEASURED INPUT -- app:* labels across 87 PRs\n")
    print(f"   {'group set':<34} {'PRs':>4} {'checks n':>9}  (spec shape)")
    for g, w in sorted(GROUP_SETS, key=lambda x: -x[1]):
        name = "+".join(g) if g else "(no app label -- not a unit)"
        n = check_count(g) if g else 0
        print(f"   {name:<34} {w:>4} {n if g else '-':>9}")
    print(f"\n   units (k>=1): {sum(w for g, w in population())} of 87"
          f"   |  mean n = {mean_checks():.2f}"
          f"   |  range {min(check_count(g) for g, _ in population())}"
          f"-{max(check_count(g) for g, _ in population())}")
    print("   The 22 non-units are excluded: they carry no app:* label, so\n"
          "   CLAUDE.md says they are not units and they never reach the berth.")

    print("\n2. PER-CHECK MODEL -- 10% per check, over that distribution\n")
    f = args.per_check
    exact = analytic_pass_rate(f)
    naive = (1 - f) ** mean_checks()
    print(f"   E[(1-f)^n]  over the real mixture    {exact*100:>7.3f}%  pass")
    print(f"   (1-f)^E[n]  using the mean n         {naive*100:>7.3f}%  pass")
    print(f"   Jensen gap                           {(exact-naive)*100:>7.3f} points"
          f"  ({exact/naive:.2f}x)")
    print("\n   The mean is the wrong summary here and the gap says by how much.\n"
          "   x -> (1-f)^x is convex, so E[(1-f)^n] >= (1-f)^E[n] always; with a\n"
          "   bimodal n the two diverge instead of nearly agreeing. Single-app\n"
          "   changes carry the pass rate; the all-five changes are already lost.")
    print(f"\n   {'group set':<34} {'n':>4} {'P(clean entry)':>15}")
    for g, w in sorted(population(), key=lambda x: check_count(x[0])):
        n = check_count(g)
        print(f"   {'+'.join(g):<34} {n:>4} {(1-f)**n*100:>14.2f}%")

    print("\n3. WHAT THE 10-50% BAND IMPLIES\n")
    print("   The band in the question is a PER-PR failure rate. Inverting the\n"
          "   mixture gives the PER-CHECK reliability each one demands:\n")
    print(f"   {'per-PR failure':>15} {'implied per-check f':>21} {'per-check pass':>16}")
    for t in (0.10, 0.20, 0.30, 0.40, 0.50):
        pc = implied_per_check(t)
        print(f"   {t*100:>14.0f}% {pc*100:>20.3f}% {(1-pc)*100:>15.3f}%")
    print(f"\n   And the converse: f={f:.0%} per check is NOT in the band at all --\n"
          f"   it is a {(1-exact)*100:.1f}% per-PR failure rate. A 10% check is\n"
          "   catastrophic once n ~ 20; the band only exists above ~96.6% per check.")

    print("\n4. THE BERTH -- release:start, opportunistic, no calendar\n")
    print(f"   hold={args.hold}m per attempt, debug={args.debug}m before retry,"
          f" {args.prs} PRs, seed {args.seed}\n")
    print(f"   {'f':>5} {'policy':<8} {'thru/day':>9} {'analytic':>9} {'err':>7}"
          f" {'util':>6} {'tries':>6} {'mean lat':>9} {'p95 lat':>9}")
    rows = []
    for pct in args.sweep:
        fb = pct / 100
        cf = throughput_closed_form(fb, args.hold, args.debug)
        for policy in ("release", "hold"):
            r = simulate_berth(args.prs, fb, args.hold, args.debug, policy, rng)
            a = cf[policy] * 1440
            s = r["throughput"] * 1440
            err = abs(s - a) / a if a else 0
            rows.append((fb, policy, s, a, err, r))
            print(f"   {pct:>4}% {policy:<8} {s:>9.1f} {a:>9.1f} {err*100:>6.2f}%"
                  f" {r['utilisation']*100:>5.1f}% {r['mean_attempts']:>6.2f}"
                  f" {r['mean_latency']/60:>8.1f}h {r['p95_latency']/60:>8.1f}h")

    print("\n5. THE RATIO -- what releasing the berth on red actually buys\n")
    print(f"   {'f':>5} {'simulated':>11} {'closed form':>12} {'1 + f*debug/hold':>18}")
    for pct in args.sweep:
        fb = pct / 100
        cf = throughput_closed_form(fb, args.hold, args.debug)
        sr = [r for r in rows if r[0] == fb and r[1] == "release"][0][2]
        sh = [r for r in rows if r[0] == fb and r[1] == "hold"][0][2]
        print(f"   {pct:>4}% {sr/sh:>10.3f}x {cf['ratio']:>11.3f}x"
              f" {cf['ratio_identity']:>17.3f}x")
    print("\n   The queue cancels. The gain depends on nothing but the failure\n"
          "   rate and debug/hold -- not on arrival rate, backlog or ordering.\n"
          "   Releasing never costs throughput: the ratio is >= 1 for all f >= 0.")
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--prs", type=int, default=1000)
    ap.add_argument("--per-check", type=float, default=0.10)
    ap.add_argument("--hold", type=float, default=30.0,
                    help="berth minutes per attempt (schedule.sh block ... 30)")
    ap.add_argument("--debug", type=float, default=60.0,
                    help="minutes an author spends debugging before retrying")
    ap.add_argument("--sweep", type=int, nargs="+", default=[10, 20, 30, 40, 50])
    ap.add_argument("--seed", type=int, default=20260915)
    ap.add_argument("--check", action="store_true",
                    help="assert simulation matches the closed form, then exit")
    args = ap.parse_args()
    rng = random.Random(args.seed)

    if args.check:
        bad = []
        # (a) Jensen: E[(1-f)^n] >= (1-f)^E[n], with equality only if n is constant.
        for f in (0.01, 0.05, 0.10, 0.25):
            if analytic_pass_rate(f) < (1 - f) ** mean_checks() - 1e-12:
                bad.append(f"Jensen violated at f={f}")
        # (b) as-implemented n is constant, so there the two MUST coincide.
        for f in (0.01, 0.10):
            e = analytic_pass_rate(f, spec_shape=False)
            m = (1 - f) ** mean_checks(spec_shape=False)
            if abs(e - m) > 1e-12:
                bad.append(f"constant-n mixture disagrees with its own mean at f={f}")
        # (c) the closed-form ratio must equal its algebraic identity.
        for f in (0.1, 0.3, 0.5):
            cf = throughput_closed_form(f, 30, 60)
            if abs(cf["ratio"] - cf["ratio_identity"]) > 1e-9:
                bad.append(f"ratio identity broken at f={f}")
        # (d) the simulation must match the closed form within Monte Carlo error.
        for pct in (10, 30, 50):
            f = pct / 100
            for policy in ("release", "hold"):
                r = simulate_berth(4000, f, 30, 60, policy, random.Random(7))
                a = throughput_closed_form(f, 30, 60)[policy]
                if abs(r["throughput"] - a) / a > 0.05:
                    bad.append(f"sim vs analytic {policy} f={f}: "
                               f"{r['throughput']:.5f} vs {a:.5f}")
        # (e) mean attempts to green must be Geometric.
        for pct in (10, 50):
            f = pct / 100
            r = simulate_berth(4000, f, 30, 60, "release", random.Random(11))
            if abs(r["mean_attempts"] - 1 / (1 - f)) > 0.05:
                bad.append(f"attempts not geometric at f={f}")
        if bad:
            print("FAIL")
            for b in bad:
                print("  " + b)
            raise SystemExit(1)
        print("ok  staging-entry: Jensen, constant-n collapse, ratio identity, "
              "sim-vs-analytic, geometric attempts")
        return

    report(args, rng)


if __name__ == "__main__":
    main()
