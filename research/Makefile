# gmake            -> HTML and PDF into build/
# gmake html | pdf -> one of them
# gmake check      -> resolve every #+INCLUDE without exporting (a renamed file breaks an include silently)
# gmake org        -> one carryable index-expanded.org with every include resolved
# gmake clean
# Shape from aygp-dr/gentle-symbolic-computation (publish per format, check target) and
# jwalsh/build-a-clojure (front-matter stripper, book-check); see export-common.el.
.PHONY: all build html pdf check org clean
all build: html pdf
build/index.org: index.org adoption.org $(wildcard history/*.org substrates/*.org findings/*.org appendix/*.org) $(wildcard ../experiments/*/notes.org ../experiments/*/README.org ../experiments/*/REVIEW.org ../experiments/*/PARING.org)
	@python3 generate.py >/dev/null
	@mkdir -p build && sed 's|^#+INCLUDE: "|#+INCLUDE: "../|' index.org > build/index.org
check: build/index.org
	@cd build && emacs --batch -l org -l ox --eval '(progn (find-file "index.org") (org-export-expand-include-keyword) (message "includes resolved: %d lines" (count-lines (point-min) (point-max))))' 2>&1 | grep -E 'resolved|Cannot include|Error' 
org: build/index.org
	@cd build && emacs --batch -l org -l ox --eval '(progn (find-file "index.org") (org-export-expand-include-keyword) (write-region (point-min) (point-max) "index-expanded.org"))' 2>&1 | grep -E "Error" ; ls -la index-expanded.org
html: build/index.org
	@cd build && emacs --batch -l org -l ../export-html.el 2>&1 | grep -E 'Error|error' || true; ls -la index.html
pdf: build/index.org
	@cd build && emacs --batch -l org -l ../export-pdf.el 2>&1 | grep -E 'Error|error' || true; ls -la index.pdf
clean: ; @rm -rf build
