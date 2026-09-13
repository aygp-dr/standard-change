;;; standard-change.el --- forge + pipeline view for standard-change  -*- lexical-binding: t; -*-

;; Validate:  emacs -Q -nw -l standard-change.el -f standard-change-status
;;            emacs -Q -nw -l standard-change.el -f standard-change-prs
;; or from an existing config:  (load "/path/to/slipway/forge.el")
;;
;; Forge (https://github.com/magit/forge) puts the repo's pull requests and
;; issues in the same buffer as its branches, which is the view this pipeline
;; actually needs: `deploy:*' labels, the berth holder, and the branch state
;; are one thing to look at rather than three.

;;; Code:

(require 'package)

(defvar standard-change-repo "aygp-dr/standard-change"
  "The GitHub repository this config is for.")

(defvar standard-change-root
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Root of the working copy, wherever this file was loaded from.")

;;;; Bootstrap ---------------------------------------------------------------

(unless (assoc "melpa" package-archives)
  (add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t))

(defun standard-change--ensure (&rest pkgs)
  "Install each of PKGS that is missing. Returns the list installed.

Refreshes and retries once on failure: a cached archive index goes stale and
MELPA drops the old tarballs, so the first install 404s on a dependency
rather than on the package you asked for -- which reads like the package is
missing when the index is."
  (let (installed)
    (dolist (p pkgs)
      (unless (package-installed-p p)
        (unless package-archive-contents (package-refresh-contents))
        (condition-case _err
            (package-install p)
          (error
           (message "standard-change: install of %s failed; refreshing archives" p)
           (package-refresh-contents)
           (package-install p)))
        (push p installed)))
    (nreverse installed)))

(package-initialize)
(standard-change--ensure 'magit 'forge)

(require 'magit)
(require 'forge)

;;;; Configuration -----------------------------------------------------------

;; Show the labels column: with this pipeline the labels ARE the state, so a PR
;; list without them says nothing about where a change actually is.
(setq forge-topic-list-columns
      '(("#"      5 t (:right-align t) number nil)
        ("Title" 42 t nil title nil)
        ("Labels" 34 t nil labels nil)
        ("State"  8 t nil state nil)
        ("Updated" 10 t nil updated nil)))

;; Pull every open topic; this repo is small and the queue view wants all of it.
(setq forge-pull-notifications nil)

;;;; Self-check --------------------------------------------------------------

(defun standard-change-forge-check ()
  "Report whether forge can actually see this repo's PRs. Prints to stdout."
  (interactive)
  (let* ((default-directory standard-change-root)
         (lines '()))
    (push (format "emacs        %s" emacs-version) lines)
    (push (format "magit        %s" (if (featurep 'magit) (magit-version) "MISSING")) lines)
    (push (format "forge        %s" (if (featurep 'forge) "loaded" "MISSING")) lines)
    (push (format "closql       %s" (if (locate-library "closql") "present" "MISSING")) lines)
    (push (format "repo root    %s" default-directory) lines)
    (push (format "git remote   %s"
                  (or (magit-get "remote" "origin" "url") "NONE")) lines)
    ;; auth-source is what ghub reads; a token must exist or every pull 404s
    (let ((auth (ignore-errors
                  (auth-source-search :host "api.github.com" :max 1))))
      (push (format "api token    %s"
                    (if auth "found in auth-source"
                      "MISSING -- add to ~/.authinfo:\n             machine api.github.com login <user>^forge password <token>"))
            lines))
    ;; ghub needs this even with a token in auth-source; without it every
    ;; pull dies with "Cannot determine username".
    (push (format "github.user  %s"
                  (or (magit-get "github.user") "UNSET -- git config --global github.user <login>"))
          lines)
    (push (format "forge db     %s"
                  (if (file-exists-p (expand-file-name "forge-database.sqlite"
                                                       user-emacs-directory))
                      "exists" "not yet created (forge-pull will make it)"))
          lines)
    (let ((out (mapconcat #'identity (nreverse lines) "\n  ")))
      (princ (concat "  " out "\n"))
      out)))


;;;; The pipeline view ---------------------------------------------------------

(defun standard-change--run (buf &rest argv)
  "Run ARGV at the repo root, into BUF. Returns the buffer.

The program is expanded against the root: `call-process' resolves a relative
program name against `exec-path', not `default-directory', so \"./status\"
fails with \"Searching for program\" even when the cwd is right."
  (let* ((default-directory standard-change-root)
         (prog (car argv))
         (prog (if (string-prefix-p "./" prog)
                   (expand-file-name prog standard-change-root)
                 prog))
         (argv (cons prog (cdr argv)))
         (b (get-buffer-create buf)))
    (with-current-buffer b
      (let ((inhibit-read-only t))
        (erase-buffer)
        (apply #'call-process (car argv) nil t nil (cdr argv))
        (goto-char (point-min))
        (special-mode)))
    b))

;;;###autoload
(defun standard-change-status ()
  "Show the queue: who holds the berth, who waits, and any violations.

This is ./status, which answers the three questions the labels encode.
Works with no forge token -- it shells out to gh."
  (interactive)
  (pop-to-buffer (standard-change--run "*change: queue*" "./status")))

;;;###autoload
(defun standard-change-prs ()
  "List open PRs with their pipeline labels.

Uses forge when it has a token, since that view is live and navigable.
Falls back to gh otherwise, because a missing token should degrade to a
worse view rather than to no view."
  (interactive)
  (if (and (featurep 'forge)
           (ignore-errors (auth-source-search :host "api.github.com" :max 1)))
      (progn (require 'forge) (call-interactively #'forge-list-pullreqs))
    (pop-to-buffer
     (standard-change--run "*change: PRs*" "gh" "pr" "list"
                           "--repo" standard-change-repo
                           "--json" "number,title,labels,headRefName"
                           "--template"
                           (concat "{{range .}}#{{.number}}  {{.headRefName}}"
                                   "\n    {{.title}}"
                                   "\n    labels: {{range .labels}}{{.name}} {{end}}"
                                   "\n\n{{end}}")))))


;;;; The label vocabulary ----------------------------------------------------
;;
;; READ FROM THE DECLARATION, NEVER RETYPED HERE.
;;
;; `change/label-owners.tsv' is the single declaration of every label, its
;; owner, and which of add/remove a human may do. Copying that list into elisp
;; would make this file a second source of truth for the same fact, which is
;; the drift defect this repo keeps finding -- the dashboard did it with the
;; environment list, spec.org did it with the support matrix, and both went
;; stale without anyone editing them.
;;
;; So: parse the tsv. If a label is added to the declaration it appears here
;; with no change to this file, and if the declaration is unreadable that is
;; reported as unknown rather than as an empty vocabulary.

(defconst standard-change-label-namespaces
  '(("itil:"       . "classification -- what KIND of change. Exactly one.")
    ("change:"     . "lifecycle -- how far it has got. At most one active.")
    ("app:"        . "blast radius -- which groups the diff touches. Labeller-owned.")
    ("staging:"    . "observation on staging, by the instrument that measured it.")
    ("production:" . "observation on production, same rule.")
    ("deploy:"     . "ACTION in flight. deploy:staging IS the berth.")
    ("blocked:"    . "why a guard refused.")
    ("review:"     . "who accepted it, and whether they were a person.")
    ("release"     . "human INTENT to ship. A person adds it; automation clears it."))
  "What each prefix MEANS. Deliberately not a list of labels -- the labels
live in the declaration and are read from it. This is the part a reader
needs that a tsv column cannot carry.")

(defconst standard-change-estate-labels '("freeze" "emergency")
  "Bare labels that are properties of the WORLD, not of any change.

They live on the estate issue, NOT on a pull request. PR #48 found why: a PR
carrying `itil:emergency' is a change, and the same write that closes the
estate to everyone else exempts its own carrier. An issue cannot be deployed,
so there is no exemption it could be handed.

Note `emergency' (the estate is shut) is a different fact from
`itil:emergency' (this change is the remedy, and passes both a freeze and an
estate emergency). Two namespaces, two subjects.")

(defun standard-change--declaration ()
  "Parse `change/label-owners.tsv' into (LABEL OWNER PERSISTENT HUMAN-ADD HUMAN-RM NOTE).
Returns nil if the file cannot be read -- callers must treat that as
unknown, not as \"there are no labels\"."
  (let ((f (expand-file-name "change/label-owners.tsv" standard-change-root)))
    (when (file-readable-p f)
      (with-temp-buffer
        (insert-file-contents f)
        (let (rows)
          (dolist (line (split-string (buffer-string) "\n" t))
            (unless (string-prefix-p "#" line)
              (let ((f (split-string line "\t")))
                (when (and (>= (length f) 6) (not (equal (nth 0 f) "exclusive")))
                  (push f rows)))))
          (nreverse rows))))))

;;;###autoload
(defun standard-change-labels ()
  "Show the label declaration: every label, its owner, and who may write it.

Read live from `change/label-owners.tsv'. If that file is unreadable this
says so rather than showing an empty list, because an empty vocabulary and an
unreadable one are different facts."
  (interactive)
  (let ((rows (standard-change--declaration))
        (buf (get-buffer-create "*change: labels*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (if (null rows)
            (insert "change/label-owners.tsv is unreadable.\n\n"
                    "This is NOT \"there are no labels\" -- it is \"I could not "
                    "check\".\nFix the path or the file before trusting any "
                    "view that depends on it.\n")
          (insert "THE PREFIXES\n\n")
          (dolist (ns standard-change-label-namespaces)
            (insert (format "  %-13s %s\n" (car ns) (cdr ns))))
          (insert "\nESTATE LABELS -- on the estate issue, never on a PR\n\n")
          (dolist (l standard-change-estate-labels)
            (insert (format "  %-13s %s\n" l
                            "a property of the world; blocks everyone including its declarer")))
          (insert (format "\nTHE DECLARATION -- %d labels, read from change/label-owners.tsv\n\n"
                          (length rows)))
          (insert (format "  %-26s %-24s %-4s %-4s %s\n"
                          "LABEL" "OWNER" "PERS" "HUM" "NOTE"))
          (dolist (r rows)
            (insert (format "  %-26s %-24s %-4s %-4s %s\n"
                            (nth 0 r) (nth 1 r) (nth 2 r)
                            (concat (if (equal (nth 3 r) "yes") "+" "-")
                                    (if (equal (nth 4 r) "yes") "-" " "))
                            (truncate-string-to-width (or (nth 5 r) "") 70)))))
        (goto-char (point-min))
        (special-mode)))
    (pop-to-buffer buf)))

;;;; Batch entry points -------------------------------------------------------
;; So `gmake forge` works whether or not an interactive Emacs is running.
;; forge-list-pullreqs is a tabulated-list command and needs a live frame, so
;; batch mode reads the forge database directly instead.

(defun standard-change--repo ()
  (let ((default-directory standard-change-root))
    (require 'forge)
    (forge-get-repository :tracked?)))

;;;###autoload
(defun standard-change-forge-pull ()
  "Refresh forge's local database from the forge. Safe in batch."
  (interactive)
  (let ((default-directory standard-change-root))
    (require 'forge)
    (let ((repo (or (standard-change--repo) (forge-get-repository :insert!))))
      (forge--pull repo (lambda (_) (princ "  forge: pulled\n")))
      (sleep-for 12))))

;;;###autoload
(defun standard-change-forge-list ()
  "Print open pull requests from forge's database, with their labels."
  (interactive)
  (let ((default-directory standard-change-root))
    (require 'forge)
    (let* ((repo (standard-change--repo))
           (db (and repo (expand-file-name "forge-database.sqlite" user-emacs-directory))))
      (if (not (and db (file-exists-p db)))
          (princ "  forge: no database -- run `gmake forge-pull` first\n")
        ;; closql's accessors move between versions; the schema does not.
        (let ((rows (emacsql (forge-db)
                             [:select [number title state] :from pullreq
                              :where (= repository $s1) :order-by [(asc number)]]
                             (oref repo id))))
          (if (null rows)
              (princ "  forge: no pull requests in the database\n")
            (dolist (r rows)
              (princ (format "  #%-4s %-46s %s\n"
                             (nth 0 r)
                             (truncate-string-to-width (format "%s" (nth 1 r)) 46)
                             (nth 2 r))))))))))

(provide 'standard-change)
;;; standard-change.el ends here
