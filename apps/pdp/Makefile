# apps/pdp — same targets in every app directory, by convention.
APP        := pdp
PORT_OFFSET := 3
-include ../../.env
PORT ?= $(shell expr $(BASE_PORT) + $(PORT_OFFSET))

.PHONY: help dev test lint lint-js build clean
help:  ; @echo "$(APP): dev test lint build  (port $(PORT))"
dev:   ; BUILD_SHA=$(BUILD_SHA) BLOCK=$(BLOCK) PORT=$(PORT) node src/server.js
test:
	@node --test
# The gates for this app. Both must be able to FAIL: node --check only proves
# the file parses and jq -e only proves the JSON is well formed, so the real
# checks are the routes.json contract and the server's obligations to the
# router and guard 5.
lint:
	@node --check src/server.js
	@node ../../gates/lint-app.mjs .
# eslint over this app's sources -- IF eslint and a rule set are actually here.
#
# Two things have to be true before this can produce a verdict, and neither is
# true on hydra today:
#
#   the TOOL     eslint is not in node_modules/.bin, not in PATH, and there is
#                no root node_modules at all. `npx eslint` would DOWNLOAD it,
#                which is a gate installing its own oracle at judgement time --
#                a different eslint on every run and a network dependency in
#                the lint path. So npx is checked with --no-install only.
#   the RULE SET eslint 9 refuses to run without eslint.config.js. There is no
#                eslint config anywhere in this repo and this target does not
#                write one: a rule set nobody agreed to produces findings
#                nobody acts on, which is the warning tier arriving in disguise.
#
# EXIT 4 FOR EITHER, because 4 is "I could not check" and 4 is not 0
# (docs/exit-codes.org). The failure this refuses to produce is the quiet one:
# a lint-js that prints nothing and exits 0 is indistinguishable from a clean
# app, and the whole repo is an argument about why those must look different.
lint-js:
	@if   [ -x node_modules/.bin/eslint ];       then E=node_modules/.bin/eslint; \
	 elif [ -x ../../node_modules/.bin/eslint ]; then E=../../node_modules/.bin/eslint; \
	 elif command -v eslint >/dev/null 2>&1;     then E=eslint; \
	 else \
	   echo "  $(APP): eslint NOT INSTALLED -- src/ was NOT checked."; \
	   echo "         exit 4: absent is not clean (docs/exit-codes.org)."; \
	   exit 4; \
	 fi; \
	 cfg=""; \
	 for c in eslint.config.js eslint.config.mjs eslint.config.cjs .eslintrc .eslintrc.js .eslintrc.json .eslintrc.yml \
	          ../../eslint.config.js ../../eslint.config.mjs ../../.eslintrc.json; do \
	   [ -f "$$c" ] && { cfg="$$c"; break; }; \
	 done; \
	 if [ -z "$$cfg" ]; then \
	   echo "  $(APP): eslint is present but NO eslint config exists -- src/ was NOT checked."; \
	   echo "         exit 4: a linter with no agreed rule set has no verdict to give."; \
	   exit 4; \
	 fi; \
	 echo "  $(APP): eslint ($$E) with $$cfg"; \
	 $$E src/
build: ; @echo "$(APP): bare metal, nothing to build"
clean: ; @rm -rf .run
