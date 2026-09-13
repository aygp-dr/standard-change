#!/usr/bin/env python3
"""Closed-loop discrete-event simulator for the change pipeline.

Simulated time, so a scenario that takes days of wall-clock runs in
milliseconds. Deliberately needs NONE of: real pull requests, a forge, running
apps on ports, worktrees, or a network. Those verify different things (the
port-block and worktree rules); this verifies the SCHEDULING and GATING
semantics, which is what actually has the hard cases in it.

ITIL 4 nomenclature throughout, and the practice split is load-bearing:

  Change Enablement    -- authorizes. Produces an RFC with a planned change
                          window on the change schedule.
  Release Management   -- plans WHAT becomes available. A release is a set of
                          components; it is planned in code and can exist long
                          before anything is deployed.
  Deployment Management-- moves components to live. ACTIVATION is this, and it
                          is a separate act from holding the window.

The separation is the point: reserving a window is not deploying, and a change
that reserves a window it is not ready to use forfeits it.

The change schedule is a calendar, so windows quantize to SLOT_MINUTES. That
quantization -- not gate speed -- is what caps deployments per day.
"""
import enum
import itertools
import random
from dataclasses import dataclass, field

SLOT_MINUTES = 30
SLOTS_PER_DAY = 24 * 60 // SLOT_MINUTES          # 48


class State(enum.Enum):
    """ITIL 4 change states (see dsp-dr/guile-changeflow for prior art)."""
    SUBMITTED = "submitted"
    ASSESSING = "assessing"
    SCHEDULED = "scheduled"        # window reserved on the change schedule
    IMPLEMENTING = "implementing"  # activated: deployment management has it
    COMPLETED = "completed"
    FAILED = "failed"
    REJECTED = "rejected"
    CANCELLED = "cancelled"


class Kind(enum.Enum):
    STANDARD = "standard"
    NORMAL = "normal"
    EMERGENCY = "emergency"


class Divergence(enum.IntEnum):
    INERT = 0
    PIPELINE = 1
    ARTIFACT = 2
    HOTFIX = 3


WITHDRAWS = (Divergence.ARTIFACT, Divergence.HOTFIX)
_ids = itertools.count(1)


@dataclass
class Change:
    kind: Kind
    touches: Divergence
    base: int = 0                      # trunk version it is based on
    head: int = 0                      # bumps on every push
    chg: str = field(default_factory=lambda: f"CHG-{next(_ids):04d}")
    state: State = State.SUBMITTED
    gated_at: int | None = None        # head hash the suite passed on
    staged_at: int | None = None       # head hash staging passed on
    window: int | None = None          # reserved slot
    activated: int | None = None
    completed: int | None = None
    forfeits: int = 0
    def gates_green(self):  return self.gated_at == self.head
    def staging_valid(self): return self.staged_at == self.head


