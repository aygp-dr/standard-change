# apps/mock — same targets in every app directory, by convention.
APP        := mock
PORT_OFFSET := 5
-include ../../.env
PORT ?= $(shell expr $(BASE_PORT) + $(PORT_OFFSET))

.PHONY: help dev test lint build clean
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
build: ; @echo "$(APP): bare metal, nothing to build"
clean: ; @rm -rf .run
