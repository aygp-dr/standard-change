#!/usr/bin/env python3
"""review.py <pr> [--approve] -- guard 4's first rung, via the reviews API.

The shell version works, but it verifies by re-reading the forge and a shell
pipeline makes that easy to get wrong: `gh api --arg` (a jq flag gh rejects)
made it exit 1 AFTER the approval had already posted, reporting failure for a
success. Here the verdict is a typed object, so "did it post" and "what did the
script return" cannot drift apart silently.

The credential is never exported. It is passed to one subprocess in a copied
environment, because gh reads GH_TOKEN from the environment and it beats
`gh auth` -- exporting it would replace the operator for every later call.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, Field

REPO = os.environ.get("GH_REPO", "aygp-dr/standard-change")
ROOT = Path(__file__).resolve().parent.parent


class Verdict(BaseModel):
    """What an analysis returns. `approve` is the only field the caller branches
    on; the rest exist so a refusal is actionable and an approval auditable."""

    approve: bool
    pr: int
    head: str
    reasons: list[str] = Field(default_factory=list)
    checked: list[str] = Field(default_factory=list)
    not_checked: list[str] = Field(default_factory=list)

    def postable(self) -> tuple[bool, str]:
        """An approval that could not observe what it approves is not one.
        Checked here rather than left to the reader."""
        if not self.approve:
            return False, "verdict is not an approval"
        if self.not_checked:
            return False, f"approve=true but not_checked={self.not_checked}"
        return True, "ok"


class ReviewState(BaseModel):
    pr: int
    head: str
    author: str
    operator: str
    decision: str
    approvals_on_head: list[str]
    reviewer_login: str | None
    reviewer_token_is: str | None

    @property
    def separation(self) -> Literal["real", "absent", "unprovisioned"]:
        if self.reviewer_token_is is None:
            return "unprovisioned"
        return "absent" if self.reviewer_token_is == self.author else "real"


def gh(*args: str, token: str | None = None) -> str:
    env = dict(os.environ)
    if token:
        env["GH_TOKEN"] = token          # this process only, never exported
    out = subprocess.run(
        ["gh", *args], capture_output=True, text=True, env=env, cwd=ROOT
    )
    if out.returncode != 0:
        raise RuntimeError(f"gh {' '.join(args)} -> {out.returncode}: {out.stderr.strip()}")
    return out.stdout.strip()


def dotenv(key: str) -> str | None:
    f = ROOT / ".env"
    if not f.exists():
        return None
    for line in f.read_text().splitlines():
        if line.startswith(f"{key}="):
            return line.split("=", 1)[1].strip() or None
    return None


def state(pr: int) -> ReviewState:
    meta = json.loads(gh("pr", "view", str(pr), "--repo", REPO,
                         "--json", "headRefOid,author,reviewDecision"))
    head = meta["headRefOid"]
    reviews = json.loads(gh("api", f"repos/{REPO}/pulls/{pr}/reviews"))
    token = dotenv("REVIEWER_GH_TOKEN")
    # Ask the forge who the token IS. REVIEWER_LOGIN is what someone typed.
    who = None
    if token:
        try:
            who = gh("api", "user", "-q", ".login", token=token)
        except RuntimeError:
            who = None
    return ReviewState(
        pr=pr,
        head=head,
        author=meta["author"]["login"],
        operator=gh("api", "user", "-q", ".login"),
        decision=meta.get("reviewDecision") or "",
        approvals_on_head=sorted({
            r["user"]["login"] for r in reviews
            if r["state"] == "APPROVED" and r["commit_id"] == head
        }),
        reviewer_login=dotenv("REVIEWER_LOGIN"),
        reviewer_token_is=who,
    )


def approve(st: ReviewState, verdict: Verdict) -> int:
    ok, why = verdict.postable()
    if not ok:
        print(f"refused: {why}", file=sys.stderr)
        return 3
    if verdict.head != st.head:
        print(f"refused: verdict names {verdict.head[:7]}, head is {st.head[:7]}",
              file=sys.stderr)
        return 5
    if st.separation == "unprovisioned":
        print("refused: no usable REVIEWER_GH_TOKEN", file=sys.stderr)
        return 3
    if st.separation == "absent":
        print(f"refused: the reviewer token IS the author ({st.author})", file=sys.stderr)
        return 6

    token = dotenv("REVIEWER_GH_TOKEN")
    body = f"Approved by {st.reviewer_token_is} against {st.head[:7]}.\n\n" + \
           "\n".join(f"- {r}" for r in verdict.reasons)
    gh("api", f"repos/{REPO}/pulls/{st.pr}/reviews", "-X", "POST",
       "-f", f"commit_id={st.head}", "-f", "event=APPROVE", "-f", f"body={body}",
       token=token)

    # Verify by re-reading, not by the call's exit code.
    after = state(st.pr)
    if st.reviewer_token_is not in after.approvals_on_head:
        print("refused: posted, but the forge reports no such approval", file=sys.stderr)
        return 7
    print(f"  approved: {st.reviewer_token_is} on {st.head[:7]}, confirmed by re-reading")
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__.splitlines()[0], file=sys.stderr)
        return 2
    pr = int(sys.argv[1])
    st = state(pr)
    print(f"review state for #{pr} @ {st.head[:7]}")
    for k, v in [("pr author", st.author), ("operator (gh auth)", st.operator),
                 ("reviewDecision", st.decision or "<empty>"),
                 ("approvals on head", ", ".join(st.approvals_on_head) or "<none>"),
                 ("REVIEWER_LOGIN", st.reviewer_login or "<unset>"),
                 ("token resolves to", st.reviewer_token_is or "<unset/invalid>"),
                 ("separation", st.separation)]:
        print(f"  {k:<22} {v}")
    if "--approve" not in sys.argv:
        return 0
    return approve(st, Verdict(approve=True, pr=pr, head=st.head,
                               checked=["diff", "tests", "lint"],
                               reasons=["grind: exercising the approval flow"]))


if __name__ == "__main__":
    sys.exit(main())
