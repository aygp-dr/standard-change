.PHONY: port-alloc port-free dev router gate gate-selftest simulate
port-alloc:      ; ./change/ports.sh alloc
port-free:       ; ./change/ports.sh free
router:          ; ./router/render.sh && nginx -c "$$PWD/.nginx.conf" -p "$$PWD"
dev: router      ; ./change/ports.sh run-apps        # starts apps present in this worktree; others resolve to block 0
gate:            ; ./gates/lint.sh && ./gates/test.sh && ./gates/e2e.sh $(app)
gate-selftest:   ; ./gates/selftest.sh
simulate:        ; ./change/simulate.sh $(app)
