# apps/core — same targets in every app directory, by convention.
APP        := core
PORT_OFFSET := 1
-include ../../.env
PORT ?= $(shell expr $(BASE_PORT) + $(PORT_OFFSET))

.PHONY: help dev test lint build clean
help:  ; @echo "$(APP): dev test lint build  (port $(PORT))"
dev:   ; BUILD_SHA=$(BUILD_SHA) BLOCK=$(BLOCK) PORT=$(PORT) node src/server.js
test:  ; node --test
lint:  ; node --check src/server.js && jq -e . routes.json >/dev/null && echo "$(APP) lint ok"
build: ; @echo "$(APP): bare metal, nothing to build"
clean: ; @rm -rf .run
