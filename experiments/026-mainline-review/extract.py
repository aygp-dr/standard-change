#!/usr/bin/env python3
"""extract.py -- the mechanical half of the mainline review.

Walks `git log <base>..main` and writes ledger.tsv with every column that can
be filled without a judgement call: identity, kind by path, whether the
progressive commit protocol required a note, whether a note exists and carries
Timeline and Reproduction, the issues referenced, and the reproduction command
lines lifted verbatim out of the note.

The judgement columns are written as `?` so a later pass can find them with
grep and so a row that was never reviewed cannot be mistaken for a reviewed
one.

    python3 experiments/026-mainline-review/extract.py HEAD~60
    python3 experiments/026-mainline-review/extract.py 1f0ac3f --out /tmp/l.tsv

Stdlib only. Reads git. Writes exactly one file.
"""

import argparse
import collections
import pathlib
import re
import subprocess
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_OUT = pathlib.Path(__file__).resolve().parent / "ledger.tsv"

RECORD_SEP = "\x1e"
FIELD_SEP = "\x1f"

# Which operator produced the commit. The two cells are not interchangeable:
# hydra has no browser build and no nginx, so a reproduction recorded there may
# be unrunnable on the mini for reasons that are not a defect.
CELL_BY_EMAIL = {
    "j@wal.sh": "mini",
    "apace@defrecord.com": "hydra",
}

# Kind by path, first matching rule wins. The order is the governing order:
# a commit that touches spec.org is a spec commit whatever else it touches.
KIND_RULES = [
    ("spec", lambda p: p == "spec.org"),
    ("gate", lambda p: p.startswith("gates/")),
    ("change-script", lambda p: p.startswith("change/")),
    ("model", lambda p: p.startswith("tla/") or p.startswith("sim/")),
    ("experiment", lambda p: p.startswith("experiments/")),
    ("research", lambda p: p.startswith("research/")),
    (
        "docs",
        lambda p: p.startswith("docs/")
        or p.startswith(".meta/")
        or p.endswith(".org")
        or p in ("CLAUDE.md", "README.md", "AGENTS.md"),
    ),
    (
        "apps",
        lambda p: p.startswith("apps/")
        or p.startswith("router/")
        or p.startswith("shared/")
        or p.startswith("idp")
        or p.startswith("dashboard/")
        or p.startswith("targets/")
        or p.startswith("envs/")
        or p.startswith("adopt/")
        or p.startswith("deploy-run/")
        or p.startswith("status/"),
    ),
]

# The protocol in .meta/methodology.org and CLAUDE.md names three kinds that
# must carry a note. Nothing else is required to.
NOTE_REQUIRED_KINDS = {"spec", "gate", "change-script"}

# A reproduction command that matches any of these writes something: a label,
# a comment, a marker, a lock, a calendar entry, a ref. The driver agent must
# never re-run one of these, so the extractor flags them up front.
WRITE_PATTERNS = [
    re.compile(r"change/(driver|scheduler|abort|settle|unaffected|activate|release|reap|marker|lock)\.sh"),
    re.compile(r"change/schedule\.sh\s+(block|book|close|open)"),
    re.compile(r"\bgh\s+(issue|pr|label|api|release|run|workflow)\b.*\b(create|edit|comment|close|reopen|delete|add|remove|merge|rerun|-X\s*(POST|PATCH|PUT|DELETE))"),
    re.compile(r"\bgit\s+(push|commit|rebase|merge|notes\s+(add|append|edit|remove)|tag|reset\s+--hard)\b"),
    re.compile(r"\bgmake\s+(port-alloc|port-free|dev|run|router|clean|stop)\b"),
    re.compile(r"\bmake\s+(port-alloc|port-free|dev|run|router|clean|stop)\b"),
    re.compile(r"\b(rm|mv|sed\s+-i|tee|truncate)\b"),
]

ISSUE_RE = re.compile(r"#(\d{1,5})\b")
TIMELINE_RE = re.compile(r"^\s*\*?\s*Timeline\b", re.M)
REPRO_RE = re.compile(r"^\s*\*?\s*Reproduction\b", re.M)
CELL_RE = re.compile(r"^\s*[Cc]ell:\s*(.+?)\s*$", re.M)

# Two note dialects are in the tree. Some Reproduction sections prefix each
# command with `$ `; others list the command bare and indented, with the output
# on the same line or the lines under it. The prefixed form is unambiguous, so
# it wins when present and the bare form is the fallback.
DOLLAR_CMD_RE = re.compile(r"^\s*\$\s+(.+?)\s*$")
BARE_CMD_RE = re.compile(
    r"^\s+((?:[A-Z_][A-Z0-9_]*=\S+\s+)*"
    r"(?:\./|/|python3?\b|gmake\b|make\b|git\b|gh\b|node\b|npm\b|sh\b|bash\b|emacs\b|jq\b|cd\b|curl\b)"
    r".*?)\s*$"
)
# Output pasted on the same line as a bare command, after `->` or two spaces.
TRAILING_OUTPUT_RE = re.compile(r"\s+(?:->|→)\s+.*$|\s{2,}\S.*$")

