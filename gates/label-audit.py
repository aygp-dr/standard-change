#!/usr/bin/env python3
"""label-audit.py -- every label write in this repo must be by its declared owner.

You cannot unit-test what GitHub Actions does at 3am. You CAN test the thing
that actually goes wrong: an agent reads the repo, decides a label should be
set, and adds a write to a script that does not own it -- while another writer,
equally reasonably, unsets it. Neither is wrong about the world. The label has
no owner. production:healthy flipped five times in twenty minutes that way.

This is a STATIC audit. It reads change/label-owners.tsv, finds every
--add-label / --remove-label in the tree, and checks the writer against the
declaration. No CI, no network, no running estate.

It also checks the persistence rule: TRANSIENT labels mark where a change sat
in the deployment process, and once it is merged back to main that position
adds no value, so change/settle.sh must clear them. PERSISTENT labels describe
what the change IS and must survive. A transient label nobody clears leaks; a
persistent one that gets cleared destroys the record.
"""
import pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DECL = ROOT / "change" / "label-owners.tsv"
SKIP = {".git", "node_modules", "worktrees", "deployments", "__pycache__",
        "experiments", ".hypothesis"}

# Which declared owner does a given file act as? The declaration names owners in
# human terms ("labeller", "workflow"); this maps them onto paths.
def owner_of(path: str) -> set:
    o = set()
    if path.startswith(".github/workflows/labeller"): o |= {"labeller"}
    elif path.startswith(".github/workflows/"):       o |= {"workflow", "scheduler"}
    elif path.startswith("gates/"):                   o |= {path, path + " --pr"}
    elif path.startswith("change/"):                  o |= {path, "scheduler"}
    return o

def load():
    rows = {}
    for line in DECL.read_text().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        f = line.split("\t")
        if len(f) < 6:
            continue
        rows[f[0]] = {"owner": f[1], "persistent": f[2] == "yes",
                      "human_add": f[3] == "yes", "human_rm": f[4] == "yes"}
    return rows

def matches(label, declared):
    """app:* covers app:core etc."""
    if label in declared:
        return label
    for k in declared:
        if k.endswith("*") and label.startswith(k[:-1]):
            return k
    return None

def main():
    decl = load()
    fails, writes = [], {}
    pat = re.compile(r"--(add|remove)-label[= ]+[\"']?([A-Za-z0-9:_.-]+)")

    for p in ROOT.rglob("*"):
        if not p.is_file() or SKIP & set(p.relative_to(ROOT).parts):
            continue
        if p.suffix not in {".sh", ".py", ".yml", ".yaml", ".mjs", ".js"} and p.name != "deploy-run":
            continue
        rel = str(p.relative_to(ROOT))
        if rel == "gates/label-audit.py":
            continue
        try:
            text = p.read_text(encoding="utf-8")
        except Exception:
            continue
        for verb, label in pat.findall(text):
            if "$" in label or label.startswith("{"):
                continue          # dynamic; cannot be audited statically
            writes.setdefault(label, set()).add(rel)
            key = matches(label, decl)
            if key is None:
                fails.append(f"{rel}: writes '{label}', which is NOT DECLARED in "
                             f"change/label-owners.tsv. Declare it or stop writing it.")
                continue
            allowed = owner_of(rel)
            if decl[key]["owner"] in ("human", "RETIRED"):
                fails.append(f"{rel}: writes '{label}', declared owner "
                             f"'{decl[key]['owner']}' -- automation must not write this.")
            elif allowed and decl[key]["owner"] not in allowed:
                fails.append(f"{rel}: writes '{label}', but its declared owner is "
                             f"'{decl[key]['owner']}'. Two writers is how the thrash starts.")

    # Persistence: settle.sh must clear every transient label and no persistent one.
    settle = (ROOT / "change" / "settle.sh").read_text()
    cleared = set(re.findall(r"--remove-label\s+\"?\$?l\"?", settle))
    clear_list = re.search(r"for l in (.*?); do", settle, re.S)
    listed = set(clear_list.group(1).split()) if clear_list else set()
    for label, row in decl.items():
        if row["owner"] == "RETIRED" or label.endswith("*"):
            continue
        if not row["persistent"] and label not in listed:
            fails.append(f"settle.sh does not clear transient label '{label}'. "
                         f"Where a change sat in the process adds no value once merged.")
        if row["persistent"] and label in listed:
            fails.append(f"settle.sh clears PERSISTENT label '{label}'. "
                         f"It describes what the change is and must survive settlement.")

    for f in fails:
        print(f"FAIL {f}")
    print(f"  {len(decl)} labels declared, {len(writes)} written in-tree, "
          f"{len(fails)} finding(s)")
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main())
