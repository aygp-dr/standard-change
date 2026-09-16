#!/usr/bin/env python3
"""IDP and change control platform for standard-change.

Two things, deliberately one tool, because they are one thing: taking a
position in the staging queue IS raising a change request. `change submit`
mints a CHG id and drives the ITIL state machine; `checkout`/`release` lease
team environments.

Staging is NOT checkoutable here. It is a queue position claimed by the
deploy:staging label so change/queue.sh evaluates guard 0 (up to date with
main) and guard 1 (singleton). Leasing it would bypass both.

Prior art: dsp-dr/guile-changeflow (ITIL 4 state machine, weighted risk
scoring, CHG-YYYYMMDD-NNNN ids). This mirrors its vocabulary; see spec.org
Change control for where it deliberately diverges.
"""
import argparse
import csv
import datetime as dt
import os
import sys

FIELDS = ["env", "holder", "pr", "checked_out_at", "expires_at", "note"]
RESERVED = {"staging", "production"}
TSV = os.environ.get("IDP_REGISTRY", "environments.tsv")
CHANGES = os.environ.get("IDP_CHANGES", "changes.tsv")

CHG_FIELDS = ["chg", "pr", "state", "ctype", "risk", "groups",
              "raised_by", "raised_at", "updated_at", "note"]

# ITIL 4 state machine (guile-changeflow), mapped onto the pipeline's labels.
TRANSITIONS = {
    "submitted":    {"assessing", "cancelled"},
    "assessing":    {"approved", "rejected", "needs-info", "cancelled"},
    "needs-info":   {"assessing", "cancelled"},
    "approved":     {"implementing", "cancelled"},
    "implementing": {"completed", "failed"},
    "failed":       {"assessing", "cancelled"},
    "completed":    set(),
    "rejected":     set(),
    "cancelled":    set(),
}

# Weighted factors, scored from the diff. Thresholds follow guile-changeflow:
# <30 standard, 30-70 normal, >70 requires CAB.
WEIGHTS = {
    "pipeline": 30,    # router/, gates/, change/, .github/ -- changes the control plane
    "targets": 20,     # deploy backends
    "multi_app": 15,   # cross-system
    "per_app": 8,
}


def risk_score(groups, paths, time_modifier=1.0):
    """Composite risk. Returns (score, change_type)."""
    tech = 0
    if any(p.startswith(("router/", "gates/", "change/", ".github/")) for p in paths):
        tech += WEIGHTS["pipeline"]
    if any(p.startswith("targets/") for p in paths):
        tech += WEIGHTS["targets"]
    if len(groups) > 1:
        tech += WEIGHTS["multi_app"]
    tech += WEIGHTS["per_app"] * len(groups)
    score = min(100, round(tech * time_modifier))
    # NOTE: emergency is NOT a risk band here. See spec.org Change control.
    ctype = "standard" if score < 30 else "normal"
    return score, ctype


def load_changes():
    if not os.path.exists(CHANGES):
        return []
    with open(CHANGES, newline="", encoding="utf-8") as fh:
        return [r for r in csv.DictReader(fh, delimiter="\t") if r.get("chg")]


def save_changes(rows):
    tmp = CHANGES + ".tmp"
    with open(tmp, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=CHG_FIELDS, delimiter="\t")
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in CHG_FIELDS})
    os.replace(tmp, CHANGES)


def mint(rows):
    day = now().strftime("%Y%m%d")
    n = sum(1 for r in rows if r["chg"].startswith(f"CHG-{day}")) + 1
    return f"CHG-{day}-{n:04d}"


def now():
    return dt.datetime.now(dt.timezone.utc)


def parse(ts):
    return dt.datetime.fromisoformat(ts.replace("Z", "+00:00"))


def stamp(t):
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def load():
    if not os.path.exists(TSV):
        return []
    with open(TSV, newline="", encoding="utf-8") as fh:
        return [r for r in csv.DictReader(fh, delimiter="\t") if r.get("env")]


