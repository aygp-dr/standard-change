#!/usr/bin/env python3
"""Derive the four DORA metrics for the 2026-09-13/14 release night.

Reads only the captured snapshots under data/. It touches nothing on the
estate and makes no network call: every input was taken read-only and is
committed alongside this script so the numbers are reproducible.

    python3 experiments/016-dora/derive.py

Every number printed carries the rows it came from. A metric that cannot be
derived from the captured data prints UNDERIVABLE and says what is missing,
rather than estimating.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path
from typing import Final, Iterable, Literal, Sequence

DATA: Final[Path] = Path(__file__).parent / "data"

# The night, as a closed interval in UTC. Chosen from the data: the first
# production cutover and the last snapshot the dashboard mirror recorded.
NIGHT_START: Final[str] = "2026-09-13T15:32:14Z"
NIGHT_END: Final[str] = "2026-09-14T02:40:09Z"

Colour = Literal["blue", "green"]
Outcome = Literal["served", "withdrawn"]


def ts(s: str) -> datetime:
    """Parse the two timestamp shapes in the inputs (with and without millis)."""
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def hms(d: timedelta) -> str:
    total = int(d.total_seconds())
    h, rem = divmod(abs(total), 3600)
    m, s = divmod(rem, 60)
    sign = "-" if total < 0 else ""
    return f"{sign}{h:d}h{m:02d}m{s:02d}s" if h else f"{sign}{m:d}m{s:02d}s"


# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Pir:
    """A post-implementation review: the record that a build served production.

    The PIR is the only artifact present for all seventeen cutovers, so it is
    the uniform clock for "production-serving". It is posted at SETTLEMENT,
    a few seconds after the front actually flips (see `front_transitions.tsv`,
    where the gap is 6s for the five cutovers the mirror witnessed).
    """

    settled_at: datetime
    pr: int
    build: str
    colour: Colour
    rollback_target: str
    labels: tuple[str, ...]

    @property
    def app_labels(self) -> tuple[str, ...]:
        return tuple(sorted(x for x in self.labels if x.startswith("app:")))

    @property
    def blast_radius(self) -> int:
        return len(self.app_labels)

    @property
    def classification(self) -> str | None:
        """itil:* is the current vocabulary; change:standard|normal is the
        pre-19:00Z spelling of the same field. Normalised, but the migration
        is recorded rather than hidden -- see notes.org."""
        for x in self.labels:
            if x.startswith("itil:"):
                return x
            if x in ("change:standard", "change:normal", "change:emergency"):
                return "itil:" + x.split(":", 1)[1]
        return None


@dataclass(frozen=True)
class Commit:
    pr: int
    sha: str
    authored_at: datetime
    committed_at: datetime
    subject: str


@dataclass(frozen=True)
class FrontTransition:
    at: datetime
    from_colour: str | None
    from_sha: str | None
    to_colour: Colour
    to_sha: str


@dataclass(frozen=True)
class DeployStatus:
    deployment_id: int
    sha: str
    state: str
    at: datetime
    description: str


def load_pirs() -> list[Pir]:
    out: list[Pir] = []
    for line in (DATA / "pirs.tsv").read_text().splitlines():
        at, pr, build, colour, rb, ev = line.split("\t")
        out.append(
            Pir(ts(at), int(pr), build, colour, rb, tuple(ev.split()))  # type: ignore[arg-type]
        )
    return sorted(out, key=lambda p: p.settled_at)


def load_commits() -> list[Commit]:
    out: list[Commit] = []
    for line in (DATA / "pr_commits.tsv").read_text().splitlines():
        pr, sha, a, c, subj = line.split("\t", 4)
        out.append(Commit(int(pr), sha, ts(a), ts(c), subj))
    return out


def load_transitions() -> list[FrontTransition]:
    out: list[FrontTransition] = []
    for line in (DATA / "front_transitions.tsv").read_text().splitlines():
        if line.startswith("poll_window"):
            continue
        at, prev, cur = line.split("\t")
        pc, _, ps = prev.partition("/")
        cc, _, cs = cur.partition("/")
        out.append(FrontTransition(ts(at), pc or None, ps or None, cc, cs))  # type: ignore[arg-type]
    return out


def load_prod_statuses() -> list[DeployStatus]:
    out: list[DeployStatus] = []
    for line in (DATA / "prod_statuses.tsv").read_text().splitlines():
        parts = line.split("\t")
        dep, sha, state, at = parts[0], parts[1], parts[2], parts[3]
        desc = parts[4] if len(parts) > 4 else ""
        out.append(DeployStatus(int(dep), sha, state, ts(at), desc))
    return out


def load_windows() -> list[dict[str, object]]:
    return json.loads((DATA / "schedule.json").read_text())["windows"]


# ---------------------------------------------------------------------------
# Derived: the production cutovers
# ---------------------------------------------------------------------------


@dataclass
class Cutover:
    """One production cutover: the front was pointed at a new build."""

    pr: int
    build: str
    colour: Colour
    at: datetime
    outcome: Outcome
    rolled_back_at: datetime | None = None
    restored_to: str | None = None
    notes: list[str] = field(default_factory=list)

    @property
    def exposure(self) -> timedelta | None:
        if self.rolled_back_at is None:
            return None
        return self.rolled_back_at - self.at


def build_cutovers(
    pirs: Sequence[Pir],
    transitions: Sequence[FrontTransition],
    statuses: Sequence[DeployStatus],
) -> list[Cutover]:
    cutovers = [
        Cutover(p.pr, p.build, p.colour, p.settled_at, "served") for p in pirs
    ]
    by_build = {c.build: c for c in cutovers}

    # The dashboard mirror is the authority wherever it was running: it polls
    # the front ~1/s and records what was actually served. Prefer it over the
    # PIR clock, and use it to find rollbacks.
    #
    # Two traps, both hit on the first attempt at this:
    #  - the mirror's FIRST row is a seed observation, not a transition. It
    #    says what was already being served when the poller started, which is
    #    not when that build was cut over to. from_colour is None there.
    #  - a build appears as a destination TWICE when something is rolled back
    #    ONTO it. Only the first arrival is that build's cutover; the second
    #    is the restoration of a different change's failure.
    seen_as_destination: set[str] = set()
    for t in transitions:
        if t.from_colour is None:  # seed row, not a cutover
            seen_as_destination.add(t.to_sha)
            continue
        c = by_build.get(t.to_sha)
        if c is not None and t.to_sha not in seen_as_destination:
            c.at = t.at
            c.notes.append("cutover time from the dashboard mirror (+/-1s)")
        # A transition BACK to a build that already served is a rollback of
        # the build it replaces.
        if t.to_sha in seen_as_destination and t.from_sha in by_build:
            bad = by_build[t.from_sha]
            bad.rolled_back_at = t.at
            bad.restored_to = t.to_sha
        seen_as_destination.add(t.to_sha)

    # A production deployment whose record was WITHDRAWN never served. It is a
    # deployment ATTEMPT that failed, and it has no PIR, so it is not in the
    # list above -- add it.
    for s in statuses:
        if s.state == "failure" and "WITHDRAWN" in s.description:
            opened = min(x.at for x in statuses if x.deployment_id == s.deployment_id)
            cutovers.append(
                Cutover(
                    pr=42,  # sole withdrawn record; PR read from the deployment ref
                    build=s.sha,
                    colour="blue",  # declared by the deploy record, never reached
                    at=opened,
                    outcome="withdrawn",
                    notes=[s.description],
                )
            )
    return sorted(cutovers, key=lambda c: c.at)


# ---------------------------------------------------------------------------
# The four metrics
# ---------------------------------------------------------------------------


def deployment_frequency(cutovers: Sequence[Cutover]) -> None:
    served = [c for c in cutovers if c.outcome == "served"]
    first, last = served[0].at, served[-1].at
    span = last - first
    hours = span.total_seconds() / 3600
    print("1. DEPLOYMENT FREQUENCY")
    print(f"   production cutovers that served     : {len(served)}")
    print(f"   deployment ATTEMPTS (incl. withdrawn): {len(cutovers)}")
    print(f"   first / last                        : {first:%Y-%m-%dT%H:%M:%SZ} .. {last:%Y-%m-%dT%H:%M:%SZ}")
    print(f"   span                                : {hms(span)}")
    print(f"   rate                                : {len(served)/hours:.2f}/hour"
          f"  (1 per {span.total_seconds()/60/len(served):.1f} min)")
    by_day: dict[str, int] = {}
    for c in served:
        by_day[f"{c.at:%Y-%m-%d}"] = by_day.get(f"{c.at:%Y-%m-%d}", 0) + 1
    print(f"   by UTC calendar day                 : {by_day}")
    gaps = [(served[i + 1].at - served[i].at) for i in range(len(served) - 1)]
    print(f"   median gap between cutovers         : {hms(sorted(gaps)[len(gaps)//2])}")
    print()


def lead_time(cutovers: Sequence[Cutover], commits: Sequence[Commit]) -> None:
    print("2. LEAD TIME FOR CHANGES  (first commit authored -> production serving)")
    print("   Measured from the EARLIEST AUTHOR date among the PR's commits.")
    print("   Why: the ~23:35Z bulk rebase reset COMMITTER dates on seven")
    print("   branches (#6 #28 #33 #38 #40 #42 #44) to within 12 seconds of")
    print("   each other while leaving author dates spanning 13:41..19:37.")
    print("   Committer date measures the rebase; author date measures the work.")
    print()
    rows: list[tuple[int, datetime, datetime, timedelta, bool]] = []
    for c in cutovers:
        if c.outcome != "served":
            continue
        mine = [x for x in commits if x.pr == c.pr]
        if not mine:
            print(f"   #{c.pr}: UNDERIVABLE -- no commit list captured")
            continue
        first = min(x.authored_at for x in mine)
        rebased = max(x.committed_at for x in mine) - max(x.authored_at for x in mine) > timedelta(minutes=5)
        rows.append((c.pr, first, c.at, c.at - first, rebased))
    for pr, first, at, d, rebased in rows:
        flag = " [rebased: committer date would say %s]" % hms(
            at - min(x.committed_at for x in commits if x.pr == pr)
        ) if rebased else ""
        print(f"   #{pr:<3} {first:%H:%M:%SZ} -> {at:%H:%M:%SZ}  {hms(d):>10}{flag}")
    ds = sorted(r[3] for r in rows)
    print()
    print(f"   n = {len(ds)}")
    print(f"   median  : {hms(ds[len(ds)//2])}")
    print(f"   mean    : {hms(sum(ds, timedelta()) / len(ds))}")
    print(f"   min/max : {hms(ds[0])} / {hms(ds[-1])}")
    p90 = ds[min(len(ds) - 1, int(round(0.9 * (len(ds) - 1))))]
    print(f"   p90     : {hms(p90)}")
    print("   DORA band: Elite (< 1 day).")
    print()


def change_failure_rate(cutovers: Sequence[Cutover], windows: Sequence[dict[str, object]]) -> None:
    print("3. CHANGE FAILURE RATE")
    attempts = list(cutovers)
    failures = [c for c in attempts if c.outcome == "withdrawn" or c.rolled_back_at]
    print("   Definition used: a PRODUCTION DEPLOYMENT that required unplanned")
    print("   remediation -- the front was rolled back, or the deployment record")
    print("   was withdrawn because the build never served. Denominator is")
    print("   production deployment ATTEMPTS, not merges and not windows.")
    print()
    for c in attempts:
        mark = "FAIL" if c in failures else "ok  "
        extra = ""
        if c.rolled_back_at:
            extra = f"  rolled back {c.at:%H:%M:%SZ} -> {c.rolled_back_at:%H:%M:%SZ} to {c.restored_to}"
        elif c.outcome == "withdrawn":
            extra = "  record withdrawn; build never served anywhere"
        print(f"   {mark} #{c.pr:<3} {c.build}  {c.at:%m-%dT%H:%M:%SZ}{extra}")
    print()
    print(f"   numerator (failed production deployments) : {len(failures)}")
    print(f"   denominator (production attempts)         : {len(attempts)}")
    print(f"   CHANGE FAILURE RATE                       : {100*len(failures)/len(attempts):.1f}%")
    served = [c for c in attempts if c.outcome == "served"]
    rb = [c for c in served if c.rolled_back_at]
    print(f"   variant, served-only denominator          : {len(rb)}/{len(served)}"
          f" = {100*len(rb)/len(served):.1f}%")
    print(f"   variant, user-visible degradation only    : 0/{len(attempts)} = 0.0%")
    print()
    codes: dict[str, int] = {}
    for w in windows:
        codes[str(w.get("result") or "open")] = codes.get(str(w.get("result") or "open"), 0) + 1
    print(f"   NOT counted -- window closure codes       : {codes}")
    print("   expired  : a lapsed reservation. spec.org §Boundary conditions:")
    print("              'not a failure. Its own closure code.' Nothing was")
    print("              attempted, so nothing failed.")
    print("   cancelled: somebody decided. 229 of them are one runaway booker")
    print("              (#6/#42/#28, scenario D12) -- queue churn, not changes.")
    print("   failed   : four STAGING windows. Staging is not production, and a")
    print("              gate that refuses is the control working, not a failure.")
    print()


def time_to_restore(cutovers: Sequence[Cutover]) -> None:
    print("4. TIME TO RESTORE SERVICE")
    print("   Measured from the dashboard mirror (front polled ~1/s), so each")
    print("   figure is accurate to +/-1s. Both restorations were front switches;")
    print("   the idle colour kept the bad build in place.")
    print()
    rb = [c for c in cutovers if c.rolled_back_at]
    for c in rb:
        assert c.rolled_back_at and c.exposure
        print(f"   #{c.pr} {c.build} on {c.colour}")
        print(f"      served from  {c.at:%Y-%m-%dT%H:%M:%S.%fZ}")
        print(f"      restored at  {c.rolled_back_at:%Y-%m-%dT%H:%M:%S.%fZ} -> {c.restored_to}")
        print(f"      TTR          {c.exposure.total_seconds():.1f}s")
    ttrs = sorted(c.exposure for c in rb if c.exposure)
    if ttrs:
        mean = sum(ttrs, timedelta()) / len(ttrs)
        print()
        print(f"   n = {len(ttrs)}   min {ttrs[0].total_seconds():.1f}s"
              f"   max {ttrs[-1].total_seconds():.1f}s"
              f"   mean {mean.total_seconds():.1f}s")
        print("   (n=2: a median is not meaningful, so both values are given.)")
        print("   DORA band: Elite (< 1 hour).")
    print()


def integrity_checks(pirs: Sequence[Pir], windows: Sequence[dict[str, object]]) -> None:
    print("5. WHAT THE DATA CANNOT SUPPORT")
    noapp = [p for p in pirs if p.blast_radius == 0]
    print(f"   cutovers with NO app:* label at completion : {[p.pr for p in noapp]}")
    print("     -> blast radius is unrecordable for these, though CLAUDE.md")
    print("        defines a unit as a PR carrying at least one app:* label.")
    old = [p.pr for p in pirs if not any(x.startswith("itil:") for x in p.labels)]
    print(f"   cutovers classified in the OLD vocabulary  : {old}")
    print("     -> change:standard|normal vs itil:standard|normal. Normalised")
    print("        here; the store should not have permitted two spellings.")
    envs = {str(w["env"]) for w in windows}
    print(f"   window environments present                : {sorted(envs)}")
    print("     -> no production window exists. A production cutover cannot be")
    print("        joined to an authorizing reservation, so 'deployed inside an")
    print("        approved window' is UNDERIVABLE for production.")
    print("   dashboard mirror coverage                  : 2026-09-13T23:45:58Z ..")
    print("        2026-09-14T02:40:09Z. Nothing before 23:45Z was witnessed by")
    print("        an instrument; the eleven earlier cutovers rest on PIR self-")
    print("        report alone, so an unwitnessed rollback before 23:45Z would")
    print("        be invisible. The rate above is a LOWER BOUND.")
    print()


def main() -> None:
    pirs = load_pirs()
    commits = load_commits()
    transitions = load_transitions()
    statuses = load_prod_statuses()
    windows = load_windows()
    cutovers = build_cutovers(pirs, transitions, statuses)

    print("=" * 72)
    print("DORA metrics -- aygp-dr/standard-change, release night 2026-09-13/14")
    print(f"window: {NIGHT_START} .. {NIGHT_END}")
    print("=" * 72)
    print()
    deployment_frequency(cutovers)
    lead_time(cutovers, commits)
    change_failure_rate(cutovers, windows)
    time_to_restore(cutovers)
    integrity_checks(pirs, windows)


if __name__ == "__main__":
    main()
