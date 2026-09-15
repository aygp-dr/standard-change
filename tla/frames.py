#!/usr/bin/env python3
"""frames.py -- write every action's UNCHANGED tuple from the `vars` tuple.

An action in Labels.tla ends with `/\\ FRAME`. This replaces it with
`/\\ UNCHANGED <<...>>` naming exactly the state variables the action does
not prime (an IF/THEN/ELSE that primes in one branch and lists the same
names in `ELSE UNCHANGED` counts as priming them). Twenty-seven variables
by hand produced duplicated names and a missing history variable; TLC
reports both as "successor state not completely specified" and the
bisection is slower than a generator.

    python3 tla/frames.py            # rewrites tla/Labels.tla in place
    python3 tla/frames.py --check    # exit 1 if any frame is stale
"""
import pathlib, re, sys

P = pathlib.Path(__file__).with_name("Labels.tla")
src = P.read_text()
VARS = [v.strip() for v in re.search(r"vars == <<(.*?)>>", src, re.S).group(1).replace("\n", " ").split(",")]

def frame_for(body):
    primed = set(re.findall(r"\b([A-Za-z]+)'\s*=", body))
    for m in re.finditer(r"ELSE UNCHANGED <<(.*?)>>", body, re.S):
        primed |= {v.strip() for v in m.group(1).replace("\n", " ").split(",")}
    keep = [v for v in VARS if v not in primed]
    out, line = [], "    /\\ UNCHANGED <<"
    for i, v in enumerate(keep):
        piece = v + (", " if i < len(keep) - 1 else ">>")
        if len(line) + len(piece) > 88:
            out.append(line.rstrip()); line = "                   "
        line += piece
    out.append(line)
    return "\n".join(out)

def rewrite(text):
    # each action: from its `Name(...) ==` or `Name ==` line to the blank line after it
    def sub(m):
        body = m.group(0)
        if "FRAME" in body:
            return re.sub(r"^    /\\ FRAME$", lambda _: frame_for(body), body, flags=re.M)
        if "UNCHANGED <<" in body:  # regenerate an existing frame
            body2 = re.sub(r"^    /\\ UNCHANGED <<(?:.|\n)*?>>", "    /\\ FRAME", body, count=1, flags=re.M)
            return re.sub(r"^    /\\ FRAME$", lambda _: frame_for(body2), body2, flags=re.M)
        return body
    return re.sub(r"^[A-Za-z]+(?:\([^)]*\))? ==\n(?:.+\n)+?(?=\n)", sub, text, flags=re.M)

new = rewrite(src)
if "--check" in sys.argv:
    sys.exit(0 if new == src else 1)
P.write_text(new)
n = len(re.findall(r"/\\ UNCHANGED <<", new))
print(f"frames written: {n} actions, {len(VARS)} variables")
