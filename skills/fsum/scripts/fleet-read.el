;;; fleet-read.el --- Read-only bearings of one Fleet root and its lieutenants -*- lexical-binding: t; -*-

;;; Commentary:

;; The shared read helper behind the `/fsum' skill (and, by path or copy, `/frev').
;; It is loaded into the ALREADY-RUNNING Fleet owner Emacs through `emacsclient'
;; and only calls installed Fleet read functions against the ALREADY-OPEN store:
;;
;;   fleet-supervisor--store        the open handle, or nil
;;   fleet-core-fleet               selector resolution (id, root, root/child)
;;   fleet-store-get                one row by id
;;   fleet-store-lieutenants        existing child rows of a root
;;   fleet-store-snapshot           one fleet, enriched (commander, tasks, decisions ...)
;;   fleet-config-lieutenants       the owner's declared lieutenants of a root
;;   fleet-dashboard-task-projection / fleet-dashboard-commander-status  derived labels (optional)
;;
;; Constraints this file exists to keep:
;; - Fail closed.  A missing store is a limitation to report, never a reason to start the
;;   dashboard, open or migrate the database, or apply configuration.
;; - No mutation.  Nothing here sends, acknowledges, creates, starts, parks, or repairs.
;;   `fleet-core-ensure-lieutenants' is deliberately never called: declared-but-uncreated
;;   lieutenants are reported as such.
;; - Allowlist.  Full store rows carry credential hashes, drafts and raw JSON; only the
;;   fields below leave this function.
;; - Bounded.  One selected group read, one observation time, per-member failures named.
;;   Long free text is abbreviated; task identities never are.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

;; Installed Fleet functions (lisp/fleet-core.el, fleet-store.el, fleet-policy.el,
;; fleet-dashboard.el).  Declared, not required: this file never loads Fleet.
(declare-function fleet-core-fleet "fleet-core" (store ref))
(declare-function fleet-store-get "fleet-store" (store table id))
(declare-function fleet-store-lieutenants "fleet-store" (store fleet-id))
(declare-function fleet-store-snapshot "fleet-store" (store &optional fleet-id))
(declare-function fleet-config-lieutenants "fleet-policy" (fleet-name))
(declare-function fleet-dashboard-commander-status "fleet-dashboard" (fleet))
(declare-function fleet-dashboard-task-projection "fleet-dashboard" (task fleet))

(defconst fleet-read-schema 1 "Version of the evidence plist shape returned by `fleet-read-bearings'.")

