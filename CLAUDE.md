# CLAUDE.md — standard-change

Derived from `spec.org`. **`spec.org` governs; when they disagree, `spec.org` wins and this file is the bug.**

## What this is

A label-driven, gate-checked deployment pipeline demonstrated on a mock ecommerce monorepo. The four apps (`core`, `plp`, `pdp`, `checkout`) are fixtures — the product is the gate sequence, the labels that drive it, the change-schedule integration, and the checklists. A **unit** is one pull request carrying at least one `app:*` label. It is *done* when all three gates are green on the head SHA, a staging slot has deployed and re-run e2e against it, and — for production — the PIR comment is posted.

## Mandate, priority, and definition of done

Set by the owner, 2026-09-20: this project has a fixed goal, not an
open-ended one, and the priority from here is finishing it, not expanding
it. The two things this repo is for producing:

- **`skills/standard-change/`** — the portable adoption/check skill,
  installable into a repo that has never seen this pattern. **Done**, as of
  this note: built, tested against a real GitHub-backed eval loop (two
  iterations, 100% assertion pass rate with the skill vs. 72–74% without),
  reviewed by an independent pass that found and fixed real citation and
  label-naming bugs, validated clean by `gh skill publish --dry-run`, and
  published as release `v0.1.0`. Future work on it should be maintenance
  (a real bug, a new install target failing) — not new scope, unless the
  owner reopens it.
- **`research/`** — the buildable corpus (`gmake -C research html | md |
  org | pdf`) arguing the pattern and surveying prior art. **Not yet
  declared done.** Known open items from the most recent review pass: (a)
  `research/index.org`'s Part I include list omits `README.org`'s
  compliance-levels table and the merge-is-tombstone section, so the
  assembled paper doesn't carry what an external adopter needs most (the
  gap that caused two real misreadings, documented in a 2026-09-18 adoption
  report); (b) the conformance ladder's rung 6 doesn't cover the case where
  the instrument exists but the pipeline is architecturally barred from
  reaching it; (c) `adoption.org` doesn't warn that an `app:*`-based
  re-derivation check presumes total `app:*` coverage; (d) no label-color
  convention is recorded anywhere despite one being proposed. A definition
  of done for `research/` — which of these are blocking, what else counts,
  when to stop adding findings and call the corpus closed — is itself
  undecided and worth settling explicitly rather than by drift.

Everything else in this file (the four fixture apps, the gate sequence, the
change-schedule integration) is the demonstration substrate that argues for
the pattern the skill packages — not itself a second deliverable to keep
growing. New experimental work should serve one of the two items above or
name explicitly why it doesn't.

## Status: built, and running

46 scripts under `change/` and `gates/`, a live estate on hydra (staging 9200, blue 9210, green 9220, front 9230), 55+ merged changes. This section previously read *"nothing is built yet … the scripts it names do not exist"* and carried its own removal condition — *"treat this section as removed once the first gate runs"*. The first gate ran; the condition fired; nobody removed it, and it kept telling every agent that loads this file that the repo was empty. Corrected 2026-09-15 by counting the files.

## Quickstart

Verified present on hydra (see `spec.org` §Host survey of record): node 24.14.1, npm 11.11.0, gmake 4.4.1, jq 1.8.1, gh 2.83.2, chromium 148 at `/usr/local/bin/chrome`.

```sh
# hydra is FreeBSD: system `make` is BSD make. Use gmake.
gmake port-alloc          # first command in a new worktree; writes .env.ports
gmake dev                 # render router, start apps present in this worktree
gmake gate app=plp        # lint + test + e2e for one group
gmake uat url=http://127.0.0.1:9000   # the browser journey as accepted; refuses a changed flow
gmake gate-selftest       # negative-test the gates; must pass before gate results count
gmake simulate app=pdp    # touch a group so the labeller attaches app:pdp
gmake port-free           # last command in a worktree
```

On ubuntu-latest (CI) the same targets run as `make`.

**Blockers on hydra** (`spec.org` §Known blockers):
- ~~`nginx` is not installed~~ — **cleared**. nginx 1.30.4 is present and the protected tier is up (9200/9210/9220/9230). Recorded as a blocker long after it stopped being one.
- Playwright ships no FreeBSD browser build. Intended route is `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` plus an explicit `executablePath` pointing at `/usr/local/bin/chrome` — **[H], not yet attempted.**

