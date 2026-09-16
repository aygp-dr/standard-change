;;; export-pdf.el -*- lexical-binding: t -*-
(load-file "../export-common.el")
(find-file "index.org")
(org-latex-export-to-pdf)