JUDGEMENT_COLUMNS = [
    "claim",
    "runnable",
    "repro_out",
    "issue_state",
    "opened",
    "validation",
    "verdict",
    "evidence",
]

MECHANICAL_COLUMNS = [
    "sha",
    "date",
    "cell",
    "merge",
    "kind",
    "paths",
    "subject",
    "note",
    "timeline",
    "repro",
    "required",
    "protocol",
    "issues",
    "repro_cmd",
    "repro_writes",
    "note_cell",
]

COLUMNS = MECHANICAL_COLUMNS + JUDGEMENT_COLUMNS

HEADER_COMMENT = """\
# ledger.tsv -- one row per mainline commit, written by
# experiments/026-mainline-review/extract.py and completed by the driver agent.
#
# Columns 1-16 are mechanical. The extractor fills them and the driver agent
# never edits them. Columns 17-24 are judgement. The extractor writes `?` and
# the driver agent replaces every `?` with a value from the vocabulary below.
#
#  1 sha           short sha of the commit on main
#  2 date          author date, YYYY-MM-DD
#  3 cell          mini | hydra | unknown        which operator produced it
#  4 merge         yes | no                      more than one parent
#  5 kind          spec | gate | change-script | model | experiment | research
#                  | docs | apps | chore         first matching path rule
#  6 paths         count of files touched
#  7 subject       commit subject, tabs and newlines flattened to spaces
#  8 note          yes | no                      a git note exists
#  9 timeline      yes | no | na                 note has a Timeline section
# 10 repro         yes | no | na                 note has a Reproduction section
# 11 required      yes | no                      protocol required a note
# 12 protocol      ok | missing-note | note-incomplete | not-required
# 13 issues        comma-joined #N from subject, body and note, or -
# 14 repro_cmd     ` ; `-joined command lines lifted from the note, or -
# 15 repro_writes  yes | no | na                 a repro command writes state
# 16 note_cell      the note's own `Cell:` line, or -   where it was observed
#
# 17 claim         one short clause, what the commit asserts is now true
# 18 runnable      yes | no-moved | no-writes | no-slow | no-host | no-forge | na
# 19 repro_out     same | differs | na           re-run output against the note
# 20 issue_state   per-reference, comma-joined, or -. A `#N` in this repo is
#                  an issue or a pull request, so the vocabulary covers both:
#                  N:issue-open | N:issue-closed | N:pr-open | N:pr-merged
#                  | N:pr-closed | N:unknown
# 21 opened        #N the note says it opened, comma-joined, or -
# 22 validation    driver | grind | experiment | tlc | sim | gate | none
#                  comma-joined when more than one touched it
# 23 verdict       confirmed | confirmed-by-note-only | unverifiable
#                  | contradicted | no-claim
# 24 evidence      one line, the observation the verdict rests on
"""


