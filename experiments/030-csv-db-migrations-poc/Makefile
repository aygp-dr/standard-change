# gmake db-migrate  -> apply pending migrations (idempotent: applied ones are skipped)
# gmake db-rollback -> roll back the single most recently applied migration
# gmake db-seed     -> load reference data, separate from migrations (db/seeds.sh)
# gmake db-status   -> show the ledger (db/tables/migrations.csv) without changing anything
# gmake db-check    -> prove idempotency: run db-migrate twice, fail if the ledger changed the second time
# gmake db-reset    -> roll back everything, back to no ledger rows
.PHONY: db-migrate db-rollback db-seed db-status db-check db-reset

LEDGER := db/tables/migrations.csv

db-migrate:
	./migrate.sh up

db-rollback:
	./migrate.sh down

db-seed:
	./db/seeds.sh

db-status:
	@if [ -f $(LEDGER) ]; then \
	  xsv table $(LEDGER) 2>/dev/null || column -s, -t $(LEDGER) 2>/dev/null || cat $(LEDGER); \
	else \
	  echo "no ledger yet -- run gmake db-migrate"; \
	fi

db-check: db-migrate
	@before=$$(cat $(LEDGER)); \
	./migrate.sh up >/dev/null; \
	after=$$(cat $(LEDGER)); \
	if [ "$$before" = "$$after" ]; then \
	  echo "idempotent: re-running db-migrate changed nothing in $(LEDGER)"; \
	else \
	  echo "NOT idempotent: $(LEDGER) changed on re-run" >&2; \
	  exit 1; \
	fi

db-reset:
	@while [ -f $(LEDGER) ] && [ "$$(wc -l < $(LEDGER) | tr -d ' ')" -gt 1 ]; do ./migrate.sh down; done
