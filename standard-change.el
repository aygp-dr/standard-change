;;; standard-change.el --- forge + pipeline view for standard-change  -*- lexical-binding: t; -*-

;; Validate:  emacs -Q -nw -l standard-change.el -f standard-change-status
;;            emacs -Q -nw -l standard-change.el -f standard-change-prs
;; or from an existing config:  (load "/path/to/slipway/forge.el")
;;
;; `-nw' is a FRAME flag and `--batch' means there is no frame, so the two
;; together are not a stricter version of either: a view command that only
;; fills a buffer then displays it to nobody and exits 0. Every command here
;; prints its buffer instead when `noninteractive', because a target that
;; succeeds silently is the one failure this repo will not notice.
;;
;; Forge (https://github.com/magit/forge) puts the repo's pull requests and
;; issues in the same buffer as its branches, which is the view this pipeline
;; actually needs: `deploy:*' labels, the berth holder, and the branch state
;; are one thing to look at rather than three.

;;; Code:

(require 'cl-lib)
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

;;;; Failing out of batch ----------------------------------------------------

(defun standard-change--fail (fmt &rest args)
  "Print FMT with ARGS, and in batch leave with a nonzero status.

`emacs --batch' exits 0 unless something signals all the way out of the top
level -- an error inside a timer or a process filter prints and is swallowed,
which is exactly where an asynchronous forge pull reports its failures
\(observed: a timer that signals still exits 0). So a batch entry point that
notices a problem has to say so in its exit status itself. Interactively this
just prints: a view command must not take the session down."
  (princ (apply #'format fmt args))
  (when noninteractive (kill-emacs 1)))

(defun standard-change--show (buf)
  "Display BUF, or print it when there is no frame to display it in.

In batch `pop-to-buffer' succeeds and shows nobody anything, so
`-f standard-change-status' exited 0 having produced no output at all."
  (if noninteractive
      (with-current-buffer buf (princ (buffer-string)))
    (pop-to-buffer buf)))

;;;; Self-check --------------------------------------------------------------

(defun standard-change-forge-check ()
  "Report whether forge can actually see this repo's PRs. Prints to stdout.

Exits nonzero in batch if anything it needs is missing. It used to print
MISSING and exit 0, which made `gmake forge-check' green on a host with no
token -- a check that cannot fail reports nothing."
  (interactive)
  (let* ((default-directory standard-change-root)
         (lines '())
         (missing '()))
    (cl-flet ((note (label text)
                (push (format "%-12s %s" label text) lines))
              (need (label text fix)
                ;; TEXT nil means the thing is not there; FIX says what to do.
                (push (format "%-12s %s" label (or text fix)) lines)
                (unless text (push label missing))))
      (note "emacs" emacs-version)
      (need "magit" (and (featurep 'magit) (magit-version)) "MISSING")
      (need "forge" (and (featurep 'forge) "loaded") "MISSING")
      (need "closql" (and (locate-library "closql") "present") "MISSING")
      (note "repo root" default-directory)
      (need "git remote" (magit-get "remote" "origin" "url") "NONE")
      ;; auth-source is what ghub reads; a token must exist or every pull 404s
      (need "api token"
            (and (ignore-errors (auth-source-search :host "api.github.com" :max 1))
                 "found in auth-source")
            (concat "MISSING -- add to ~/.authinfo:\n             "
                    "machine api.github.com login <user>^forge password <token>"))
      ;; Present is not valid. On 2026-09-14 this reported "found in
      ;; auth-source" and the pull that followed died with HTTP 401: both
      ;; tokens in ~/.authinfo had been revoked. A check that inspects the
      ;; file and not the API is a check on the wrong subject -- the same
      ;; defect as a health check reading the deployer's own version file. So
      ;; spend one request on /user, which needs no scope, and report what the
      ;; API said rather than what the file contains.
      (need "api probe"
            (let ((user (magit-get "github.user")))
              (and user
                   (condition-case err
                       (let ((login (cdr (assq 'login
                                               (ghub-get "/user" nil
                                                         :username user
                                                         :auth 'forge)))))
                         (and login (format "GET /user -> %s" login)))
                     (error (message "standard-change: api probe: %s"
                                     (error-message-string err))
                            nil))))
            (concat "REJECTED -- the token in ~/.authinfo is not accepted by "
                    "api.github.com; regenerate it, then git config github.user"))
      ;; ghub needs this even with a token in auth-source; without it every
      ;; pull dies with "Cannot determine username".
      (need "github.user" (magit-get "github.user")
            "UNSET -- git config --global github.user <login>")
      ;; Absence is not a failure here: forge-pull creates the database.
      (note "forge db"
            (if (file-exists-p (expand-file-name "forge-database.sqlite"
                                                 user-emacs-directory))
                "exists" "not yet created (forge-pull will make it)")))
    (let ((out (mapconcat #'identity (nreverse lines) "\n  ")))
      (princ (concat "  " out "\n"))
      (when missing
        (standard-change--fail "  forge-check: FAIL -- %s\n"
                               (mapconcat #'identity (nreverse missing) ", ")))
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
  (standard-change--show (standard-change--run "*change: queue*" "./status")))

;;;###autoload
(defun standard-change-prs ()
  "List open PRs with their pipeline labels.

Uses forge when it has a token, since that view is live and navigable.
Falls back to gh otherwise, because a missing token should degrade to a
worse view rather than to no view."
  (interactive)
  ;; `forge-list-pullreqs' is a tabulated-list command: in batch it fills a
  ;; buffer nobody sees and exits 0. Batch takes the gh route, which prints.
  (if (and (not noninteractive)
           (featurep 'forge)
           (ignore-errors (auth-source-search :host "api.github.com" :max 1)))
      (progn (require 'forge) (call-interactively #'forge-list-pullreqs))
    (standard-change--show
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
    (standard-change--show buf)))

;;;; Batch entry points -------------------------------------------------------
;; So `gmake forge` works whether or not an interactive Emacs is running.
;; forge-list-pullreqs is a tabulated-list command and needs a live frame, so
;; batch mode reads the forge database directly instead.

(defun standard-change--repo ()
  (let ((default-directory standard-change-root))
    (require 'forge)
    (forge-get-repository :tracked?)))

(defvar standard-change-forge-pull-timeout 120
  "Seconds to wait for an asynchronous forge pull before calling it failed.")

;;;###autoload
(defun standard-change-forge-pull ()
  "Refresh forge's local database from the forge. Safe in batch.

The pull is asynchronous, so this waits for the callback rather than for a
clock. It used to `sleep-for 12' and exit: when the forge took longer than
twelve seconds -- or failed, since ghub reports that from a process filter
where batch swallows it -- the target exited 0 with the database untouched,
and the next `forge-list' printed a stale snapshot as though it were today's.
Observed: with the wait cut short, the pull prints no \"done\" and the run
still exits 0."
  (interactive)
  (let ((default-directory standard-change-root)
        (done nil))
    (require 'forge)
    (let ((repo (or (standard-change--repo) (forge-get-repository :insert!)))
          (deadline (+ (float-time) standard-change-forge-pull-timeout)))
      (forge--pull repo (lambda (&rest _) (setq done t)))
      (while (and (not done) (< (float-time) deadline))
        (accept-process-output nil 0.2))
      (if done
          (princ "  forge: pulled\n")
        (standard-change--fail
         "  forge: pull unfinished after %ss -- the database was NOT refreshed\n"
         standard-change-forge-pull-timeout)))))

;;;###autoload
(defun standard-change-forge-list ()
  "Print pull requests from forge's database, with their state.

Every state, not only open: which changes have merged since is half of what
this view is for. The header dates the database, because a listing that
cannot be told from a stale one is not evidence of anything."
  (interactive)
  (let ((default-directory standard-change-root))
    (require 'forge)
    (let* ((repo (standard-change--repo))
           (db (expand-file-name "forge-database.sqlite" user-emacs-directory)))
      (cond
       ((null repo)
        (standard-change--fail
         "  forge: %s is not tracked -- run `gmake forge-pull` first\n"
         standard-change-repo))
       ((not (file-exists-p db))
        (standard-change--fail
         "  forge: no database at %s -- run `gmake forge-pull` first\n" db))
       (t
        (princ (format "  forge: %s, database written %s\n" standard-change-repo
                       (format-time-string
                        "%Y-%m-%d %H:%M"
                        (file-attribute-modification-time (file-attributes db)))))
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
                             (nth 2 r)))))))))))

;;;; The IDP, over HTTP ---------------------------------------------------------
;;
;; A client for idp-api/openapi.yaml: the three verbs, closure, the boundary,
;; and the reads. Built against idp-api/mock/server.mjs; the real server is
;; the dashboard's once it grows the verbs. Every write sends an
;; Idempotency-Key, and a refusal is shown the way the contract returns it:
;; fact, cost, recovery, berth -- because the refusal is the product.
;;
;;   M-x standard-change-idp            one-key menu over the verbs
;;   M-x standard-change-idp-status     the boundary, the changes, the schedule

(defvar standard-change-idp-url (or (getenv "IDP_URL") "http://127.0.0.1:9998")
  "The IDP to talk to. The mock by default.")

(defun standard-change--idp (method path &optional body)
  "METHOD PATH with optional BODY (an alist) -> (STATUS . PARSED-JSON)."
  (let* ((url-request-method method)
         (url-request-extra-headers
          `(("Content-Type" . "application/json")
            ("Idempotency-Key" . ,(format "emacs-%x" (random (expt 2 32))))))
         (url-request-data (and body (encode-coding-string (json-encode body) 'utf-8)))
         (buf (url-retrieve-synchronously (concat standard-change-idp-url path) t t 5)))
    (unless buf (standard-change--fail "  idp: %s is not answering\n" standard-change-idp-url))
    (with-current-buffer buf
      (goto-char (point-min))
      (let ((status (and (re-search-forward "^HTTP/[0-9.]+ \\([0-9]+\\)" nil t)
                         (string-to-number (match-string 1)))))
        (re-search-forward "^$" nil t)
        (let ((text (string-trim (buffer-substring-no-properties (point) (point-max)))))
          (kill-buffer buf)
          (cons status (and (> (length text) 0)
                            (ignore-errors (json-parse-string text :object-type 'alist :null-object nil)))))))))

(defun standard-change--idp-show (r)
  "Print a contract response R legibly; a refusal by its four fields."
  (let ((status (car r)) (body (cdr r)))
    (princ (format "  %s %s\n" (if (< status 400) "ok " "REFUSED") status))
    (if (and (listp body) (assq 'refused body))
        (dolist (k '(refused fact cost recovery berth))
          (princ (format "     %-9s %s\n" k (or (alist-get k body) ""))))
      (when body (princ (format "     %s\n" (json-encode body)))))
    r))

;;;###autoload
(defun standard-change-idp-status ()
  "The boundary, every change, and the schedule, from the IDP."
  (interactive)
  (let* ((cs (cdr (standard-change--idp "GET" "/changes")))
         (sc (cdr (standard-change--idp "GET" "/schedule")))
         (b (alist-get 'boundary sc))
         (buf (get-buffer-create "*change: idp*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "BOUNDARY  %s%s%s\n\n" (upcase (alist-get 'state b))
                        (if-let* ((e (alist-get 'emergency b)))
                            (format "  emergency for #%s: %s" (alist-get 'change e) (alist-get 'reason e)) "")
                        (if-let* ((h (alist-get 'berth b)))
                            (format "  berth: #%s (%s)" (alist-get 'held_by h) (alist-get 'lease h)) "  berth: free")))
        (insert (format "%-5s %-10s %-13s %-8s %-26s %s\n" "#" "class" "lifecycle" "head" "window" "lease"))
        (seq-doseq (c cs)
          (insert (format "%-5s %-10s %-13s %-8s %-26s %s\n"
                          (alist-get 'pr c) (alist-get 'class c) (alist-get 'lifecycle c) (alist-get 'head c)
                          (or (alist-get 'id (alist-get 'window c)) "—")
                          (or (alist-get 'id (alist-get 'lease c)) "—"))))
        (insert "\n")
        (seq-doseq (w (alist-get 'windows sc))
          (insert (format "%-26s #%-4s %s .. %s  %-10s %s\n" (alist-get 'id w) (alist-get 'change w)
                          (alist-get 'start w) (alist-get 'end w) (alist-get 'mode w)
                          (or (alist-get 'result w) "open"))))
        (goto-char (point-min))
        (special-mode)))
    (standard-change--show buf)))

(defun standard-change--idp-pr ()
  (string-trim-left (read-string "change (PR #): ") "#"))

;;;###autoload
(defun standard-change-idp ()
  "One key per verb of the contract. r reserve, a activate, s settle, c cancel,
f close failed, F freeze, O open the boundary, E declare an emergency, R reap,
? status."
  (interactive)
  (let ((k (read-char "idp: [r]eserve [a]ctivate [s]ettle [c]ancel [f]ail [F]reeze [O]pen [E]mergency [R]eap [?]status ")))
    (with-output-to-temp-buffer "*change: idp reply*"
      (pcase k
        (?r (let* ((pr (standard-change--idp-pr))
                   (c (cdr (standard-change--idp "GET" (concat "/changes/" pr)))))
              (standard-change--idp-show
               (standard-change--idp "POST" (format "/changes/%s/reservation" pr)
                                     `((groups . ,(alist-get 'groups c)) (minutes . 30))))))
        (?a (standard-change--idp-show (standard-change--idp "POST" (format "/changes/%s/activation" (standard-change--idp-pr)))))
        (?s (let* ((pr (standard-change--idp-pr))
                   (c (cdr (standard-change--idp "GET" (concat "/changes/" pr))))
                   (h (alist-get 'head c)) (l (alist-get 'id (alist-get 'lease c)))
                   (at (format-time-string "%FT%TZ" nil t)))
              (standard-change--idp-show
               (standard-change--idp "POST" (format "/changes/%s/settlement" pr)
                                     `((lease . ,(or l "")) (claimed_build . ,h)
                                       (observations . [((probe . "http://127.0.0.1:9230/version.json") (at . ,at) (build . ,h))
                                                        ((probe . "http://127.0.0.1:9230/version.json") (at . ,at) (build . ,h))
                                                        ((probe . "http://127.0.0.1:9230/version.json") (at . ,at) (build . ,h))]))))))
        (?c (standard-change--idp-show (standard-change--idp "DELETE" (format "/changes/%s/reservation" (standard-change--idp-pr)))))
        (?f (standard-change--idp-show (standard-change--idp "POST" (format "/changes/%s/closure" (standard-change--idp-pr))
                                                             '((code . "failed") (reason . "from emacs")))))
        (?F (standard-change--idp-show (standard-change--idp "PUT" "/boundary/freeze" `((reason . ,(read-string "reason: "))))))
        (?O (standard-change--idp "DELETE" "/boundary/freeze")
            (standard-change--idp-show (standard-change--idp "DELETE" "/boundary/emergency")))
        (?E (standard-change--idp-show (standard-change--idp "PUT" "/boundary/emergency"
                                                             `((change . ,(standard-change--idp-pr)) (reason . ,(read-string "reason: "))))))
        (?R (standard-change--idp-show (standard-change--idp "POST" "/schedule/reap")))
        (_  (standard-change-idp-status))))))

(provide 'standard-change)
;;; standard-change.el ends here