def save(rows):
    tmp = TSV + ".tmp"
    with open(tmp, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=FIELDS, delimiter="\t")
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in FIELDS})
    os.replace(tmp, TSV)


def audit(line):
    with open(os.environ.get("IDP_AUDIT", "environments.log"), "a", encoding="utf-8") as fh:
        fh.write(f"{stamp(now())}\t{line}\n")


def guard_reserved(env):
    if env in RESERVED:
        sys.exit(
            f"refused: '{env}' is not a leasable environment.\n"
            f"It is the path to production and is claimed by adding the "
            f"deploy:staging label to a PR, so that change/queue.sh can check "
            f"guard 0 (up to date with main) and guard 1 (singleton). "
            f"Leasing it would bypass both."
        )


def cmd_list(args):
    rows = load()
    if not rows:
        print("no environments checked out")
        return
    t = now()
    print(f"{'ENV':<24} {'HOLDER':<16} {'PR':<6} {'EXPIRES':<22} STATE")
    for r in sorted(rows, key=lambda r: r["env"]):
        exp = parse(r["expires_at"])
        state = "EXPIRED" if exp < t else f"{int((exp - t).total_seconds() // 60)}m left"
        print(f"{r['env']:<24} {r['holder']:<16} {r['pr']:<6} {r['expires_at']:<22} {state}")


def cmd_checkout(args):
    guard_reserved(args.env)
    rows = load()
    t = now()
    for r in rows:
        if r["env"] == args.env:
            if parse(r["expires_at"]) > t:
                sys.exit(
                    f"refused: {args.env} held by {r['holder']} "
                    f"(PR #{r['pr']}) until {r['expires_at']}.\n"
                    f"Wait, or 'idp.py clear {args.env} --reason ...' if it is abandoned."
                )
            rows.remove(r)
            audit(f"reclaim\t{args.env}\tlease expired, held by {r['holder']}")
            break
    exp = t + dt.timedelta(hours=args.hours)
    rows.append({
        "env": args.env, "holder": args.holder, "pr": str(args.pr or ""),
        "checked_out_at": stamp(t), "expires_at": stamp(exp), "note": args.note or "",
    })
    save(rows)
    audit(f"checkout\t{args.env}\t{args.holder}\tpr={args.pr}\tuntil={stamp(exp)}")
    print(f"{args.env} checked out by {args.holder} until {stamp(exp)}")


def cmd_release(args):
    rows = load()
    keep = [r for r in rows if r["env"] != args.env]
    if len(keep) == len(rows):
        sys.exit(f"{args.env} is not checked out")
    save(keep)
    audit(f"release\t{args.env}")
    print(f"{args.env} released")


def cmd_clear(args):
    rows = load()
    hit = [r for r in rows if r["env"] == args.env]
    if not hit:
        sys.exit(f"{args.env} is not checked out")
    save([r for r in rows if r["env"] != args.env])
    audit(f"clear\t{args.env}\tforced from {hit[0]['holder']}\treason={args.reason}")
    print(f"{args.env} cleared (was {hit[0]['holder']}): {args.reason}")


def cmd_expired(args):
    t = now()
    stale = [r for r in load() if parse(r["expires_at"]) < t]
    for r in stale:
        print(f"{r['env']}\t{r['holder']}\tpr={r['pr']}\texpired {r['expires_at']}")
    sys.exit(1 if stale and args.check else 0)


def cmd_change_submit(args):
    rows = load_changes()
    if any(r["pr"] == str(args.pr) and r["state"] not in
           ("completed", "rejected", "cancelled") for r in rows):
        sys.exit(f"refused: PR #{args.pr} already has an open change record")
    groups = args.groups.split() if args.groups else []
    paths = args.paths.split() if args.paths else []
    score, ctype = risk_score(groups, paths)
    chg = mint(rows)
    rows.append({
        "chg": chg, "pr": str(args.pr), "state": "submitted", "ctype": ctype,
        "risk": str(score), "groups": " ".join(groups),
        "raised_by": args.by, "raised_at": stamp(now()),
        "updated_at": stamp(now()), "note": args.note or "",
    })
    save_changes(rows)
    audit(f"change\t{chg}\tsubmitted\tpr={args.pr}\trisk={score}\ttype={ctype}")
    print(f"{chg}\tstate=submitted\ttype={ctype}\trisk={score}")
    if score > 70:
        print(f"NOTE: risk {score} > 70 — requires CAB review before approval.",
              file=sys.stderr)


