;;; export-html.el -*- lexical-binding: t -*-
(load-file "../export-common.el")
(find-file "index.org")
(org-html-export-to-html)
