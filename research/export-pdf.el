;;; export-pdf.el -*- lexical-binding: t -*-
(load-file "../export-common.el")
(find-file (concat (or (getenv "VOL") "index") ".org"))
(org-latex-export-to-pdf)
