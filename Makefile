# Bare metal by choice: this is a CI/CD pipeline simulator and FreeBSD is a
# poor host for docker/podman. Apps are node processes on a port block.
# On hydra use gmake; system make is BSD make.
APPS := $(notdir $(wildcard apps/*))

.PHONY: help env env-check run dev router stop test lint gate gate-selftest \
        audit audit-selftest simulate port-alloc port-free ports clean

help:
	@echo "env / env-check   .env from .env.template (warns if stale)"
	@echo "port-alloc        claim a port block for this worktree"
	@echo "run               start every app via apps/*/Makefile"
	@echo "dev               run + router"
	@echo "gate              lint, test, e2e"

# .env is generated and gitignored; .env.template is tracked.
.env: .env.template
	@./change/ports.sh alloc >/dev/null
	@cat .env.template .env.ports > .env
	@echo "regenerated .env"

env: .env

env-check:
	@if [ ! -f .env ]; then \
	  echo "WARNING: no .env — run 'gmake env'"; exit 1; \
	elif [ .env.template -nt .env ]; then \
	  echo "WARNING: .env.template is newer than .env — run 'gmake env'"; exit 1; \
	else echo ".env current"; fi

# Delegates to each app's own Makefile, so every app has the same targets.
run: env-check
	@for a in $(APPS); do \
	  $(MAKE) -C apps/$$a dev & \
	done; \
	echo "started: $(APPS)"

router: env-check
	@. ./.env && BASE_PORT=$$BASE_PORT BLOCK=$$BLOCK node router/server.js

dev: ; @./change/ports.sh run-apps
stop: ; @./change/ports.sh stop

test:  ; @for a in $(APPS); do $(MAKE) -s -C apps/$$a test || exit 1; done
lint:  ; @./router/generate.sh >/dev/null && \
	  for a in $(APPS); do $(MAKE) -s -C apps/$$a lint || exit 1; done && \
	  ./gates/labeller-test.py

gate: lint test ; @./gates/e2e.sh $(app)
gate-selftest:   ; @./gates/labeller-test.py && ./tla/check.sh && $(MAKE) -s audit-selftest
audit-selftest:
	@./gates/audit-controls.py --repo o/r --fixture gates/fixtures/audit/pass >/dev/null \
	  || { echo "audit rejects a compliant fixture"; exit 1; }
	@./gates/audit-controls.py --repo o/r --fixture gates/fixtures/audit/fail >/dev/null \
	  && { echo "audit passes a non-compliant fixture"; exit 1; } || true
	@echo "audit-controls: both directions confirmed"
audit:           ; @./gates/audit-controls.py
simulate:        ; @./change/simulate.sh $(app)
port-alloc:      ; @./change/ports.sh alloc
port-free:       ; @./change/ports.sh free
ports:           ; @./change/ports.sh list
clean:           ; @rm -rf .run .env .env.ports