(defconst fleet-read-detail-limit 600 "Free text longer than this many characters is abbreviated.")
(defconst fleet-read-detail-head 360 "Characters kept from the start of an abbreviated text.")
(defconst fleet-read-detail-tail 180
  "Characters kept from the end of an abbreviated text.
The end often carries the `sent since:' marker Fleet appends to a stale status.")

(define-error 'fleet-read-error "Fleet read error")

(defun fleet-read--fail (code message &rest evidence)
  "Signal `fleet-read-error' with stable CODE, MESSAGE and EVIDENCE plist."
  (signal 'fleet-read-error (list code message evidence)))

(defun fleet-read-error-code (err) "Stable code of `fleet-read-error' ERR." (nth 1 err))
(defun fleet-read-error-message (err) "Message of `fleet-read-error' ERR." (nth 2 err))
(defun fleet-read-error-evidence (err) "Evidence plist of `fleet-read-error' ERR." (nth 3 err))

(defun fleet-read-error-string (err)
  "Render ERR (a `fleet-read-error' or any error) for humans."
  (if (eq (car err) 'fleet-read-error)
      (format "%s: %s" (fleet-read-error-code err) (fleet-read-error-message err))
    (error-message-string err)))

;;;; Installed Fleet and the open store

(defconst fleet-read--required-functions
  '(fleet-core-fleet fleet-store-get fleet-store-lieutenants fleet-store-snapshot fleet-config-lieutenants)
  "Installed Fleet functions this reader calls.  All must be defined.")

(defun fleet-read--store ()
  "The store Fleet already has open in this Emacs, or fail closed."
  (let ((missing (cl-remove-if #'fboundp fleet-read--required-functions)))
    (when (or missing (not (boundp 'fleet-supervisor--store)))
      (fleet-read--fail 'fleet-not-loaded
                        "Fleet is not loaded in this Emacs; /fsum does not load or start it"
                        :missing missing)))
  (or (symbol-value 'fleet-supervisor--store)
      (fleet-read--fail 'store-not-open
                        "Fleet's store is not open in this Emacs; /fsum does not start the dashboard or open the store")))

;;;; Text helpers

(defun fleet-read-bound (text)
  "TEXT abbreviated to `fleet-read-detail-limit' characters, keeping head and tail.
Non-strings are returned as is."
  (if (and (stringp text) (> (length text) fleet-read-detail-limit))
      (concat (substring text 0 fleet-read-detail-head)
              " […abbreviated…] "
              (substring text (- (length text) fleet-read-detail-tail)))
    text))

(defun fleet-read--json (text)
  "Parse JSON column TEXT into a plist, or nil when empty or malformed."
  (when (and (stringp text) (not (string-empty-p text)))
    (ignore-errors
      (json-parse-string text :object-type 'plist :array-type 'list :null-object nil :false-object nil))))

(defun fleet-read--truthy (v) "Non-nil unless V is nil, 0 or :false." (not (or (null v) (eql v 0) (eq v :false))))

;;;; Root selection

(defun fleet-read--selector-row (store selector)
  "Fleet row for SELECTOR (id, root name or root/child), or nil.
Uses the installed resolver so selector semantics stay Fleet's own."
  (condition-case nil
      (fleet-core-fleet store selector)
    (error nil)))

(cl-defun fleet-read-resolve-root (store &key session-fleet-id selector)
  "The root fleet row `/fsum' observes.
SESSION-FLEET-ID is the fleet UUID from the caller's boot message; SELECTOR is
the optional explicit `/fsum FLEET' argument.  Rules: without either, fail;
a selector that resolves to a different fleet than the known session root is a
conflict, not a switch; lieutenants and archived fleets are refused."
  (when (and (null session-fleet-id) (null selector))
    (fleet-read--fail 'no-fleet-identity
                      "No fleet identity: pass the fleet id from your boot message, or an explicit selector"))
  (let ((session (and session-fleet-id (fleet-store-get store "fleets" session-fleet-id)))
        (selected (and selector (fleet-read--selector-row store selector))))
    (when (and session-fleet-id (null session))
      (fleet-read--fail 'no-such-fleet "The session's fleet id is not in the store" :ref session-fleet-id))
    (when (and selector (null selected))
      (fleet-read--fail 'no-such-fleet "No such fleet" :ref selector))
    (when (and session selected (not (equal (plist-get session :id) (plist-get selected :id))))
      (fleet-read--fail 'selector-conflict
                        (format "Selector `%s' names fleet %s but this session belongs to fleet %s; not switching"
                                selector (plist-get selected :name) (plist-get session :name))
                        :selector selector :selected (plist-get selected :id) :session (plist-get session :id)))
    (let ((root (or session selected)))
      (when (equal (plist-get root :lifecycle) "archived")
        (fleet-read--fail 'fleet-archived "That fleet is archived" :ref (plist-get root :id)))
      (when (plist-get root :parent-id)
        (fleet-read--fail 'not-a-root
                          (format "`%s' is a lieutenant; /fsum observes a root fleet" (plist-get root :name))
                          :ref (plist-get root :id) :parent (plist-get root :parent-id)))
      root)))

;;;; Projection (allowlisted)

(defun fleet-read--commander (rt)
  "Allowlisted view of a commander runtime row RT, or nil."
  (when rt
    (let ((q (fleet-read--json (plist-get rt :pending-question)))
          (approvals (fleet-read--json (plist-get rt :pending-approvals))))
      (list :runtime-id (plist-get rt :id)
            :lifecycle (plist-get rt :lifecycle)
            :turn-state (plist-get rt :turn-state)
            :connection-state (plist-get rt :connection-state)
            :model (plist-get rt :model)
            :last-activity-at (plist-get rt :last-activity-at)
            :pending-question (and q (fleet-read-bound (or (plist-get q :question) "")))
            :pending-approvals (length approvals)))))

(defun fleet-read--commander-label (fleet)
  "Dashboard's commander label for enriched FLEET, else the raw lifecycle."
  (cond
   ((fboundp 'fleet-dashboard-commander-status)
    (car (ignore-errors (fleet-dashboard-commander-status fleet))))
   ((plist-get fleet :commander) (plist-get (plist-get fleet :commander) :lifecycle))
   (t "none")))

(defun fleet-read--newer-instructions (task)
  "How many recent human/commander messages to TASK are newer than its status.
Recent means Fleet's last-three projection; the count qualifies an old status,
it does not resolve it."
  (let ((since (plist-get task :detail-at)))
    (if (not (stringp since))
        0
      (cl-count-if (lambda (m)
                     (and (member (plist-get m :origin) '("human" "commander"))
                          (stringp (plist-get m :created-at))
                          (string> (plist-get m :created-at) since)
                          (not (member (plist-get m :state) '("rejected" "cancelled-before-dispatch")))))
                   (plist-get task :messages-recent)))))

(defun fleet-read--task (task fleet)
  "Allowlisted view of enriched TASK row belonging to enriched FLEET."
  (let* ((rt (plist-get task :runtime))
         (tool (and rt (fleet-read--json (plist-get rt :active-tool))))
         (derived (and (fboundp 'fleet-dashboard-task-projection)
                       (ignore-errors (fleet-dashboard-task-projection task fleet)))))
    (list :id (plist-get task :id)
          :name (plist-get task :name)
          :kind (plist-get task :kind)
          :lifecycle (plist-get task :lifecycle)
          :phase (plist-get task :phase)
          :detail (fleet-read-bound (plist-get task :detail))
          :detail-at (plist-get task :detail-at)
          :delivery (plist-get task :delivery-mode)
          :branch (plist-get task :branch)
          :wait (and (plist-get task :wait-reason)
                     (list :reason (fleet-read-bound (plist-get task :wait-reason))
                           :deadline (plist-get task :wait-deadline)
                           :job-id (plist-get task :wait-job-id)))
          :runtime (and rt (list :lifecycle (plist-get rt :lifecycle)
                                 :turn-state (plist-get rt :turn-state)
                                 :pending-question (and (fleet-read--json (plist-get rt :pending-question)) t)
                                 :pending-approvals (length (fleet-read--json (plist-get rt :pending-approvals)))
                                 :active-tool (and tool (plist-get tool :name))))
          :decisions (mapcar (lambda (d) (list :id (plist-get d :id)
                                               :question (fleet-read-bound (plist-get d :question))
                                               :authority (plist-get d :authority)
                                               :state (plist-get d :state)
                                               :created-at (plist-get d :created-at)))
                             (plist-get task :decisions))
          :artifacts (mapcar (lambda (a) (list :kind (plist-get a :kind)
                                               :ref (or (plist-get a :external-ref) (plist-get a :rel-path))
                                               :external (and (plist-get a :external-ref) t)
                                               :verified (fleet-read--truthy (plist-get a :verified))))
                             (plist-get task :artifacts))
          :external-jobs (mapcar (lambda (j) (list :system (plist-get j :system) :state (plist-get j :state)
                                                   :ref (fleet-read-bound (plist-get j :job-ref))))
                                 (plist-get task :external-jobs))
          :failed-operations (mapcar (lambda (o) (plist-get o :kind))
                                     (cl-remove-if-not (lambda (o) (member (plist-get o :state) '("failed" "blocked")))
                                                       (plist-get task :operations)))
          :newer-instructions (fleet-read--newer-instructions task)
          :derived (and derived (list :state (symbol-name (nth 0 derived)) :source (nth 1 derived))))))

(defun fleet-read--request (r)
  "Allowlisted view of request row R."
  (list :id (plist-get r :id) :subject (fleet-read-bound (plist-get r :subject)) :state (plist-get r :state)
        :parent-fleet-id (plist-get r :parent-fleet-id) :child-fleet-id (plist-get r :child-fleet-id)
        :created-at (plist-get r :created-at)))

(defun fleet-read--member (store row role root-name configured)
  "Observe one existing fleet ROW (ROLE `root' or `lieutenant') under ROOT-NAME.
CONFIGURED is t, nil, or `unknown'.  A failed read yields a member whose
:status is `read-failed' and names the error; the row identity is kept."
  (let* ((id (plist-get row :id))
         (base (list :id id :name (plist-get row :name)
                     :selector (if (eq role 'root) root-name (format "%s/%s" root-name (plist-get row :name)))
                     :role (symbol-name role) :configured configured)))
    (condition-case err
        (let* ((snap (fleet-store-snapshot store id))
               (f (car (plist-get snap :fleets))))
          (unless f (fleet-read--fail 'no-such-fleet "Fleet row vanished during the read" :ref id))
          (append base
                  (list :status "observed"
                        :revision (plist-get snap :revision)
                        :lifecycle (plist-get f :lifecycle)
                        :supervision (fleet-read--truthy (plist-get f :supervision))
                        :charter (fleet-read-bound (plist-get f :charter))
                        :commander (fleet-read--commander (plist-get f :commander))
                        :commander-label (fleet-read--commander-label f)
                        :pending-events (or (plist-get f :pending-events) 0)
                        :queued-wakes (or (plist-get f :queued-wakes) 0)
                        :running-operations (length (plist-get f :running-operations))
                        :failed-operations (mapcar (lambda (o) (plist-get o :kind))
                                                   (cl-remove-if-not (lambda (o) (member (plist-get o :state) '("failed" "blocked")))
                                                                     (plist-get f :running-operations)))
                        :open-requests (mapcar #'fleet-read--request (plist-get f :open-requests))
                        :tasks (mapcar (lambda (task) (fleet-read--task task f)) (plist-get f :tasks)))))
      (error (append base (list :status "read-failed" :error (fleet-read-error-string err)))))))

(defun fleet-read--declared-member (name root-name)
  "Member entry for a lieutenant NAME the owner declared but Fleet has not created.
It has a declaration reference, not a fleet id or runtime."
  (list :id nil :name name :selector (format "%s/%s" root-name name) :role "lieutenant"
        :configured t :status "declared-not-created" :tasks nil :open-requests nil))

;;;; Entry point

(cl-defun fleet-read-bearings (&key session-fleet-id selector runtime-id)
  "One bounded, read-only observation of a root fleet and its lieutenants.
SESSION-FLEET-ID and SELECTOR choose the root (see `fleet-read-resolve-root');
RUNTIME-ID, when given, is compared with the root's current commander runtime.
Returns a plist: :schema :observed-at :revision :root (:id :name :artifact-root)
:caller :config :members :requests :diagnostics :counts.  Members are the root,
every existing lieutenant
(stopped or not) and every declared-but-uncreated lieutenant; each carries a
:status of observed, read-failed or declared-not-created."
  (let* ((store (fleet-read--store))
         (root (fleet-read-resolve-root store :session-fleet-id session-fleet-id :selector selector))
         (root-id (plist-get root :id)) (root-name (plist-get root :name))
         (diagnostics nil)
         (config (condition-case err
                     (list :status "ok"
                           :declared (mapcar (lambda (c) (plist-get c :name)) (fleet-config-lieutenants root-name)))
                   (error (push (format "Owner configuration unreadable; declared lieutenants unknown: %s"
                                        (error-message-string err))
                                diagnostics)
                          (list :status "error" :declared nil :error (error-message-string err)))))
         (existing (condition-case err
                       (fleet-store-lieutenants store root-id)
                     (error (push (format "Existing lieutenants could not be listed: %s" (error-message-string err)) diagnostics)
                            :failed)))
         (config-ok (equal (plist-get config :status) "ok"))
         (configured-p (lambda (name) (cond ((not config-ok) 'unknown)
                                            ((member name (plist-get config :declared)) t)
                                            (t nil))))
         (members (cons (fleet-read--member store root 'root root-name t)
                        (unless (eq existing :failed)
                          (mapcar (lambda (row) (fleet-read--member store row 'lieutenant root-name (funcall configured-p (plist-get row :name))))
                                  existing))))
         (existing-names (unless (eq existing :failed) (mapcar (lambda (r) (plist-get r :name)) existing)))
         (declared-only (and config-ok (not (eq existing :failed))
                             (cl-remove-if (lambda (n) (member n existing-names)) (plist-get config :declared)))))
    (setq members (append members (mapcar (lambda (n) (fleet-read--declared-member n root-name)) declared-only)))
    (dolist (m members)
      (when (equal (plist-get m :status) "read-failed")
        (push (format "%s: read failed (%s)" (plist-get m :selector) (plist-get m :error)) diagnostics)))
    (dolist (n declared-only)
      (push (format "%s/%s is declared in config but not created; it is applied when the root's commander starts" root-name n) diagnostics))
    (dolist (m members)
      (when (and (equal (plist-get m :role) "lieutenant") (null (plist-get m :configured)) config-ok)
        (push (format "%s exists but is no longer in config (Fleet never removes lieutenants)" (plist-get m :selector)) diagnostics)))
    (let* ((root-member (car members))
           (current (plist-get root :commander-runtime-id))
           (caller (list :runtime-id runtime-id
                         :current-commander-p (cond ((null runtime-id) 'unknown) ((equal runtime-id current) t) (t nil))))
           (requests (let ((seen (make-hash-table :test 'equal)) out)
                       (dolist (m members)
                         (dolist (r (plist-get m :open-requests))
                           (unless (gethash (plist-get r :id) seen)
                             (puthash (plist-get r :id) t seen)
                             (push r out))))
                       (nreverse out))))
      (when (and runtime-id (not (equal runtime-id current)))
        (push (format "Caller runtime %s is not the root's current commander runtime (replaced or stale session); read anyway" runtime-id)
              diagnostics))
      (list :schema fleet-read-schema
            :observed-at (format-time-string "%FT%T%z")
            :revision (plist-get root-member :revision)
            ;; :artifact-root is the root fleet's own directory path (no credential,
            ;; no free text); `fleet-result.el' needs it to find commander/runs.
            :root (list :id root-id :name root-name :artifact-root (plist-get root :artifact-root))
            :caller caller
            :config config
            :members members
            :requests requests
            :diagnostics (nreverse diagnostics)
            :counts (list :members-declared (length (plist-get config :declared))
                          :members-existing (if (eq existing :failed) nil (1+ (length existing)))
                          :members-observed (cl-count "observed" members :key (lambda (m) (plist-get m :status)) :test #'equal)
                          :tasks (apply #'+ (mapcar (lambda (m) (length (plist-get m :tasks))) members)))))))

(defun fleet-read--jsonable (v)
  "V with lists turned into vectors and nil into :null for `json-serialize'.
A list of plists would otherwise be mistaken for an alist (Fleet's store
encoder vectorizes for the same reason)."
  (cond ((null v) :null)
        ((eq v t) t)
        ((and (consp v) (keywordp (car v)))
         (cl-loop for (k val) on v by #'cddr append (list k (fleet-read--jsonable val))))
        ((consp v) (apply #'vector (mapcar #'fleet-read--jsonable v)))
        ((symbolp v) (symbol-name v))
        (t v)))

(defun fleet-read-bearings-json (&rest args)
  "`fleet-read-bearings' with ARGS, serialized as JSON text."
  (json-serialize (fleet-read--jsonable (apply #'fleet-read-bearings args))))

(provide 'fleet-read)
;;; fleet-read.el ends here
