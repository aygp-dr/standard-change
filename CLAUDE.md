# CLAUDE.md — standard-change

Derived from `spec.org`. **`spec.org` governs; when they disagree, `spec.org` wins and this file is the bug.**

## What this is

A label-driven, gate-checked deployment pipeline demonstrated on a mock ecommerce monorepo. The four apps (`core`, `plp`, `pdp`, `checkout`) are fixtures — the product is the gate sequence, the labels that drive it, the change-schedule integration, and the checklists. A **unit** is one pull request carrying at least one `app:*` label. It is *done* when all three gates are green on the head SHA, a staging slot has deployed and re-run e2e against it, and — for production — the PIR comment is posted.

## Status: nothing is built yet

The repo currently contains `spec.org`, this file, and `.meta/`. Every command below is specified by the spec, **not yet runnable** — the scripts it names do not exist. Treat this section as removed once the first gate runs.

## Quickstart

Verified present on hydra (see `spec.org` §Host survey of record): node 24.14.1, npm 11.11.0, gmake 4.4.1, jq 1.8.1, gh 2.83.2, chromium 148 at `/usr/local/bin/chrome`.

```sh
# hydra is FreeBSD: system `make` is BSD make. Use gmake.
gmake port-alloc          # first command in a new worktree; writes .env.ports
gmake dev                 # render router, start apps present in this worktree
gmake gate app=plp        # lint + test + e2e for one group
gmake gate-selftest       # negative-test the gates; must pass before gate results count
gmake simulate app=pdp    # touch a group so the labeller attaches app:pdp
gmake port-free           # last command in a worktree
```

On ubuntu-latest (CI) the same targets run as `make`.

**Two blockers on hydra today** (`spec.org` §Known blockers):
- `nginx` is not installed, so `gmake router` / `gmake dev` cannot run here.
- Playwright ships no FreeBSD browser build. Intended route is `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` plus an explicit `executablePath` pointing at `/usr/local/bin/chrome` — **[H], not yet attempted.**

## Tangling

`spec.org` is literate and carries `:tangle` targets: `apps/plp/routes.json`, `ports.tsv`, `router/nginx.conf.tmpl`, `.github/labeler.yml`, `.github/workflows/deploy-staging.yml`, `Makefile`. Tangle with `C-c C-v t` in Emacs, or batch:

```sh
emacs --batch -l org --eval '(org-babel-tangle-file "spec.org")'
```

Verified [E] on 2026-09-12 with GNU Emacs 30.2: all 6 blocks tangle and nested directories are created (file-level `:mkdirp t`).

**Do not re-tangle casually.** `ports.tsv` is a `:tangle` target *and* mutable state that `port-alloc`/`port-free` write to — re-tangling clobbers live worktree allocations. See `spec.org` §Open items.

## Conventions

- **Port blocks.** Each worktree owns ten ports: base `10000 + 10n`, router on the base, apps at fixed offsets (core 1, plp 2, pdp 3, checkout 4, mock backend 5). `ports.tsv` is the registry. Never hardcode a port; read `.env.ports`.
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