## Tangling — spec.org tangles nothing, and a gate enforces that

`spec.org` is **intent, not source**. It carries zero `:tangle` targets (measured: `grep -c 'begin_src.*:tangle' spec.org` → 0), and `gates/docs-lint.py --tangle` fails the build if any reappear.

This section previously instructed the reader to run `org-babel-tangle-file` and named six blocks — `apps/plp/routes.json`, `ports.tsv`, `router/nginx.conf.tmpl`, `.github/labeler.yml`, `.github/workflows/deploy-staging.yml`, `Makefile`. Following it would have done nothing at best; the warning it carried (`ports.tsv` is both a tangle target and live mutable state that `port-alloc`/`port-free` write) described a hazard that no longer exists in that form. **A document telling agents to perform an act that a gate refuses is worse than one that is merely out of date** — it puts the instruction and the control in direct contradiction, and this file is loaded into every agent's context before either is read. Corrected 2026-09-15.

## Conventions

- **Port tiers — the number tells you what an environment is.**
  `9000-9099` **dev** (worktree blocks, `9000 + 10n`, n ≤ 9, disposable),
  `9100-9199` **team** (real environments that **cannot promote**),
  `9200-9299` **protected** (`9200` staging, `9210` production blue, `9220`
  production green — the path to production). Corrected 2026-09-13: this file
  previously said `9200` production / `9201` staging, which gave the two
  production replicas no addresses of their own and put blue/green outside the
  block scheme. A dev block must never cross into 9100; `ports.sh` refuses
  block 10. Never hardcode a port; read `.env.ports`.
- **Inside a jail**, nginx is `:80` and apps are `8001-8005` — identical in
  every environment, because each jail has its own IP. Ports are only scarce
  where a namespace is shared.
- **`routes.json` is the source.** The router config, the labeller config, and the journey list are all generated from `apps/*/routes.json`. Edit the source, regenerate; never hand-edit a generated file.
- **Deploy groups are app directories.** `main` and `default` are aliases for `core`.
- **No platform token in any filename.** Portability is recorded in the spec's matrix, not encoded in slugs.
- **Org-mode for docs.** Markdown only for `CLAUDE.md`, `AGENTS.md`, `README.md`. No org inside org. Diagrams are Mermaid with `:eval never-export`, never image files.
- **Commits** are conventional, one logical step. Stage files **by name** — never `git add -A`, `git add .`, or `git add --all`. Commits touching the spec, a gate, or the change scripts carry a git note with *Timeline* (including what failed) and *Reproduction* (command, output, cell).

## Invariants

**Do:**
- Run `gate-selftest` before trusting any gate result. A gate that fails to reject its `fixtures/<gate>/fail/` input produces no verdict that run — its PASS is void.
- Mark any claim you have not observed as `[H]`, and any cell you have not watched pass as unsupported.
- Call `preflight.sh` before every staging and production deployment. Exit codes: 0 proceed, 2 lock, 3 freeze, 4 calendar unreachable — **4 blocks**, it does not proceed.
- Put `schedule.sh close` and `lock.sh release` in `always()` steps.
- Record deviations in the commit message *and* the review ledger issue while the spec is at 0.x.

**Do not:**
- Add a warning tier to any gate. Zero findings or the gate failed.
- Promote a matrix cell you did not watch pass, with versions pasted into `spec.org` §Host survey of record.
- Deploy a group to production without `deployed:staging-<group>-<n>` on the head SHA.
- Let the first (in-runner) e2e run authorize production. The staging-slot run is the authorizing one.
- Amend `spec.org` to paper over a failing run. A run that refutes the spec amends the spec *in the direction of the observation*.

See `spec.org` §Verification contract and §Refutation conditions for the full statement. The seven refutation conditions are tests to be written, not worries — until they are executable, the repo's central claim is `[H]`.

## Where work lands

- Speculative work → `experiments/NNN-slug/` with a falsifiable hypothesis, success criterion, exact run command, and a dated `notes.org`. Numbering is monotonic and never reused. Tooling written to audit the repo is itself an experiment.
- Deferred or suspected-wrong → an issue stating the **trigger** that forces the revisit, not a source comment.
- Parallel work → a git worktree under `worktrees/`, its own port block, removed when done.
- Operating disciplines and the terms of art → `.meta/`.
