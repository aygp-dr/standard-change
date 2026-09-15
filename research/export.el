;;; export.el --- build research/index.org as HTML and PDF in batch.  -*- lexical-binding: t -*-
;;; emacs --batch -l org -l export.el   (run from research/build/, see the Makefile)
(defun sc-strip-included-keywords (_backend)
  "Included org files carry their own #+TITLE/#+DATE; drop every keyword after
the master's own header so the title is the master's."
  (save-excursion
    (goto-char (point-min)) (forward-line 8)
    (while (re-search-forward "^#\\+\\(TITLE\\|DATE\\|AUTHOR\\|OPTIONS\\|SUBTITLE\\|LATEX_HEADER\\|LATEX_CLASS\\):.*\n" nil t)
      (replace-match ""))))
(add-hook 'org-export-before-parsing-functions #'sc-strip-included-keywords)
(setq org-latex-compiler "xelatex"
      org-confirm-babel-evaluate nil
      org-export-with-broken-links 'mark)
(find-file "index.org")
(org-html-export-to-html)
(org-latex-export-to-pdf)
