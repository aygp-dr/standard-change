# gmake                 -> the complete edition, HTML and PDF, into build/
# gmake VOL=vol-adopting pdf   -> one volume (vol-adopting, vol-rules, vol-running, vol-history)
# gmake volumes         -> every volume, PDF
# gmake html | pdf | check | org | clean
# Shape from aygp-dr/gentle-symbolic-computation and jwalsh/build-a-clojure; see export-common.el.
VOL ?= index
VOLUMES = vol-adopting vol-rules vol-running vol-history
.PHONY: all build html pdf check org clean volumes
all build: html pdf
build/$(VOL).org: $(VOL).org preamble.org adoption.org $(wildcard history/*.org substrates/*.org findings/*.org appendix/*.org) $(wildcard ../experiments/*/notes.org ../experiments/*/README.org ../experiments/*/REVIEW.org ../experiments/*/PARING.org)
	@python3 generate.py >/dev/null
	@mkdir -p build && sed -e 's|^#+INCLUDE: "|#+INCLUDE: "../|' -e 's|^#+SETUPFILE: |#+SETUPFILE: ../|' $(VOL).org > build/$(VOL).org
check: build/$(VOL).org
	@cd build && emacs --batch -l org -l ox --eval '(progn (find-file "$(VOL).org") (org-export-expand-include-keyword) (message "includes resolved: %d lines" (count-lines (point-min) (point-max))))' 2>&1 | grep -E 'resolved|Cannot include|Error'
org: build/$(VOL).org
	@cd build && emacs --batch -l org -l ox --eval '(progn (find-file "$(VOL).org") (org-export-expand-include-keyword) (write-region (point-min) (point-max) "$(VOL)-expanded.org"))' 2>&1 | grep -E "Error" ; ls -la $(VOL)-expanded.org
html: build/$(VOL).org
	@cd build && VOL=$(VOL) emacs --batch -l org -l ../export-html.el 2>&1 | grep -E 'Error|error' || true; ls -la $(VOL).html
pdf: build/$(VOL).org
	@cd build && VOL=$(VOL) emacs --batch -l org -l ../export-pdf.el 2>&1 | grep -E 'Error|error' || true; ls -la $(VOL).pdf
volumes:
	@for v in $(VOLUMES); do $(MAKE) -s VOL=$$v pdf; done
clean: ; @rm -rf build