def cmd_change_state(args):
    rows = load_changes()
    hit = next((r for r in rows if r["chg"] == args.chg), None)
    if not hit:
        sys.exit(f"no such change: {args.chg}")
    cur = hit["state"]
    if args.to not in TRANSITIONS.get(cur, set()):
        allowed = ", ".join(sorted(TRANSITIONS.get(cur, set()))) or "(terminal)"
        sys.exit(f"refused: {args.chg} is '{cur}'; may only move to: {allowed}")
    hit["state"] = args.to
    hit["updated_at"] = stamp(now())
    if args.note:
        hit["note"] = args.note
    save_changes(rows)
    audit(f"change\t{args.chg}\t{cur} -> {args.to}\t{args.note or ''}")
    print(f"{args.chg}\t{cur} -> {args.to}")


def cmd_change_list(args):
    rows = load_changes()
    if args.open:
        rows = [r for r in rows
                if r["state"] not in ("completed", "rejected", "cancelled")]
    if not rows:
        print("no change records")
        return
    print(f"{'CHG':<20} {'PR':<6} {'STATE':<13} {'TYPE':<9} {'RISK':<5} GROUPS")
    for r in rows:
        print(f"{r['chg']:<20} {r['pr']:<6} {r['state']:<13} "
              f"{r['ctype']:<9} {r['risk']:<5} {r['groups']}")


def cmd_change_risk(args):
    groups = args.groups.split() if args.groups else []
    paths = args.paths.split() if args.paths else []
    score, ctype = risk_score(groups, paths)
    print(f"risk={score}\ttype={ctype}")
    if score > 70:
        print("requires CAB review", file=sys.stderr)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list").set_defaults(fn=cmd_list)

    c = sub.add_parser("checkout")
    c.add_argument("env")
    c.add_argument("--holder", default=os.environ.get("USER", "unknown"))
    c.add_argument("--pr", type=int)
    c.add_argument("--hours", type=float, default=8)
    c.add_argument("--note")
    c.set_defaults(fn=cmd_checkout)

    r = sub.add_parser("release:start"); r.add_argument("env"); r.set_defaults(fn=cmd_release)

    cl = sub.add_parser("clear")
    cl.add_argument("env"); cl.add_argument("--reason", required=True)
    cl.set_defaults(fn=cmd_clear)

    ch = sub.add_parser("change", help="change control records")
    chs = ch.add_subparsers(dest="sub", required=True)

    cs = chs.add_parser("submit")
    cs.add_argument("--pr", type=int, required=True)
    cs.add_argument("--groups", default="")
    cs.add_argument("--paths", default="", help="space-separated changed paths")
    cs.add_argument("--by", default=os.environ.get("USER", "unknown"))
    cs.add_argument("--note")
    cs.set_defaults(fn=cmd_change_submit)

    ct = chs.add_parser("state")
    ct.add_argument("chg"); ct.add_argument("to"); ct.add_argument("--note")
    ct.set_defaults(fn=cmd_change_state)

    cli = chs.add_parser("list")
    cli.add_argument("--open", action="store_true")
    cli.set_defaults(fn=cmd_change_list)

    cr = chs.add_parser("risk")
    cr.add_argument("--groups", default=""); cr.add_argument("--paths", default="")
    cr.set_defaults(fn=cmd_change_risk)

    e = sub.add_parser("expired")
    e.add_argument("--check", action="store_true", help="exit 1 if any are stale")
    e.set_defaults(fn=cmd_expired)

    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
