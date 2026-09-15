;;; export-common.el --- the export hook and settings shared by export-html.el and export-pdf.el  -*- lexical-binding: t -*-
;;;
;;; Two things the raw export got wrong on 2026-09-15 (187 pages):
;;;   1. included files carry their own #+TITLE/#+DATE; the title became a
;;;      heading and the other keywords are dropped, so the master's title wins.
;;;   2. 229 tables overflowed the text width (the worst by 2580pt): ox-latex
;;;      emits `tabular', which never wraps a cell. Every table without its
;;;      own #+ATTR_LATEX gets one: tabularx over \textwidth (page-breaking via
;;;      ltablex), X for columns whose longest cell is wide, l otherwise, and
;;;      \small. Fonts: STIX Two Text covers the arrows and set symbols Charter
;;;      lacked (100 missing glyphs, 78 of them a right arrow).

(defun sc--table-align (rows)
  "ROWS is a list of lists of cell strings. Return a tabularx align spec."
  (let* ((ncol (apply #'max (mapcar #'length rows)))
         (widths (make-vector ncol 0)))
    (dolist (r rows)
      (let ((i 0))
        (dolist (c r)
          (when (< i ncol)
            (aset widths i (max (aref widths i) (length (string-trim c)))))
          (setq i (1+ i)))))
    ;; text width is ~95 chars of \small; every column wider than the budget
    ;; share wraps, widest first, until the fixed columns fit
    (let* ((total (apply #'+ (append widths nil)))
           (budget 90)
           (thresh (cond ((<= total budget) 1000)
                         (t (let ((tt 40))
                              (while (and (> tt 6)
                                          (> (apply #'+ (mapcar (lambda (w) (if (> w tt) 0 w)) (append widths nil)))
                                             (- budget (* 12 (length (seq-filter (lambda (w) (> w tt)) (append widths nil)))))))
                                (setq tt (- tt 2)))
                              tt))))
           (spec ""))
      (dotimes (i ncol)
        (setq spec (concat spec (if (> (aref widths i) thresh) "X" "l"))))
      ;; a table with no wide column still needs one X for tabularx to be valid
      (if (string-match-p "X" spec) spec
        (concat (substring spec 0 (1- (length spec))) "X")))))

(defun sc-wrap-wide-tables (backend)
  "Before every org table lacking #+ATTR_LATEX, insert one that wraps."
  (when (org-export-derived-backend-p backend 'latex)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^[ \t]*|" nil t)
        (beginning-of-line)
        (let ((start (point)) rows)
          ;; only the first line of a table block
          (unless (save-excursion (forward-line -1) (looking-at "^[ \t]*|"))
            (let ((prev (save-excursion (forward-line -1) (buffer-substring (line-beginning-position) (line-end-position)))))
              (unless (string-match-p "^#\\+ATTR_LATEX" prev)
                ;; collect rows
                (save-excursion
                  (while (looking-at "^[ \t]*|")
                    (let ((l (buffer-substring (line-beginning-position) (line-end-position))))
                      (unless (string-match-p "^[ \t]*|-" l)
                        (push (split-string (string-trim l "[ \t|]+" "[ \t|]+") "|") rows)))
                    (forward-line 1)))
                (when rows
                  (goto-char start)
                  (insert (format "#+ATTR_LATEX: :environment tabularx :width \\textwidth :align %s :font \\small\n"
                                  (sc--table-align (nreverse rows))))))))
          ;; skip the rest of this table
          (while (and (not (eobp)) (looking-at "^[ \t]*|")) (forward-line 1)))))))

(defun sc-strip-included-keywords (_backend)
  "Included org files carry their own #+TITLE/#+DATE; the title becomes a
heading and every other keyword after the master's own header is dropped."
  (save-excursion
    ;; the master's own keywords end at its first heading; strip only after it
    (goto-char (point-min)) (re-search-forward "^\\* " nil t) (beginning-of-line)
    (let ((from (point)))
      (while (re-search-forward "^#\\+TITLE: \\(.*\\)\n" nil t)
        (replace-match "** \\1\n"))
      (goto-char from))
    (while (re-search-forward "^#\\+\\(DATE\\|AUTHOR\\|OPTIONS\\|SUBTITLE\\|LATEX_HEADER\\|LATEX_CLASS\\):.*\n" nil t)
      (replace-match ""))))

(add-hook 'org-export-before-parsing-functions #'sc-strip-included-keywords)
(add-hook 'org-export-before-parsing-functions #'sc-wrap-wide-tables 90)
(setq org-latex-compiler "xelatex"
      org-latex-tables-centered nil
      org-confirm-babel-evaluate nil
      org-export-with-broken-links 'mark)
