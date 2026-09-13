# Bare metal by choice: this is a CI/CD pipeline simulator and FreeBSD is a
# poor host for docker/podman. Apps are node processes on a port block.
# On hydra use gmake; system make is BSD make.
APPS     := $(notdir $(wildcard apps/*))
# external/ is NOT ours: stand-ins for services we do not deploy.
EXTERNAL := $(notdir $(wildcard external/*))

.PHONY: help env env-check run dev router stop test lint gate gate-selftest \
        audit audit-selftest docs pbt pbt-random simulate simulate-gates smoke \
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

test:  ## unit tests, every app
test: ; @for a in $(APPS); do $(MAKE) -s -C apps/$$a test || exit 1; done
lint:  ## lint every app plus the labeller oracle
lint: ; @./router/generate.sh >/dev/null && \
	  for a in $(APPS); do $(MAKE) -s -C apps/$$a lint || exit 1; done && \
	  ./gates/labeller-test.py

gate: lint test ; @./gates/e2e.sh $(app) && ./gates/smoke.sh  ## lint, test, e2e and smoke   app=<name>
smoke:  ## walk the estate as a browser would   url=<base>
smoke: ; @./gates/smoke.sh $(url)
gate-selftest: docs-selftest  ## prove every gate can fail, then that it passes  ## prove every gate can fail, then that it passes
	@./gates/labeller-test.py && ./tla/check.sh && $(MAKE) -s audit-selftest

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
forge-list:  ## list PRs from the forge database
forge-list: ; @emacs --batch -l standard-change.el -f standard-change-forge-list
forge-pull:  ## refresh the forge database
forge-pull: ; @emacs --batch -l standard-change.el -f standard-change-forge-pull
forge:           forge-pull forge-list  ## pull then list PRs through emacs
forge-check:     ; @emacs --batch -l standard-change.el -f standard-change-forge-check

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