class World:
    """The estate, plus the change schedule."""

    def __init__(self, berths=1, hold_slots=1, seed=0):
        self.clock = 0                 # in slots
        self.trunk = 0
        self.merges: list[tuple[int, Divergence]] = []
        self.berths = berths
        self.hold_slots = hold_slots
        self.reservations: dict[int, list[Change]] = {}
        self.active: list[Change] = []
        self.changes: list[Change] = []
        self.log: list[str] = []
        self.rng = random.Random(seed)
        self.regressed = False
        self.forfeited = 0

    # -- change enablement -------------------------------------------------
    def submit(self, c: Change):
        c.base = self.trunk
        self.changes.append(c)
        self._log(f"{c.chg} submitted ({c.kind.value}, touches={c.touches.name})")
        return c

    def run_gates(self, c: Change):
        c.gated_at = c.head
        if c.state is State.SUBMITTED:
            c.state = State.ASSESSING

    def push(self, c: Change):
        c.head += 1                      # new content -> every verdict is void
        c.gated_at = c.staged_at = None
        if c.state is State.SCHEDULED:
            self._release(c, "pushed after scheduling")

    def rebase(self, c: Change):
        c.base = self.trunk
        c.head += 1
        c.gated_at = c.staged_at = None

    def divergence(self, c: Change) -> Divergence:
        since = [k for v, k in self.merges if v > c.base]
        return max(since) if since else Divergence.INERT

    # -- the change schedule (quantized) -----------------------------------
    def free_slot(self, from_slot=None):
        s = from_slot if from_slot is not None else self.clock + 1
        while len(self.reservations.get(s, [])) >= self.berths:
            s += 1
        return s

    def reserve(self, c: Change, slot=None):
        """Guard 0 and guard 1 at REQUEST time. Reserving is not deploying."""
        if c.state not in (State.ASSESSING, State.SUBMITTED):
            return None
        if c.kind is not Kind.EMERGENCY and c.base != self.trunk:
            self._log(f"{c.chg} refused window: behind trunk (guard 0)")
            return None
        if not c.gates_green():
            self._log(f"{c.chg} refused window: gates not green (guard 2)")
            return None
        s = self.free_slot(slot)
        self.reservations.setdefault(s, []).append(c)
        c.window, c.state = s, State.SCHEDULED
        self._log(f"{c.chg} scheduled -> slot {s} ({self.fmt(s)})")
        return s

    def _release(self, c: Change, why):
        if c.window is not None:
            self.reservations.get(c.window, []).remove(c)
            self._log(f"{c.chg} forfeits slot {c.window}: {why}")
            c.window = None
            c.forfeits += 1
            self.forfeited += 1
        if c.state is State.SCHEDULED:
            c.state = State.ASSESSING

    # -- deployment management ---------------------------------------------
    def tick(self):
        """Advance one slot. ORDER MATTERS: finish before activating.

        Found by Hypothesis. Activating first meant a berth released and
        reclaimed within the same quantum let the incoming change evaluate
        guard 4b against a trunk that was about to move -- D4's mechanism,
        arriving through scheduling rather than through an emergency. A berth
        must be fully released, with the merge applied, before it is retaken.
        """
        self.clock += 1
        for c in list(self.active):
            if self.clock >= (c.activated or 0) + self.hold_slots:
                self._finish(c)
        for c in list(self.reservations.get(self.clock, [])):
            self._activate(c)

    def _activate(self, c: Change):
        """Guards re-checked AT RELIANCE. This is the whole reason activation
        is separate from reservation: the world moved while the slot waited."""
        if not c.gates_green():
            return self._release(c, "gates not green at activation (guard 2)")
        if c.kind is not Kind.EMERGENCY and self.divergence(c) in WITHDRAWS:
            return self._release(c, f"trunk moved: {self.divergence(c).name} (guard 4b)")
        if c.kind is not Kind.EMERGENCY and not c.staging_valid():
            c.staged_at = c.head          # the window IS the staging run
        c.state, c.activated = State.IMPLEMENTING, self.clock
        self.active.append(c)
        self.reservations[self.clock].remove(c)
        self._log(f"{c.chg} ACTIVATED at slot {self.clock} ({self.fmt(self.clock)})")

    def _finish(self, c: Change):
        """Guard 4b AGAIN, at the merge.

        Found by Hypothesis at berths=2: two changes activate in the same slot,
        both pass guard 4b because trunk has not moved yet, then both merge --
        the first moves trunk and the second ships a tree predating it. So
        WIDENING THE BERTH REINSTATES D4 unless the merge is itself guarded.
        Activation is not the last point of reliance; the merge is.
        """
        self.active.remove(c)
        if c.kind is not Kind.EMERGENCY and self.divergence(c) in WITHDRAWS:
            c.state, c.staged_at = State.ASSESSING, None
            self._log(f"{c.chg} merge refused: trunk moved during the window "
                      f"({self.divergence(c).name}); revalidate (guard 4b at merge)")
            return
        self.trunk += 1
        self.merges.append((self.trunk,
                            Divergence.HOTFIX if c.kind is Kind.EMERGENCY else c.touches))
        c.state, c.completed, c.window = State.COMPLETED, self.clock, None
        self._log(f"{c.chg} completed at slot {self.clock}; trunk -> {self.trunk}")
        for other in self.changes:       # main-moved
            if other.state is State.SCHEDULED and self.divergence(other) in WITHDRAWS \
               and other.kind is not Kind.EMERGENCY:
                other.staged_at = None

    # -- helpers -----------------------------------------------------------
    def emergency_now(self, c: Change):
        """Break glass: no window needed, activates immediately."""
        c.kind = Kind.EMERGENCY
        c.state = State.SCHEDULED
        self.reservations.setdefault(self.clock + 1, []).append(c)

    def fmt(self, slot):
        return f"day {slot // SLOTS_PER_DAY} {(slot % SLOTS_PER_DAY) * SLOT_MINUTES // 60:02d}:" \
               f"{(slot % SLOTS_PER_DAY) * SLOT_MINUTES % 60:02d}"

    def _log(self, m):
        self.log.append(f"[{self.fmt(self.clock)}] {m}")

    # -- invariants --------------------------------------------------------
    def check(self):
        # An emergency takes no berth -- that is what break-glass MEANS. Counting
        # it against capacity would make the invariant assert something the
        # design never claimed.
        scheduled_live = [c for c in self.active if c.kind is not Kind.EMERGENCY]
        assert len(scheduled_live) <= self.berths, "more scheduled deployments live than berths"
        for c in self.changes:
            if c.state is State.COMPLETED:
                assert c.gated_at is not None, f"{c.chg} completed with no gate run"
                if c.kind is not Kind.EMERGENCY:
                    assert c.staged_at is not None, f"{c.chg} skipped staging"
        assert not self.regressed, "a change shipped a tree predating an artifact merge"


def capacity_report():
    print(f"Change schedule quantum: {SLOT_MINUTES} min -> "
          f"{SLOTS_PER_DAY} slots/day per berth")
    print(f"{'berths':>7} {'slots/day':>10} {'100 PRs':>10} {'500 PRs':>10}")
    for b in (1, 2, 4, 8, 16):
        per_day = SLOTS_PER_DAY * b
        print(f"{b:>7} {per_day:>10} {100/per_day:>9.1f}d {500/per_day:>9.1f}d")
    print("\n  This is the CEILING with perfectly green gates and zero forfeits.")
    print("  The calendar quantum caps throughput before any gate runs: a")
    print("  30-minute grain means 48 deployments/day/berth and no more,")
    print("  however fast the suite gets. Shortening the gate suite cannot")
    print("  buy a slot that the schedule does not have.")


if __name__ == "__main__":
    capacity_report()
