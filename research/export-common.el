;;; export-common.el --- the export hook and settings shared by export-html.el and export-pdf.el  -*- lexical-binding: t -*-
;;;
;;; REVIEW COPY (scratchpad, 2026-09-15): the repo's file plus the changes
;;; recommended by the PDF review. Each change is marked ";; REVIEW:".

(require 'cl-lib)
(require 'ox-latex)

;; REVIEW: characters of \small text across the wide table measure
;; (\textwidth+4cm at 12pt is ~110); a table whose longest row fits in the
;; narrow measure stays at \textwidth.
(defvar sc-table-budget 100)
(defvar sc-table-narrow-budget 80)

(defun sc--table-align (rows)
  "ROWS is a list of lists of cell strings. Return a tabularx align spec.
Wide columns are X, weighted by their longest cell (capped), ragged right."
  (let* ((ncol (apply #'max (mapcar #'length rows)))
         (widths (make-vector ncol 0)))
    (dolist (r rows)
      (let ((i 0))
        (dolist (c r)
          (when (< i ncol)
            (aset widths i (max (aref widths i) (length (string-trim c)))))
          (setq i (1+ i)))))
    (let* ((ws (append widths nil))
           (total (apply #'+ ws))
           (budget sc-table-budget)
           (thresh (cond ((<= total budget) 1000)
                         (t (let ((tt 40))
                              (while (and (> tt 6)
                                          (> (apply #'+ (mapcar (lambda (w) (if (> w tt) 0 w)) ws))
                                             (- budget (* 12 (length (seq-filter (lambda (w) (> w tt)) ws))))))
                                (setq tt (- tt 2)))
                              tt))))
           (kinds (mapcar (lambda (w) (if (> w thresh) 'x 'l)) ws)))
      ;; a table with no wide column still needs one X for tabularx to be valid
      (unless (memq 'x kinds) (setcar (last kinds) 'x))
      ;; REVIEW: X columns share the free width in proportion to their longest
      ;; cell (floor 12, cap 90), and are set ragged right: no rivers, no
      ;; overfull \texttt tokens hitting the next column. hsize factors must
      ;; sum to the number of X columns, so the last one absorbs the rounding.
      ;; weight = sqrt of the longest cell (capped at 90), share clamped to
      ;; [0.6, 1.6] of an equal share: a column of short cells is narrower,
      ;; never too narrow for a word
      (let* ((xw (cl-loop for w in ws for k in kinds when (eq k 'x) collect (sqrt (float (min w 90)))))
             (nx (length xw))
             (sum (apply #'+ xw))
             (hs (mapcar (lambda (w) (min 1.6 (max 0.6 (/ (* w nx) sum)))) xw))
             (sum2 (apply #'+ hs))
             (hs (mapcar (lambda (h) (/ (fround (* 100.0 (/ (* h nx) sum2))) 100.0)) hs))
             (hs (append (butlast hs) (list (- nx (apply #'+ (butlast hs))))))
             (spec ""))
        (dolist (k kinds)
          (setq spec (concat spec
                             (if (eq k 'l) "l"
                               (prog1 (format ">{\\hsize=%.2f\\hsize\\raggedright\\arraybackslash}X" (car hs))
                                 (setq hs (cdr hs)))))))
        (cons spec total)))))

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
                  (let* ((spec+total (sc--table-align (nreverse rows)))
                         ;; REVIEW: a wide table overhangs the narrow prose
                         ;; measure by 2cm each side (longtable centres it)
                         (width (if (<= (cdr spec+total) sc-table-narrow-budget)
                                    "\\textwidth"
                                  "\\dimexpr\\textwidth+4cm\\relax")))
                    (insert (format "#+ATTR_LATEX: :environment tabularx :width %s :align %s :font \\small\n"
                                    width (car spec+total))))))))
          ;; skip the rest of this table
          (while (and (not (eobp)) (looking-at "^[ \t]*|")) (forward-line 1)))))))

;; REVIEW: booktabs rules, and the header row repeats on every page of a
;; table ltablex breaks (\endhead). Runs on the LaTeX string ox-latex made.
(defun sc-booktabs-table (table backend _info)
  (when (org-export-derived-backend-p backend 'latex)
    (let ((s table))
      ;; first rule after the header row: \midrule, then \endhead
      (when (string-match "\\\\\\\\\n\\\\hline\n" s)
        (setq s (replace-match "\\\\\\\\\n\\\\midrule\\\\endhead\n" t nil s)))
      (setq s (replace-regexp-in-string "^\\\\hline\n" "\\\\midrule\n" s))
      (setq s (replace-regexp-in-string "\\(\\\\begin{tabularx}{[^}]*}{[^\n]*}\n\\)" "\\1\\\\toprule\n" s))
      (setq s (replace-regexp-in-string "\\\\end{tabularx}" "\\\\bottomrule\n\\\\end{tabularx}" s))
      ;; a table set wider than the measure overhangs it by 2cm each side;
      ;; longtable's default \LTleft=\fill cannot go negative and reports the
      ;; excess as overfull, so the skips are fixed inside the table's group
      (when (string-match-p "dimexpr" s)
        (setq s (concat "{\\setlength\\LTleft{-2cm}\\setlength\\LTright{-2cm}\n" s "}")))
      s)))
(add-to-list 'org-export-filter-table-functions #'sc-booktabs-table)

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

;; REVIEW: the five level-1 headings become \part (class "research" below),
;; which numbers them itself; the "Part I: " the org text carries is dropped
;; for LaTeX only, so HTML keeps it.
(defun sc-part-headings (backend)
  (when (org-export-derived-backend-p backend 'latex)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^\\* Part [IVX]+: " nil t)
        (replace-match "* ")))))

;; REVIEW: :VERIFIED:/:VERDICT:/:SOURCE:/:FINDING: are not exported at all
;; (org-export-with-properties is nil, and exporting them gives a verbatim
;; dump). They become a description list under the heading, in both backends;
;; :CUSTOM_ID: stays in the drawer so [[#id]] links keep resolving.
(defun sc-render-verdict-drawers (_backend)
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward "^[ \t]*:PROPERTIES:[ \t]*\n" nil t)
      (let ((beg (match-beginning 0)) props)
        (when (re-search-forward "^[ \t]*:END:[ \t]*\n" nil t)
          ;; a marker: the deletions inside the drawer move it; point must end
          ;; past the drawer whether or not it had anything to render, or a
          ;; drawer with only :CUSTOM_ID: is found again forever
          (let ((end (copy-marker (match-end 0))))
            (save-restriction
              (narrow-to-region beg end)
              (goto-char (point-min))
              (while (re-search-forward "^[ \t]*:\\(VERIFIED\\|VERDICT\\|SOURCE\\|FINDING\\):[ \t]*\\(.*\\)\n" nil t)
                (push (cons (match-string 1) (match-string 2)) props)
                (replace-match "")))
            (goto-char end)
            (set-marker end nil))
          (when props
            (let ((verdict (cdr (assoc "VERDICT" props)))
                  (verified (cdr (assoc "VERIFIED" props)))
                  (source (cdr (assoc "SOURCE" props)))
                  (finding (cdr (assoc "FINDING" props))))
              (insert (format "- verdict :: %s%s%s\n%s\n"
                              (or verdict "unverified")
                              (if verified (format " (%s)" verified) "")
                              (if source (format ", [[%s][source]]" source) "")
                              (if finding (format "- finding :: %s" finding) ""))))))))))

;;; MERMAID -> FIGURES. Eight diagrams exported as verbatim text. mermaid-cli
;;; (mmdc) renders each block at export time and the block becomes a figure.
;;; Two facts found on 2026-09-15: mmdc needs a browser, given by
;;; ../puppeteer.json (the desktop Chrome); and mermaid 10.9 refuses a colon
;;; inside a state transition's label, which every label here has (change:start),
;;; so the rendering copy writes those colons as #58; and the org source is
;;; untouched. A block mmdc cannot render stays verbatim and says so in the log.
;;; REVIEW: LaTeX gets a vector PDF at the diagram's natural size (--pdfFit)
;;; included at "max width=\linewidth" (adjustbox), so a two-node diagram is
;;; not stretched across the page; HTML keeps the 2x PNG.
(defvar sc-mermaid-counter 0)
(defun sc--mermaid-fix-colons (body)
  "In stateDiagram transition lines, a colon after the first is #58;."
  (mapconcat
   (lambda (line)
     (if (string-match "^\\(.*-->[^:]*:\\)\\(.*\\)$" line)
         (concat (match-string 1 line)
                 (replace-regexp-in-string ":" "#58;" (match-string 2 line)))
       line))
   (split-string body "\n") "\n"))
(defun sc-render-mermaid (backend)
  (let ((latex (org-export-derived-backend-p backend 'latex)))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^[ \t]*#\\+begin_src mermaid[^\n]*\n" nil t)
        (let ((beg (match-beginning 0)) (body-start (match-end 0)))
          (when (re-search-forward "^[ \t]*#\\+end_src[ \t]*$" nil t)
            (let* ((body-end (match-beginning 0)) (end (match-end 0))
                   (body (buffer-substring-no-properties body-start body-end))
                   (n (setq sc-mermaid-counter (1+ sc-mermaid-counter)))
                   (mmd (format "mermaid-%d.mmd" n))
                   (out (format "mermaid-%d.%s" n (if latex "pdf" "png"))))
              (with-temp-file mmd (insert (sc--mermaid-fix-colons body)))
              (if (= 0 (apply #'call-process "mmdc" nil "*mmdc*" nil
                              "-p" "../puppeteer.json" "-i" mmd "-o" out "-b" "white"
                              (if latex '("--pdfFit") '("-s" "2"))))
                  (progn (delete-region beg end)
                         (goto-char beg)
                         (insert (format "#+ATTR_LATEX: :options max width=\\linewidth\n#+ATTR_HTML: :style max-width:100%%\n[[file:%s]]\n" out)))
                (message "mermaid: block %d not rendered, left verbatim" n)))))))))
(add-hook 'org-export-before-parsing-functions #'sc-render-mermaid 50)

(add-hook 'org-export-before-parsing-functions #'sc-strip-included-keywords)
(add-hook 'org-export-before-parsing-functions #'sc-part-headings 10)
(add-hook 'org-export-before-parsing-functions #'sc-render-verdict-drawers 20)
(add-hook 'org-export-before-parsing-functions #'sc-wrap-wide-tables 90)

;; REVIEW: article with \part on top. Level 4 stays a run-in \paragraph (the
;; third entry is skipped on purpose): parts I-V, documents 1-37 numbered
;; straight through, subsections n.m, and the 291 level-4 headings unnumbered.
(add-to-list 'org-latex-classes
             '("research" "\\documentclass{article}"
               ("\\part{%s}" . "\\part*{%s}")
               ("\\section{%s}" . "\\section*{%s}")
               ("\\subsection{%s}" . "\\subsection*{%s}")
               ("\\paragraph{%s}" . "\\paragraph*{%s}")))

(setq org-latex-src-block-backend 'verbatim   ; the preamble turns verbatim into fvextra's Verbatim, which wraps
      org-export-use-babel nil                ; export never evaluates a block (gentle-symbolic-computation)
      org-latex-compiler "xelatex"
      org-latex-tables-centered nil
      org-confirm-babel-evaluate nil
      org-export-with-broken-links 'mark
      ;; REVIEW: longtable/ltablex needs more passes than org's fixed three
      ;; (45 § links were still undefined after three); latexmk iterates to a
      ;; fixed point. Keep the log so gmake can grep it.
      org-latex-pdf-process '("latexmk -xelatex -interaction=nonstopmode -output-directory=%o %f")
      org-latex-remove-logfiles nil
      ;; REVIEW: the contents end on a page of their own
      org-latex-toc-command "\\tableofcontents\\clearpage\n\n")
