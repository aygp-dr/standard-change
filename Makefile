# Bare metal by choice: this is a CI/CD pipeline simulator and FreeBSD is a
# poor host for docker/podman. Apps are node processes on a port block.
# On hydra use gmake; system make is BSD make.
APPS     := $(notdir $(wildcard apps/*))
# external/ is NOT ours: stand-ins for services we do not deploy.
EXTERNAL := $(notdir $(wildcard external/*))

.PHONY: help env env-check run dev router stop test lint gate gate-selftest \
        audit audit-selftest observation-selftest docs pbt pbt-random simulate \
        simulate-gates smoke uat \
        forge forge-list forge-pull forge-check \
        port-alloc port-free ports clean

help:  ## show this list
	@grep -hE '^[a-zA-Z0-9_.-]+:.*##' $(MAKEFILE_LIST) | sort \
	  | awk 'BEGIN{FS=":.*## "}{printf "  %-16s %s\n",$$1,$$2}' 

# .env is generated and gitignored; .env.template is tracked.
# Compose, do not clobber. change/env.sh preserves local overrides and reports
# what changed; `cat template ports > .env` silently discarded them.
.env: .env.template
	@./change/env.sh

env: .env  ## compose .env, keeping your overrides

env-check:  ## fail if .env is older than the template
	@if [ ! -f .env ]; then \
	  echo "WARNING: no .env — run 'gmake env'"; exit 1; \
	elif [ .env.template -nt .env ]; then \
	  echo "WARNING: .env.template is newer than .env — run 'gmake env'"; exit 1; \
	else echo ".env current"; fi

# Delegates to each app's own Makefile, so every app has the same targets.
run: env-check  ## start every app via apps/*/Makefile
	@for a in $(APPS); do \
	  $(MAKE) -C apps/$$a dev & \
	done; \
	echo "started: $(APPS)"

router: env-check  ## run the router only
	@. ./.env && BASE_PORT=$$BASE_PORT BLOCK=$$BLOCK node router/server.js

dev:  ## run the apps plus the router
dev: ; @./change/ports.sh run-apps
stop:  ## stop this worktree block
stop: ; @./change/ports.sh stop

test:  ## unit tests, every app plus the shared surface
# shared/ is tested FIRST: every app imports it, so a failure there is a
# failure in all of them and there is no point running four app suites to
# learn it four times.
# Name the FILES. `node --test <dir>` hands the directory to the CJS loader and
# dies with MODULE_NOT_FOUND -- the same trap the per-app suites hit, which is
# why they run bare `node --test` from inside the app directory.
test: ; @node --test shared/tests/*.test.mjs >/dev/null 2>&1 || { node --test shared/tests/*.test.mjs; exit 1; }; \
	  echo "  shared/oneui: ok"; \
	  for a in $(APPS); do $(MAKE) -s -C apps/$$a test || exit 1; done
lint:  ## shellcheck the scripts, lint every app, check the labeller oracle
# ONE lint, three surfaces. Before this, `gmake lint` covered the apps and the
# labeller oracle and said nothing about 28 shell scripts -- the control plane,
# which is the part of this repo that is actually the product. A linter that
# skips the thing under test is the same defect as a gate whose oracle comes
# from the wrong tree.
#
# shellcheck runs FIRST: a parse error in change/ or gates/ makes every app
# result meaningless, because those scripts are what would have run them.
lint: ; @./gates/shellcheck.sh && \
	  ./router/generate.sh >/dev/null && \
	  for a in $(APPS); do $(MAKE) -s -C apps/$$a lint || exit 1; done && \
	  ./gates/labeller-test.py

gate: lint test ; @./gates/e2e.sh $(app) && ./gates/smoke.sh  ## lint, test, e2e and smoke   app=<name>
smoke:  ## walk the estate as a browser would   url=<base>
smoke: ; @./gates/smoke.sh $(url)
uat:  ## the browser journey, AS-IS, in headless Chromium   url=<base>
uat: ; @./gates/uat.sh $(url)
gate-selftest: docs-selftest  ## prove every gate can fail, then that it passes  ## prove every gate can fail, then that it passes
	@./gates/labeller-test.py && ./tla/check.sh && $(MAKE) -s observation-selftest \
	  && $(MAKE) -s audit-selftest

# The two guards that authorize on observations, run against recorded PR state,
# offline. Both directions: they must refuse a measurement taken on a different
# build, and the suite must be SHOWN to detect that -- the same fixture is run
# against the frozen pre-#16 guard, which has to authorize the stale one. A
# suite that passes against the broken guard too has established nothing
# (issue #16).
observation-selftest:
	@./gates/observation-test.sh
	@./gates/observation-test.sh --selftest

# The documents gate and its own negative test. A gate that cannot fail
# verifies nothing, so the malformed fixture must be rejected.
docs-selftest:
	@./gates/docs-lint.py
	@./gates/docs-lint.py --selftest
	@./gates/docs-lint.py --tangle
audit-selftest:
	@./gates/audit-controls.py --repo o/r --fixture gates/fixtures/audit/pass >/dev/null \
	  || { echo "audit rejects a compliant fixture"; exit 1; }
	@./gates/audit-controls.py --repo o/r --fixture gates/fixtures/audit/fail >/dev/null \
	  && { echo "audit passes a non-compliant fixture"; exit 1; } || true
	@echo "audit-controls: both directions confirmed"
	@./gates/simulate-gates.py --check
	@./gates/pbt-pipeline.py --exhaustive >/dev/null \
	  || { echo "pbt: clean model reports a violation"; exit 1; }
	@GUARD_4B=0 ./gates/pbt-pipeline.py --exhaustive >/dev/null \
	  && { echo "pbt: model cannot find scenario D4; it verifies nothing"; exit 1; } || true
	@echo "pbt-pipeline: both directions confirmed"
audit:  ## are this repo controls enforced
audit: ; @./gates/audit-controls.py
docs:  ## the documents gate
docs: ; @./gates/docs-lint.py
# Forge through batch emacs, so it works whether or not emacs is running.
# `--batch' already implies no init file and no frame; adding `-nw' would not
# make it stricter, and the entry points print rather than pop a buffer at
# nobody. Each one sets its own exit status: batch exits 0 through an error
# raised in a process filter, which is where an async forge pull reports.
forge-list:  ## list PRs from the forge database
forge-list: ; @emacs --batch -l standard-change.el -f standard-change-forge-list
forge-pull:  ## refresh the forge database
forge-pull: ; @emacs --batch -l standard-change.el -f standard-change-forge-pull
# Sequenced by recipe, not by prerequisites: under -j the two would run at
# once and the list would print the database the pull is still writing.
forge:  ## pull then list PRs through emacs
forge: ; @$(MAKE) -s forge-pull && $(MAKE) -s forge-list
forge-check:  ## can forge see this repo PRs
forge-check: ; @emacs --batch -l standard-change.el -f standard-change-forge-check

pbt:  ## exhaustive model of the promotion guards
pbt: ; @./gates/pbt-pipeline.py --exhaustive
pbt-random:      ; @./gates/pbt-pipeline.py
simulate-gates:  ## gate reliability, berth ceiling, emergency pressure
simulate-gates: ; @./gates/simulate-gates.py
simulate:        ; @./change/simulate.sh $(app)
port-alloc:  ## claim a port block for this worktree
port-alloc: ; @./change/ports.sh alloc
port-free:  ## release this worktree port block
port-free: ; @./change/ports.sh free
ports:  ## show the port registry
ports: ; @./change/ports.sh list
clean:  ## remove generated files
clean: ; @rm -rf .run .env .env.ports

dashboard:  ## the estate: queue, protected, team
	@./dashboard
