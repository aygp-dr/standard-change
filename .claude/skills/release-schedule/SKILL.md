---
name: release-schedule
description: Book a change window for one pull request from a person's phrase ("in 2h", "tomorrow 09:00") when the estate has a calendar. Use when asked to schedule a release, reserve a slot, or say when a change will go. It books one window; it never claims the berth, never deploys, never rebooks a lapsed window.
---

# /release-schedule [PR] [when]

The scheduled case: a calendar in front of the berth. Reserving is not
deploying; when the window opens the guards run again (five-properties P2;
experiment 003).

Calls `./change/schedule.sh block <pr> "<groups>" <minutes> --at <iso>`.
The time comes from `./change/when.sh "<phrase>"`: schedule.sh accepts only
ISO 8601 UTC and must not learn the phrases. Groups come from
`./change/groups.sh <pr>`.

## Preconditions, checked before calling

- Run `./change/reap.sh` first: next-available appends behind dead windows
  (024 F9).
- The PR is OPEN. block refuses MERGED and CLOSED with exit 2; say it first.
- Groups is non-empty. With none, the word is `release:skip`.
- The time is in the future. when.sh refuses what it cannot read; do not guess.
- The duration is at or above the floor: 3 + soak + apps - 1, plus 10 for a
  control-plane change (exit 6). Never pass `--short`.
- No open window overlaps on this environment (exit 5).
- This PR holds no open window already: `./change/schedule.sh windows <pr>`.
  block does not check this and 024 F9 left one change holding two.

## The one thing it writes

One window row in `refs/idp/schedule`, by compare-and-swap. block also adds
`release:scheduled` today; under #125 that is the pipeline's record and stays
the pipeline's.

## What it refuses, and says

- "#N is MERGED; a landed change needs no window."
- "In the past; now is T."
- "20m cannot hold this change; it needs 34m (deploy+settle 3, soak 5, +1 per
  extra app, +10 control-plane)."
- "staging is booked by CHG-... over S..E; next free slot is T."
- "#N already holds CHG-...; unschedule it first."
- And what block does not say: "booked into S..E; the quantum is 30m so 20m
  became 30m" (024 F9: silent rounding).

## What it never does

Claim the berth; add the start label or `deploy:staging`; book production
(`CHANGE_ENV` stays staging); rebook after a lapse (a person's act,
reap.sh); touch the class, the approval, or any observation.

## How the person knows

block prints the id and S..E; `release:scheduled` appears; this skill posts
the one comment block does not: the window id, and that reserving is not
deploying and the guards run again when it opens.
