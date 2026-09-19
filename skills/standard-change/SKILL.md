---
name: standard-change
description: Bootstrap the standard-change label-driven deploy pattern (release:start / release:end / release:skip, level 0) in a repository that doesn't have it yet. Use when a person asks to adopt, set up, bring in, or "add standard-change" to a repo. Starts by surveying the repo's existing labels and PR history before proposing anything, and never touches a label namespace the repo already owns.
---

# /standard-change

Bootstraps level 0 of the standard-change pattern — three labels,
`release:start` / `release:end` / `release:skip` — into a repository that
has never had them. Nothing higher than level 0 without being asked; see
`aygp-dr/standard-change`'s `README.org`, "Levels of compliance". A
repository claiming level 0 and nothing else is not doing less of the
process, it is doing all of it that repo's shape requires.

## What it surveys before writing anything

- `gh label list --json name,color,description` on the target repo — every
  existing label, its color, its prefix if it has one.
- `gh pr list --state all --limit 50 --json labels` — how those labels are
  actually used, not just declared.
- Whether the repo already has (a) a risk designation on a change and (b) a
  concept of "something deployable" — under whatever names it already uses
  (`risk:*` / `type:*` / a Jira priority; `component:*` / `area:*` / a
  CODEOWNERS path). These are the repo's own inputs. standard-change never
  adds, removes, or repairs a label in either namespace — see
  `aygp-dr/standard-change`'s
  `research/findings/labels-are-the-only-channel.org`.

## What it refuses, and says

- A hue collision: if a `release:*` label's proposed color matches an
  existing prefix's hue, it picks a different one and says why — a real
  adopter (`www.wal.sh`, 2026-09-18) needed `itil:standard` and `app:site`
  visually distinct after both landed on the same blue, and that round trip
  is avoidable by checking first.
- An existing `release:*` or `change:*` namespace already in use for
  something else: it stops and asks rather than overwriting.
- A repo it can't confirm write access to: it asks for `gh auth status`
  first rather than failing partway through `gh label create`.

## The one thing it writes

Three labels via `gh label create`, only after the survey above finds no
collision: `release:start`, `release:end`, `release:skip`. No participles
(that's level 1 — the runner answers each verb with one, only once a
runner exists to answer with). No `itil:*`, no `app:*`-equivalent — those
belong to the repo already, named whatever it already names them.

## What it never does

Write a runner, a scheduler, or a gate — those are the repo's own choice of
substrate (see `research/substrates/conformance-ladder.org` in
`aygp-dr/standard-change` for what each rung costs and what it's gated on).
Rename an existing label. Touch a label outside the `release:*` namespace it
just created. Assume `app:*`-equivalent coverage is total over the
deployable tree — a partial namespace makes any later re-derivation check
unsound in the permissive direction, worth surfacing to the person, not
assumed away.

## How the person knows it was heard

The three labels exist (`gh label list` shows them), plus a short summary
naming what the survey found: what the repo already calls its risk and unit
concepts, whether a collision was avoided and how, and a pointer at
`research/build/index.md` (or `.html`) in `aygp-dr/standard-change` for the
base process's full grammar before picking a runner.