def git(args):
    result = subprocess.run(
        ["git"] + args,
        cwd=str(REPO_ROOT),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        sys.exit("git {} failed: {}".format(" ".join(args), result.stderr.strip()))
    return result.stdout


def read_notes():
    """Map commit sha -> note text. One `git notes list`, then one show each."""
    listing = subprocess.run(
        ["git", "notes", "list"],
        cwd=str(REPO_ROOT),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if listing.returncode != 0:
        return {}
    notes = {}
    for line in listing.stdout.splitlines():
        parts = line.split()
        if len(parts) != 2:
            continue
        commit_sha = parts[1]
        shown = subprocess.run(
            ["git", "notes", "show", commit_sha],
            cwd=str(REPO_ROOT),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        if shown.returncode == 0:
            notes[commit_sha] = shown.stdout
    return notes


def classify_kind(paths):
    for kind_name, matches in KIND_RULES:
        for path in paths:
            if matches(path):
                return kind_name
    return "chore"


def repro_commands(note_text):
    """Every command line under Reproduction, verbatim, in order.

    Trailing pasted output is stripped so the string is a command a shell
    could take. The output stays in the note, which is where the driver agent
    reads it from when comparing a re-run.
    """
    if not note_text:
        return []
    match = REPRO_RE.search(note_text)
    if not match:
        return []
    tail = note_text[match.end():]
    lines = tail.splitlines()

    dollar = [m.group(1) for m in (DOLLAR_CMD_RE.match(line) for line in lines) if m]
    if dollar:
        return dollar

    bare = []
    for line in lines:
        if line.strip().lower().startswith("cell:"):
            continue
        found = BARE_CMD_RE.match(line)
        if not found:
            continue
        command = TRAILING_OUTPUT_RE.sub("", found.group(1)).strip()
        if command:
            bare.append(command)
    return bare


def recorded_cell(note_text):
    match = CELL_RE.search(note_text or "")
    return flatten(match.group(1))[:60] if match else "-"


def command_writes(commands):
    for command in commands:
        for pattern in WRITE_PATTERNS:
            if pattern.search(command):
                return True
    return False


def issues_in(*texts):
    found = []
    for text in texts:
        if not text:
            continue
        for number in ISSUE_RE.findall(text):
            if number not in found:
                found.append(number)
    return sorted(found, key=int)


def flatten(text):
    return re.sub(r"\s+", " ", text).strip()


def parse_paths(base_ref):
    """Second pass, paths only, so a commit body can never be read as a path."""
    raw = git(
        [
            "log",
            "--reverse",
            "--name-only",
            "--format=" + RECORD_SEP + "%H",
            base_ref + "..main",
        ]
    )
    by_sha = {}
    for chunk in raw.split(RECORD_SEP):
        lines = [line for line in chunk.splitlines() if line.strip()]
        if not lines:
            continue
        by_sha[lines[0].strip()] = lines[1:]
    return by_sha


def parse_log(base_ref):
    log_format = RECORD_SEP + FIELD_SEP.join(
        ["%H", "%h", "%ad", "%an", "%ae", "%P", "%s", "%b"]
    )
    raw = git(
        ["log", "--reverse", "--date=short", "--format=" + log_format, base_ref + "..main"]
    )
    paths_by_sha = parse_paths(base_ref)
    commits = []
    for chunk in raw.split(RECORD_SEP):
        if not chunk.strip():
            continue
        fields = chunk.split(FIELD_SEP)
        if len(fields) < 8:
            continue
        full_sha, short_sha, date, author_name, author_email, parents, subject = fields[:7]
        commits.append(
            {
                "full_sha": full_sha,
                "sha": short_sha,
                "date": date,
                "author_name": author_name,
                "author_email": author_email,
                "parents": parents.split(),
                "subject": subject,
                "body": fields[7].strip(),
                "paths": paths_by_sha.get(full_sha, []),
            }
        )
    return commits


def build_rows(commits, notes):
    rows = []
    for commit in commits:
        note_text = notes.get(commit["full_sha"], "")
        has_note = bool(note_text)
        kind_name = classify_kind(commit["paths"])
        required = kind_name in NOTE_REQUIRED_KINDS
        has_timeline = bool(TIMELINE_RE.search(note_text)) if has_note else None
        has_repro = bool(REPRO_RE.search(note_text)) if has_note else None
        commands = repro_commands(note_text)

        if not required:
            protocol = "not-required"
        elif not has_note:
            protocol = "missing-note"
        elif has_timeline and has_repro:
            protocol = "ok"
        else:
            protocol = "note-incomplete"

        rows.append(
            {
                "sha": commit["sha"],
                "date": commit["date"],
                "cell": CELL_BY_EMAIL.get(commit["author_email"], "unknown"),
                "merge": "yes" if len(commit["parents"]) > 1 else "no",
                "kind": kind_name,
                "paths": str(len(commit["paths"])),
                "subject": flatten(commit["subject"]),
                "note": "yes" if has_note else "no",
                "timeline": ("yes" if has_timeline else "no") if has_note else "na",
                "repro": ("yes" if has_repro else "no") if has_note else "na",
                "required": "yes" if required else "no",
                "protocol": protocol,
                "issues": ",".join("#" + n for n in issues_in(commit["subject"], commit["body"], note_text)) or "-",
                "repro_cmd": " ; ".join(flatten(c) for c in commands) or "-",
                "repro_writes": ("yes" if command_writes(commands) else "no") if commands else "na",
                "note_cell": recorded_cell(note_text),
            }
        )
        for column in JUDGEMENT_COLUMNS:
            rows[-1][column] = "?"
    return rows



# ---- the mechanical part of the walk (experiments/027 F1: the cheap driver did not walk) ----
SKIP_LEAD = ("#", "//", ";", "*")

def survival(sha, paths):
    """Step 7: are the commit's added lines still in the tree at HEAD?
    -> ('present'|'gone'|'na', 'k/n', superseding sha or '')"""
    diff = git(["show", "--format=", "--unified=0", sha, "--"] + list(paths))
    lines = []
    cur_path = None
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            cur_path = line[6:]
        elif line.startswith("+") and not line.startswith("+++"):
            text = line[1:]
            stripped = text.strip()
            if len(stripped) < 20 or stripped.startswith(SKIP_LEAD):
                continue
            lines.append((cur_path, text))
        if len(lines) >= 3:
            break
    if not lines:
        return "na", "0/0", ""
    hits = 0
    for path, text in lines:
        try:
            subprocess.run(["git", "grep", "-F", "-q", text, "HEAD", "--", path],
                           cwd=REPO_ROOT, check=True, capture_output=True)
            hits += 1
        except subprocess.CalledProcessError:
            pass
    n = len(lines)
    present = (n >= 3 and hits >= 2) or (n < 3 and hits == n)
    if present:
        return "present", "%d/%d" % (hits, n), ""
    newest = ""
    for path, _ in lines:
        log = git(["log", "--format=%h", "-1", sha + "..HEAD", "--", path]).strip()
        if log:
            newest = log
            break
    return "gone", "%d/%d" % (hits, n), newest


def mechanical_verdict(row, surv):
    """Step 12, the rules a machine can apply (1, 4, 5, 7, 8, 9, 10, 11).
    Rules 2, 3 and 6 need a reproduction or the forge; those rows keep '?'."""
    status, frac, superseded = surv
    if row["merge"] == "yes":
        return "no-claim", "merge commit"
    if row["required"] == "yes" and row["note"] == "no":
        return "unverifiable", "protocol defect: kind=%s requires a note, none present" % row["kind"]
    if row["required"] == "yes" and row["note"] == "yes" and (row["timeline"] == "no" or row["repro"] == "no"):
        return "unverifiable", "note incomplete: timeline=%s repro=%s" % (row["timeline"], row["repro"])
    if row["note"] == "yes" and row["timeline"] == "yes" and row["repro"] == "yes":
        return "confirmed-by-note-only", "note complete; reproduction not re-run by the extractor (rule 6 needs a run)"
    if row["kind"] == "chore" and row["issues"] == "-" and row["note"] == "no":
        return "no-claim", "chore with no issue and no note"
    if status == "present":
        return "confirmed", "survival present %s" % frac
    if status == "gone":
        return "unverifiable", "survival gone %s, superseded by %s" % (frac, superseded or "?")
    return "unverifiable", "survival na: no added line long enough to grep"


def write_ledger(rows, out_path):
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8") as handle:
        handle.write(HEADER_COMMENT)
        handle.write("\t".join(COLUMNS) + "\n")
        for row in rows:
            handle.write("\t".join(row[column] for column in COLUMNS) + "\n")


def report_counts(rows, base_ref, out_path):
    def tally(column):
        return collections.Counter(row[column] for row in rows)

    print("base ref            {}".format(base_ref))
    print("ledger              {}".format(out_path))
    print("commits             {}".format(len(rows)))
    print("merge commits       {}".format(tally("merge")["yes"]))
    print("")
    print("by cell")
    for value, count in tally("cell").most_common():
        print("  {:<18}{}".format(value, count))
    print("by kind")
    for value, count in tally("kind").most_common():
        print("  {:<18}{}".format(value, count))
    print("by protocol")
    for value, count in tally("protocol").most_common():
        print("  {:<18}{}".format(value, count))
    print("")
    notes_present = tally("note")["yes"]
    required = tally("required")["yes"]
    print("notes present       {}".format(notes_present))
    print("notes required      {}".format(required))
    print("notes missing       {}".format(tally("protocol")["missing-note"]))
    print("notes incomplete    {}".format(tally("protocol")["note-incomplete"]))
    print("has Timeline        {}".format(tally("timeline")["yes"]))
    print("has Reproduction    {}".format(tally("repro")["yes"]))
    print("")
    print("rows citing issues  {}".format(sum(1 for row in rows if row["issues"] != "-")))
    print("rows with repro cmd {}".format(sum(1 for row in rows if row["repro_cmd"] != "-")))
    print("repro cmds that write {}".format(tally("repro_writes")["yes"]))
    print("")
    print("judgement cells to fill  {}".format(len(rows) * len(JUDGEMENT_COLUMNS)))


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("base", help="base ref, exclusive; the walk is <base>..main")
    parser.add_argument("--out", default=str(DEFAULT_OUT), help="ledger path")
    parser.add_argument("--mechanical", action="store_true",
                        help="fill verdict and evidence where the decision table needs no run (rules 1,4,5,7,8,9,10,11)")
    arguments = parser.parse_args(argv)

    out_path = pathlib.Path(arguments.out).resolve()
    commits = parse_log(arguments.base)
    if not commits:
        sys.exit("no commits in {}..main".format(arguments.base))
    notes = read_notes()
    rows = build_rows(commits, notes)
    if arguments.mechanical:
        by_sha = {c["sha"]: c for c in commits}
        for row in rows:
            surv = survival(row["sha"], by_sha[row["sha"]]["paths"])
            row["verdict"], row["evidence"] = mechanical_verdict(row, surv)
        import collections as _c
        print("mechanical verdicts:", dict(_c.Counter(r["verdict"] for r in rows)))
    write_ledger(rows, out_path)
    report_counts(rows, arguments.base, out_path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
