# gmake            -> HTML and PDF into build/
# gmake html | pdf -> one of them
# gmake clean
.PHONY: all build html pdf clean
all build: html pdf
build/index.org: index.org adoption.org $(wildcard ../docs/*.org) $(wildcard ../experiments/*/notes.org)
	@mkdir -p build && sed 's|^#+INCLUDE: "|#+INCLUDE: "../|' index.org > build/index.org
html: build/index.org
	@cd build && emacs --batch -l org -l ../export-html.el 2>&1 | grep -E 'Error|error' || true; ls -la index.html
pdf: build/index.org
	@cd build && emacs --batch -l org -l ../export-pdf.el 2>&1 | grep -E 'Error|error' || true; ls -la index.pdf
clean: ; @rm -rf build
