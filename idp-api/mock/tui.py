#!/usr/bin/env python3
"""tui.py -- the IDP from a terminal, against idp-api/openapi.yaml.

Stdlib only. One screen: the boundary, the changes, the schedule, and a
prompt whose verbs are the contract's. Refusals print as the contract
returns them -- fact, cost, recovery, berth -- because that is the product.

  python3 idp-api/mock/tui.py                  # interactive, against :9998
  python3 idp-api/mock/tui.py --once           # print the screen and exit
  python3 idp-api/mock/tui.py --run "r 62; a 62; s 62; q"   # scripted

verbs:  r <pr> [min]   reserve       a <pr>      activate (as the scheduler)
        s <pr>         settle, 3 converged probes     x <pr>  settle, mixed fleet
        c <pr>         cancel the reservation         f <pr>  close failed
        F [reason]     freeze         E <pr> [reason]  declare emergency (evicts)
        O              boundary open  R                reap    q  quit
"""
import json, os, sys, urllib.request, urllib.error, uuid, datetime

BASE = os.environ.get("IDP_URL", "http://127.0.0.1:9998")

def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method,
                                 headers={"content-type": "application/json", "idempotency-key": f"tui-{uuid.uuid4().hex[:8]}"})
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, (json.loads(r.read() or b"null") if r.status != 204 else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try: return e.code, json.loads(raw)
        except Exception: return e.code, raw.decode(errors="replace")
    except urllib.error.URLError as e:
        print(f"  cannot reach {BASE}: {e.reason}\n  start it: node idp-api/mock/server.mjs"); sys.exit(2)

def screen():
    _, cs = call("GET", "/changes"); _, sc = call("GET", "/schedule")
    b = sc["boundary"]
    print(f"\n  BOUNDARY  {b['state'].upper():<9}"
          + (f" freeze: {b['freeze']['reason']}" if b.get("freeze") else "")
          + (f" emergency for #{b['emergency']['change']}: {b['emergency']['reason']}" if b.get("emergency") else "")
          + (f"   berth: #{b['berth']['held_by']} ({b['berth']['lease']})" if b.get("berth") else "   berth: free"))
    print(f"\n  {'#':<4} {'class':<10} {'lifecycle':<13} {'head':<8} {'window':<26} {'lease':<10}")
    for c in cs:
        print(f"  {c['pr']:<4} {c['class']:<10} {c['lifecycle']:<13} {c['head']:<8} "
              f"{(c['window'] or {}).get('id','—'):<26} {(c['lease'] or {}).get('id','—'):<10}")
    print(f"\n  {'window':<26} {'chg':<5} {'start':<21} {'end':<21} {'mode':<11} result")
    for w in sc["windows"]:
        print(f"  {w['id']:<26} #{w['change']:<4} {w['start']:<21} {w['end']:<21} {w['mode']:<11} {w['result'] or 'open'}")
    if not sc["windows"]: print("  (nothing booked)")

def show(status, body):
    tag = "ok " if status < 400 else "REFUSED" if status in (409, 412, 422, 423) else "??"
    print(f"  {tag} {status}")
    if isinstance(body, dict) and "refused" in body:
        for k in ("refused", "fact", "cost", "recovery", "berth"):
            print(f"     {k:<9} {body.get(k, '')}")
    elif body is not None:
        print("     " + json.dumps(body, indent=2).replace("\n", "\n     "))

def now(): return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def do(line):
    a = line.split()
    if not a: return True
    v, arg = a[0], a[1:]
    pr = arg[0].lstrip("#") if arg else None
    head = lambda: call("GET", f"/changes/{pr}")[1].get("head", "0000000")
    lease = lambda: (call("GET", f"/changes/{pr}")[1].get("lease") or {}).get("id", "")
    if v == "q": return False
    if v == "r": g = call("GET", f"/changes/{pr}")[1].get("groups", []); show(*call("POST", f"/changes/{pr}/reservation", {"groups": g, "minutes": int(arg[1]) if len(arg) > 1 else 30}))
    elif v == "c": show(*call("DELETE", f"/changes/{pr}/reservation"))
    elif v == "a": show(*call("POST", f"/changes/{pr}/activation"))
    elif v == "s": h = head(); show(*call("POST", f"/changes/{pr}/settlement", {"lease": lease(), "claimed_build": h, "observations": [{"probe": f"http://127.0.0.1:9230/version.json", "at": now(), "build": h} for _ in range(3)]}))
    elif v == "x": h = head(); show(*call("POST", f"/changes/{pr}/settlement", {"lease": lease(), "claimed_build": h, "observations": [{"probe": "p1", "at": now(), "build": h}, {"probe": "p2", "at": now(), "build": "0000000"}]}))
    elif v == "f": show(*call("POST", f"/changes/{pr}/closure", {"code": "failed", "reason": "from the tui"}))
    elif v == "F": show(*call("PUT", "/boundary/freeze", {"reason": " ".join(arg) or "unstated"}))
    elif v == "E": show(*call("PUT", "/boundary/emergency", {"change": pr, "reason": " ".join(arg[1:]) or "unstated"}))
    elif v == "O": call("DELETE", "/boundary/freeze"); show(*call("DELETE", "/boundary/emergency"))
    elif v == "R": show(*call("POST", "/schedule/reap"))
    else: print(__doc__)
    return True

def main():
    if "--once" in sys.argv: screen(); return
    if "--run" in sys.argv:
        for line in sys.argv[sys.argv.index("--run") + 1].split(";"):
            print(f"\n> {line.strip()}")
            if not do(line.strip()): break
        screen(); return
    screen()
    while True:
        try: line = input("\nidp> ")
        except EOFError: break
        if not do(line): break
        screen()

if __name__ == "__main__":
    main()
