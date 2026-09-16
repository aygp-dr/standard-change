;;; export-html.el -*- lexical-binding: t -*-
(load-file "../export-common.el")
(find-file (concat (or (getenv "VOL") "index") ".org"))
(org-html-export-to-html)
