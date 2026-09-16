# Bare metal by choice: this is a CI/CD pipeline simulator and FreeBSD is a
# poor host for docker/podman. Apps are node processes on a port block.
# On hydra use gmake; system make is BSD make.
APPS     := $(notdir $(wildcard apps/*))
# external/ is NOT ours: stand-ins for services we do not deploy.
EXTERNAL := $(notdir $(wildcard external/*))

.PHONY: research build prose prose-root lint-org help env env-check run dev router stop test lint gate gate-selftest smoke-selftest \
        lint-shell lint-python shebang-selftest \
        audit audit-selftest observation-selftest docs pbt pbt-random simulate \
        simulate-gates smoke uat idp-mock idp-tui idp-org \
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
#
# EXIT 4 IS CARRIED, NOT SWALLOWED. Two of the surfaces below can report
# "I could not check" (docs/exit-codes.org: shfmt absent, no python linter
# installed). The old chain had no way to express that -- every surface either
# passed or failed -- so a tool that was not installed produced exactly the
# output of a tool that found nothing. That is the repo's own defect class 1
# aimed at its own linter. `lint` now keeps the worst code it saw and names the
# surface, so a clean run on a host missing a tool exits 4 and says which one.
# The gates are invoked DIRECTLY, never through $(MAKE). make reports every
# recipe failure as its own "Error 1" and exits 2, so a sub-make's exit 4 comes
# back as 2 and the distinction this target exists to preserve is destroyed on
# the way up. Call the script, read the script's number.
lint:
	@rc=0; \
	./gates/lint-shell.sh; s=$$?; \
	case $$s in \
	  0) ;; \
	  4) rc=4 ;; \
	  *) echo "lint: STOPPING -- the shell control plane is not clean, so every"; \
	     echo "      app and oracle result below it would be measured by scripts"; \
	     echo "      that do not lint. Fix the shell first."; exit 1 ;; \
	esac; \
	./router/generate.sh >/dev/null || rc=1; \
	for a in $(APPS); do $(MAKE) -s -C apps/$$a lint || rc=1; done; \
	./gates/labeller-test.py || rc=1; \
	./gates/python-lint.sh; p=$$?; \
	case $$p in 0) ;; 4) if [ $$rc = 0 ]; then rc=4; fi ;; *) rc=1 ;; esac; \
	echo; \
	case $$rc in \
	  0) echo "lint: shell, apps, labeller oracle and python -- zero findings" ;; \
	  4) echo "lint: zero findings, but a surface was NOT CHECKED (exit 4 above)."; \
	     echo "      A linter that is absent is not a linter that found nothing." ;; \
	  *) echo "lint: findings above" ;; \
	esac; \
	exit $$rc

lint-shell:  ## the control plane: shellcheck, the shebang policy, shfmt
lint-shell: ; @./gates/lint-shell.sh

lint-python:  ## gates/*.py, sim/*.py, apps/**/*.py -- ruff, flake8, pyflakes or py_compile
lint-python: ; @./gates/python-lint.sh

shebang-selftest:  ## prove the shebang policy can reject each bad form
shebang-selftest: ; @./gates/shebang.sh --selftest

gate: lint test ; @./gates/e2e.sh $(app) && ./gates/smoke.sh  ## lint, test, e2e and smoke   app=<name>
smoke:  ## walk the estate as a browser would   url=<base>
smoke: ; @./gates/smoke.sh $(url)
uat:  ## the browser journey, AS-IS, in headless Chromium   url=<base>
uat: ; @./gates/uat.sh $(url)
gate-selftest: docs-selftest  ## prove every gate can fail, then that it passes  ## prove every gate can fail, then that it passes
	@./gates/shebang.sh --selftest >/dev/null \
	  || { ./gates/shebang.sh --selftest; echo "shebang policy cannot reject; its PASS is void"; exit 1; }
	@./gates/labeller-test.py && ./tla/check.sh && $(MAKE) -s observation-selftest \
	  && $(MAKE) -s audit-selftest && $(MAKE) -s pr-audit-selftest \
	  && $(MAKE) -s label-model-selftest && $(MAKE) -s smoke-selftest

# The smoke crawl's negative test, and the reason it exists. wget prints
# "Found no broken links." after crawling NOTHING at all, so against a host
# that refused every connection this gate scored a pass -- measured on port
# 9077, spec.org defect class 7. smoke was the one gate absent from the list
# above, which is precisely where the vacuous check was.
smoke-selftest:
	@./gates/smoke.sh --selftest

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
pr-audit:  ## the five minimal invariants, against the live forge
pr-audit: ; @./gates/pr-state-audit.py
pr-audit-selftest:  ## prove the PR-state audit can reject each invariant
pr-audit-selftest: ; @./gates/pr-state-audit.py --selftest
label-model:  ## every declared label must exist in a model first
label-model: ; @./gates/label-model-coverage.py
label-model-selftest:  ## prove the coverage gate can reject
label-model-selftest: ; @./gates/label-model-coverage.py --selftest
build:  ## alias for research (HTML and PDF of the history and research)
build: research

research:  ## the history and research as one document, HTML and PDF -> research/build/
research: ; @$(MAKE) -s -C research build

prose-root:  ## vale over the org files at the root -- README, spec, docs, experiments
prose-root: ; @./gates/prose.sh

lint-org:  ## the org gate for a PR: docs-lint, then vale at error level on the WalSh style   FILES=<org files>
lint-org: ; @./gates/docs-lint.py && if [ -n "$(FILES)" ]; then vale --minAlertLevel=error --filter='.Name matches "WalSh"' --output=line $(FILES) && echo "  vale: no WalSh errors in $(words $(FILES)) file(s)"; else echo "  vale: no org files to lint"; fi

prose:  ## vale (the wal.sh style) over the research writeup
prose: ; @vale research/adoption.org research/README.org research/history/*.org research/substrates/*.org research/findings/*.org experiments/023-start-only/notes.org | tail -1

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
idp-mock:  ## the IDP contract (idp-api/openapi.yaml) as an in-memory mock on :9998
idp-mock: ; @node idp-api/mock/server.mjs
idp-tui:  ## the IDP from a terminal, against the mock   IDP_URL=<base>
idp-tui: ; @python3 idp-api/mock/tui.py
idp-org:  ## the IDP with org-mode as the store: tangle and run the eviction demo
idp-org: ; @cd idp-api && emacs --batch -l org --eval '(org-babel-tangle-file "idp.org")' >/dev/null 2>&1 && cd .. && emacs --batch -l idp-api/idp.el -f idp-org-demo 2>/dev/null
