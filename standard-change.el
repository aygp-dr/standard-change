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

(provide 'standard-change)
;;; standard-change.el ends here
