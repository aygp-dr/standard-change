---
name: standard-change
description: >-
  Check or bootstrap the standard-change label-driven deploy pattern in any
  repository. Use "check" when a person asks whether a repo is
  standard-change compliant, what level it's at, or to audit its release
  labels — read-only, never writes anything. Use "adopt" when a person asks
  to adopt, set up, bring in, wire up, or "add standard-change" to a repo
  that has none of it yet. Trigger on any of these even if the person
  doesn't say "standard-change" explicitly, such as label-driven deploys,
  release labels, PR labels for starting or ending a release, or "what
  level is this repo at." Always survey the repo's existing labels and PR
  history before proposing or claiming anything.
---

# /standard-change [check | adopt]

Two things, and they don't share a failure mode: `check` is read-only and
can only under-claim; `adopt` writes labels and must never collide with
what the repo already owns. Both start with the same survey.

## Data and access requirements

State these before running anything, don't just assume them:

- Local disk access to the target repo (a clone, or a working tree) — level
  3/4 checks read `.github/workflows/*.yml` for automation evidence, and
  that only works against a working tree, not a bare API view of the repo.
- Read access to the repo's forge/version-control platform metadata (its
  labels and PR history); `adopt` additionally needs write access to create
  labels.

Neither mode assumes GitHub. Determine the forge before running any survey
step:

```sh
git -C <path> remote get-url origin
```

- `github.com` in the URL — the `gh`-based steps below apply as written.
- `gitlab.com` (or a self-hosted GitLab) — label/MR-history equivalents
  exist (`glab label list`, `glab mr list`), but this skill has not been
  exercised against them. Say so explicitly rather than silently running
  `gh` against a repo it can't see.
- Anything else (a bare git remote, a self-hosted forge with no CLI) —
  labels and PR history may not exist there as a concept at all. Report
  that plainly instead of guessing at an equivalent.

If the repo isn't reachable locally (only a name or URL was given, no
clone), say so and ask for one rather than fabricating findings from the
name alone.

## Where each level's definition actually comes from

Every row in the `check` table below is a citation, not this skill's own
invention: the level definitions are `aygp-dr/standard-change`'s
`README.org`, "Levels of compliance"; the label-ownership rule is
`research/findings/labels-are-the-only-channel.org`; the present/used/
unverifiable evidence distinction borrows the same discipline as that
repo's own `research/substrates/conformance-ladder.org`. When reporting a
verdict, name which of these a level's requirement came from, so a
skeptical reader can go check the source instead of taking the skill's
word for it.

## The survey both modes run first

- `gh label list --json name,color,description` — every existing label,
  its color, its prefix if it has one.
- `gh pr list --state all --limit 50 --json labels` — how those labels are
  actually used, not just declared.
- Whether the repo already has (a) a risk designation on a change and (b) a
  concept of "something deployable" — under whatever names it already uses
  (`risk:*` / `type:*` / a Jira priority; `component:*` / `area:*` / a
  CODEOWNERS path). These are the repo's own inputs. standard-change never
  adds, removes, or repairs a label in either namespace — see
  `aygp-dr/standard-change`'s
  `research/findings/labels-are-the-only-channel.org`.

## check

Read-only. Reports which of the five documented levels
(`aygp-dr/standard-change`'s `README.org`, "Levels of compliance") the repo
actually supports — never "level 5" or anything past Estate; that isn't
defined anywhere in the source repo, and claiming it would be inventing a
standard rather than checking against one.

Levels compose: stop reporting further levels the moment one comes back
false, since a false at level N makes N+1 unverifiable by definition, not
merely unverified.

| level | requires | how it's checked |
|---|---|---|
| 0 Base | `release:start`, `release:end`, `release:skip` exist | `gh label list` |
| 1 Acknowledged | the participle labels (`release:started`/`release:ended`/`release:skipped`) exist AND at least one was actually applied to a real PR | labels, plus `gh pr list --state all --label release:started --limit 3` (etc.) |
| 2 Held | `release:hold` exists and was applied at least once | same two-step pattern |
| 3 Scheduled | `release:schedule`/`release:scheduled` exist, applied at least once, AND a workflow file references a calendar or scheduler | labels + PR history + `grep -l -i 'schedul\|calendar' .github/workflows/*.yml` |
| 4 Estate | an `itil:*` label family exists, a `deploy:*`/environment-tier label family exists, and at least one workflow references a lock or berth mechanism | labels + PR history + workflow grep |

Every level's verdict is one of three things, never collapsed to yes/no:

- **present** — the label vocabulary exists.
- **used** — it was actually applied to a real, findable PR, not just
  declared once and forgotten.
- **can't verify remotely** — e.g. whether a runner is actually listening
  for the label. `gh` shows labels and PRs, not CI logs or webhook
  configuration; say so rather than assuming a workflow file that mentions
  the right keyword is actually wired up correctly.

A repo can be *present* at level 2 and have never *used* it — report that
distinction, don't round up. Close with the highest level where every rung
up to it is at least *used*, plus everything above as present-but-unused or
unverified. Never say "this repo is level N" bare — that claims more
certainty than a read-only external check can produce.

## adopt

Bootstraps level 0 only — the three base labels — into a repo that has
none of them. Nothing higher without being asked; a repository claiming
level 0 and nothing else is not doing less of the process, it is doing all
of it that repo's shape requires.

### What it refuses, and says

- A hue collision: if a `release:*` label's proposed color matches an
  existing prefix's hue, it picks a different one and says why — a real
  adopter (`www.wal.sh`, 2026-09-18) needed `itil:standard` and `app:site`
  visually distinct after both landed on the same blue, and that round trip
  is avoidable by checking first.
- An existing `release:*` or `change:*` namespace already in use for
  something else: it stops and asks rather than overwriting.
- A repo it can't confirm write access to: it asks for `gh auth status`
  first rather than failing partway through `gh label create`.

### The one thing it writes

Three labels via `gh label create`, only after the survey finds no
collision:

| label | default color | why |
|---|---|---|
| `release:start` | `0e8a16` (green) | matches the `www.wal.sh` adoption report's proposal, itself derived from GitHub's own 16 stock swatches |
| `release:end` | `5319e7` (purple) | same source |
| `release:skip` | `fbca04` (amber) | unclaimed by that proposal; amber reads as "paused/declined" without competing with `itil:*`'s teal/amber/red risk ramp |

If any default collides with a hue already in use in the target repo, pick
the nearest unclaimed color from that same 8-color stock set
(`b60205 d93f0b fbca04 0e8a16 006b75 1d76db 0052cc 5319e7`) and say which
default was swapped and why, rather than silently picking something
arbitrary.

No participles (that's level 1 — the runner answers each verb with one,
only once a runner exists to answer with). No `itil:*`, no
`app:*`-equivalent — those belong to the repo already, named whatever it
already names them.

### What it never does

Write a runner, a scheduler, or a gate — those are the repo's own choice of
substrate (see `research/substrates/conformance-ladder.org` in
`aygp-dr/standard-change` for what each rung costs and what it's gated on).
Rename an existing label. Touch a label outside the `release:*` namespace it
just created. Assume `app:*`-equivalent coverage is total over the
deployable tree — a partial namespace makes any later re-derivation check
unsound in the permissive direction, worth surfacing to the person, not
assumed away.

### How the person knows it was heard

The three labels exist (`gh label list` shows them), plus a short summary
naming what the survey found: what the repo already calls its risk and unit
concepts, whether a collision was avoided and how, and a pointer at
`research/build/index.md` (or `.html`) in `aygp-dr/standard-change` for the
base process's full grammar before picking a runner.
