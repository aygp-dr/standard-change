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
            # ADDING AND REMOVING ARE DIFFERENT ACTS (docs/label-ownership.org).
            # The declaration already models this -- human_add and human_rm are
            # separate columns -- and this check ignored the verb it had just
            # parsed, so every legitimate CLEAR read as an illegal write.
            #
            # Asserting a label is a claim; clearing one withdraws a claim, and
            # the pipeline is allowed to withdraw claims it did not make. That is
            # the stated rule for `release`: a person adds it, automation removes
            # it. change/schedule.sh answering a change:requested by booking it,
            # and change/reap.sh releasing a berth held by a dead window, are the
            # same shape.
            #
            # A remove must still name a DECLARED label -- that check is above and
            # applies to both verbs, because clearing something with no owner is
            # how a label nobody governs gets quietly cleaned up.
            if verb == "remove":
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

    # Exclusion groups. Cardinality is a different fact from ownership, and the
    # rows above cannot express it -- #2 carried itil:standard AND
    # itil:emergency at once, leaving its class undefined while every rule in
    # preflight branched on the class.
    #
    # Checked statically: no single script may be able to ADD two members of one
    # group. That does not prove a PR never holds two (two scripts, or a human
    # plus a script, still can -- which is why preflight checks it live too), but
    # it catches the easy half at no cost.
    groups = {}
    for line in DECL.read_text().splitlines():
        f = line.split("\t")
        if len(f) >= 4 and f[0] == "exclusive":
            groups[f[1]] = set(f[2].split())

    for name, members in groups.items():
        for src, written in [(w, ls) for w, ls in
                             [(w, {l for l in writes if w in writes[l]}) for w in
                              {x for ss in writes.values() for x in ss}]]:
            both = members & written
            # Adding two members is FINE if each add is paired with removing the
            # others -- that is the if/elif pattern labeller.yml uses, and it is
            # the correct way to change a class. Flagging it was a false
            # positive on the first run of this check. Only an add with no
            # corresponding remove can leave two on a PR at once.
            if len(both) > 1 and name == "class":
                try:
                    text = (ROOT / src).read_text(encoding="utf-8")
                except Exception:
                    continue
                unpaired = {l for l in both
                            if f"--remove-label {l}" not in text
                            and f'--remove-label "{l}"' not in text}
                if len(unpaired) > 1:
                    fails.append(f"{src}: adds {sorted(unpaired)} without removing "
                                 f"the other -- mutually exclusive in group "
                                 f"'{name}'. One change, one class.")

    undeclared = {l for l in writes if matches(l, decl) is None}
    for name, members in groups.items():
        missing = members - set(decl)
        if missing:
            fails.append(f"exclusion group '{name}' names undeclared label(s) "
                         f"{sorted(missing)} -- declare them or remove them from the group.")

    for f in fails:
        print(f"FAIL {f}")
    print(f"  {len(decl)} labels declared, {len(writes)} written in-tree, "
          f"{len(fails)} finding(s)")
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main())
