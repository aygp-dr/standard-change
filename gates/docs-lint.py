#!/usr/bin/env python3
"""The documents gate. spec.org names one; this is it.

The code gate checks that artifacts run. This checks that the documents are
well-formed -- a different question, and neither substitutes for the other
(spec.org, Verification contract).

Written after committing an org file whose mermaid block was closed with
#+end_example instead of #+end_src. Every other check in this repo passed on
it: the tangle succeeded, the gates were green, the diagram simply vanished
from the render. A malformed document fails silently, which is precisely why
it needs its own gate.

Checks:
  1. org block balance -- every #+begin_X closed by a matching #+end_X
  2. no org-in-org (#+begin_src org), per the house conventions
  3. mermaid blocks carry :eval never-export
  4. no bare '#' or ';' hazards inside mermaid sequence messages
  5. internal [[./file]] links resolve
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
# fixtures are DELIBERATELY malformed -- they are the gate's negative test, so
# scanning them would make the gate permanently red.
SKIP = {".git", "node_modules", "worktrees", ".hypothesis", "__pycache__", "fixtures"}


def org_files():
    for p in ROOT.rglob("*.org"):
        if not SKIP & set(p.relative_to(ROOT).parts):
            yield p


def check(p):
    bad = []
    text = p.read_text(encoding="utf-8")
    lines = text.splitlines()

    # 1 + 2: block balance
    stack = []
    for i, line in enumerate(lines, 1):
        m = re.match(r'\s*#\+begin_(\w+)', line, re.I)
        if m:
            kind = m.group(1).lower()
            stack.append((kind, i))
            if kind == "src" and re.match(r'\s*#\+begin_src\s+org\b', line, re.I):
                bad.append(f"{p.name}:{i} org-in-org is forbidden")
            continue
        m = re.match(r'\s*#\+end_(\w+)', line, re.I)
        if m:
            kind = m.group(1).lower()
            if not stack:
                bad.append(f"{p.name}:{i} #+end_{kind} with no open block")
            elif stack[-1][0] != kind:
                open_kind, open_line = stack.pop()
                bad.append(f"{p.name}:{i} #+end_{kind} closes "
                           f"#+begin_{open_kind} opened at line {open_line}")
            else:
                stack.pop()
    for kind, line in stack:
        bad.append(f"{p.name}:{line} #+begin_{kind} is never closed")

    # 3 + 4: mermaid
    for m in re.finditer(r'#\+begin_src mermaid([^\n]*)\n(.*?)#\+end_src', text, re.S):
        header, body = m.group(1), m.group(2)
        if "never-export" not in header:
            line = text[:m.start()].count("\n") + 1
            bad.append(f"{p.name}:{line} mermaid block lacks :eval never-export")
        for bl in body.splitlines():
            if ";" in bl:
                bad.append(f"{p.name} mermaid: ';' separates statements -> {bl.strip()[:60]}")
            if re.search(r'->>?[^:]*:.*#\d', bl):
                bad.append(f"{p.name} mermaid: '#' in a message -> {bl.strip()[:60]}")

    # 5: internal links
    for m in re.finditer(r'\[\[\./([^\]]+)\]', text):
        if not (p.parent / m.group(1)).exists():
            bad.append(f"{p.name} dead link -> ./{m.group(1)}")
    return bad


def selftest():
    """The gate must reject its own malformed fixture."""
    f = ROOT / "gates" / "fixtures" / "docs" / "bad.org"
    n = len(check(f))
    if n >= 5:
        print(f"  docs-lint: rejects the malformed fixture ({n} findings)")
        return 0
    print("  docs-lint accepts a malformed document; it verifies nothing")
    return 1


def tangle_is_clean():
    """The spec must not tangle anything.

    spec.org is INTENT, not source (spec.org, This spec is intent). A :tangle
    directive there hands over bytes and calls them a requirement, which
    forecloses the implementation freedom the domain model argues for -- and
    it silently reverted two hand-edits to Makefile before that was noticed.
    """
    text = (ROOT / "spec.org").read_text()
    import re
    bad = re.findall(r'#\+begin_src[^\n]*:tangle\s+(\S+)', text)
    if bad:
        print("FAIL spec.org tangles: " + ", ".join(bad))
        print("     The spec states what must hold; the file on disk is the source.")
        return 1
    print("  spec.org: intent only, tangles nothing")
    return 0


def _unused_old_tangle_check():
    """kept out of the gate; superseded by the check above"""
    import subprocess
    r = subprocess.run(["emacs", "--batch", "-l", "org", "--eval",
                        '(org-babel-tangle-file "spec.org")'],
                       cwd=ROOT, capture_output=True, text=True)
    if r.returncode:
        print("FAIL tangle failed:", r.stderr.strip()[:120])
        return 1
    d = subprocess.run(["git", "diff", "--name-only"], cwd=ROOT,
                       capture_output=True, text=True).stdout.split()
    # spec.org itself may legitimately differ; the DERIVED files may not
    dirty = [f for f in d if f != "spec.org"]
    if dirty:
        print("FAIL tangling spec.org changed tracked files: " + ", ".join(dirty))
        print("     A derived file was edited directly. spec.org governs;")
        print("     put the change there and re-tangle.")
        return 1
    print("  tangle: derived files match spec.org")
    return 0


def main():
    if "--tangle" in sys.argv:
        return tangle_is_clean()
    if "--selftest" in sys.argv:
        return selftest()
    findings, n = [], 0
    for p in sorted(org_files()):
        n += 1
        findings += check(p)
    for f in findings:
        print(f"FAIL {f}")
    print(f"  {n} org files, {len(findings)} findings")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
