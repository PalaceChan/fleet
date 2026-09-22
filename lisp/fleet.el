;;; fleet.el --- Emacs-native orchestration of ECA agents -*- lexical-binding: t; -*-

;; Author: Alejandro Velazquez
;; URL: https://github.com/PalaceChan/fleet
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools

;;; Commentary:

;; Public commands: `fleet-new', `fleet-dashboard', `fleet-park',
;; `fleet-task-close', `fleet-destroy', `fleet-doctor', `fleet-watch-start', `fleet-watch-stop',
;; `fleet-commander-stop', `fleet-commander-replace', `fleet-commander-set-model',
;; `fleet-install-mcp'.
;; Requiring this file launches nothing.  See quickstart.md.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'fleet-paths)
(require 'fleet-store)
(require 'fleet-policy)
(require 'fleet-core)
(require 'fleet-eca)
(require 'fleet-runtime)
(require 'fleet-supervisor)
(require 'fleet-rpc)
(require 'fleet-dashboard)
(require 'fleet-telemetry)

;;;; Startup

(defun fleet-dashboard-ensure-started (callback)
  "Start the supervisor (owner or read-only) if needed.
Then call CALLBACK with the mode plist."
  (fleet-supervisor-start
   (lambda (r)
     (when (eq (plist-get r :mode) 'owner)
       (condition-case err (fleet-rpc-start)
         (error (message "Fleet: RPC socket failed: %s" (error-message-string err)))))
     (funcall callback r))))

(defun fleet--store ()
  "Store or a friendly error."
  (condition-case err (fleet-supervisor-store)
    (fleet-error (user-error "%s" (fleet-error-string err)))))

(defun fleet--require-owner ()
  "Signal a user error unless this Emacs owns Fleet."
  (when (fleet-supervisor-read-only-p) (user-error "Read-only: another Emacs owns this Fleet data root"))
  (unless (fleet-supervisor-owner-p) (user-error "Fleet is not the owner here; run M-x fleet-dashboard first (or recover with fleet-doctor)")))

(defun fleet--fleet-names (&optional lifecycles roots-only)
  "Selectors of fleets in LIFECYCLES (default active+parked+parking).
Lieutenants appear as `root/child' after their root unless ROOTS-ONLY."
  (let ((store (fleet--store)))
    (cl-loop for root in (fleet-store-root-fleets store)
             when (member (plist-get root :lifecycle) (or lifecycles '("active" "parked" "parking")))
             collect (plist-get root :name)
             and unless roots-only
             append (cl-loop for lt in (fleet-store-lieutenants store (plist-get root :id))
                             when (member (plist-get lt :lifecycle) (or lifecycles '("active" "parked" "parking")))
                             collect (fleet-core-fleet-selector store lt)))))

(defun fleet--read-fleet (prompt &optional lifecycles roots-only)
  "Read an existing fleet selector with PROMPT; ROOTS-ONLY hides lieutenants."
  (let ((names (fleet--fleet-names lifecycles roots-only)))
    (unless names (user-error "No fleets%s" (if lifecycles (format " in state %s" lifecycles) "")))
    (completing-read prompt names nil t)))

;;;; Commands

;;;###autoload
(defun fleet-dashboard ()
  "Show the live Fleet dashboard, starting Fleet in this Emacs if needed."
  (interactive)
  (fleet-dashboard-ensure-started
   (lambda (r)
     (let ((buf (fleet-dashboard-buffer)))
       (with-current-buffer buf
         (unless (derived-mode-p 'fleet-dashboard-mode) (fleet-dashboard-mode))
         (fleet-dashboard-render))
       (pop-to-buffer buf)
       (pcase (plist-get r :mode)
         ('read-only (message "Fleet: read-only (owner: %s)" (or (plist-get r :reason) "another Emacs")))
         ('error (message "Fleet: %s" (plist-get r :error)))
         (_ nil))))))

;;;###autoload
(defun fleet-new (name)
  "Create fleet NAME, or resume/visit it when it exists.
NAME may be a `root/child' selector to visit or restart a lieutenant;
lieutenants themselves are declared in the owner's `config.json' and created
when their root's commander starts."
  (interactive
   (progn
     (unless fleet-supervisor--store (user-error "Run M-x fleet-dashboard first so Fleet can start"))
     (list (completing-read "Fleet: " (fleet--fleet-names) nil nil))))
  (fleet--require-owner)
  (let* ((store (fleet--store))
         (existing (condition-case nil (fleet-core-fleet store name) (fleet-error nil))))
    (cond
     ((null existing)
      (when (string-match-p "/" name)
        (user-error "No lieutenant %s; lieutenants are declared under fleets.<root>.lieutenants in %s and created when the root's commander starts" name (fleet-config-file)))
      (unless (fleet-paths-valid-name-p name) (user-error "Invalid fleet name %S (use [A-Za-z0-9][A-Za-z0-9._-]*)" name))
      (when (yes-or-no-p (format "Create new fleet %s and start its commander? " name))
        (fleet-eca-assert-supported)
        (let* ((choice (fleet--read-model-and-variant store "Commander"))
               (fleet (fleet-core-create-fleet store name :model (car choice) :variant (cdr choice))))
          (fleet--start-commander-and-show fleet nil))))
     ((member (plist-get existing :lifecycle) '("parked"))
      (fleet--resume-or-visit existing))
     ((member (plist-get existing :lifecycle) '("parking" "retiring"))
      (fleet-dashboard)
      (message "Fleet %s is %s; wait for it to settle (see dashboard)" name (plist-get existing :lifecycle)))
     (t
      (let* ((rt (and (plist-get existing :commander-runtime-id) (fleet-store-get store "runtimes" (plist-get existing :commander-runtime-id))))
             (conn (and rt (fleet-eca-conn (plist-get rt :id)))))
        (cond
         ((and conn (eq (fleet-eca-conn-state conn) 'ready))
          (fleet-dashboard)
          (fleet-eca-visit conn))
         ((and rt (not (member (plist-get rt :lifecycle) '("stopped" "never-launched"))))
          (fleet-dashboard)
          (message "Commander runtime %s is %s; use fleet-commander-stop / fleet-doctor before starting another" (fleet-paths-short-id (plist-get rt :id)) (plist-get rt :lifecycle)))
         ((yes-or-no-p (format "Fleet %s is active without a live commander; start one? " name))
          (fleet--pin-and-start-commander store existing (fleet--recovery-summary store existing)))))))))

(defun fleet--read-model-and-variant (store role &optional fleet)
  "Offer completion over the known ECA catalog for ROLE; return (MODEL . VARIANT).
Both nil means the configured/ECA default.  Skipped silently (nil . nil) when
no Fleet runtime has announced the catalog yet, so nothing has to be typed.
With FLEET (an existing fleet row) the default entry keeps that fleet's current
pin, and the result is what its next commander should be pinned to."
  (let* ((cat (fleet-store-eca-catalog store))
         (models (plist-get cat :models))
         (current (and fleet (fleet-core-commander-model fleet)))
         (default-label (format "%s (%s)" (if fleet "keep" "default")
                                (or (car current) fleet-commander-model (plist-get cat :default-model) "ECA default"))))
    (if (null models)
        (or current (cons nil nil))
      (let* ((model (completing-read (format "%s model: " role) (cons default-label models) nil t nil nil default-label))
             (keep (equal model default-label))
             (model (if keep (car current) model))
             (variants (plist-get cat :variants))
             (variant (completing-read (format "%s variant (empty = server default): " role)
                                       (or variants '("low" "medium" "high")) nil nil nil nil
                                       (if keep (or (cdr current) "") ""))))
        (cons model (unless (member variant '("" "-")) variant))))))

(defun fleet--pin-and-start-commander (store fleet recovery-summary)
  "Ask which model FLEET's next commander runs on, persist it, then start it.
The prompt is skipped when no catalog is known yet (nothing to choose from)."
  (let* ((choice (fleet--read-model-and-variant store "Commander" fleet))
         (fleet (if (equal choice (fleet-core-commander-model fleet))
                    fleet
                  (fleet-core-set-commander-model store (plist-get fleet :id) :model (car choice) :variant (cdr choice)))))
    (fleet--start-commander-and-show fleet recovery-summary)))

(defun fleet--resume-or-visit (fleet)
  "Explicit resume flow for a parked FLEET."
  (let* ((store (fleet--store))
         (tasks (fleet-store-tasks store (plist-get fleet :id)))
         (summary (format "%d suspended, %d done, %d failed, %d pending events"
                          (cl-count-if (lambda (task) (and (equal (plist-get task :lifecycle) "suspended") (not (member (plist-get task :phase) '("done" "failed"))))) tasks)
                          (cl-count-if (lambda (task) (equal (plist-get task :phase) "done")) tasks)
                          (cl-count-if (lambda (task) (equal (plist-get task :phase) "failed")) tasks)
                          (fleet-store-scalar store "SELECT COUNT(*) FROM event_receipts WHERE fleet_id = ? AND state IN ('pending','needs-reconciliation')" (plist-get fleet :id))))
         (choice (completing-read (format "Fleet %s is parked (%s). " (plist-get fleet :name) summary)
                                  '("resume: mark active; commander may start unfinished tasks" "visit only: open commander/dashboard, stay parked") nil t)))
    (fleet-dashboard)
    (when (string-prefix-p "resume" choice)
      (dolist (id (fleet-core-resume-fleet store (plist-get fleet :id)))
        (fleet-supervisor-kick id 'resume)))
    (let* ((fleet (fleet-store-get store "fleets" (plist-get fleet :id)))
           (rt (and (plist-get fleet :commander-runtime-id) (fleet-store-get store "runtimes" (plist-get fleet :commander-runtime-id))))
           (conn (and rt (fleet-eca-conn (plist-get rt :id)))))
      (cond
       ((and conn (eq (fleet-eca-conn-state conn) 'ready)) (fleet-eca-visit conn)
        (when (string-prefix-p "resume" choice)
          (fleet-supervisor-send store :fleet-id (plist-get fleet :id) :runtime-id (plist-get rt :id) :sender "fleet"
                                 :text (concat "The user resumed this fleet. " (fleet--recovery-summary store fleet)))))
       ((and rt (not (member (plist-get rt :lifecycle) '("stopped" "never-launched"))))
        (message "Retained commander %s is %s; stop it (fleet-commander-stop) before starting a new one" (fleet-paths-short-id (plist-get rt :id)) (plist-get rt :lifecycle)))
       (t (fleet--pin-and-start-commander store fleet (fleet--recovery-summary store fleet)))))))

(defalias 'fleet--recovery-summary #'fleet-core-recovery-summary)

(defun fleet--start-commander-and-show (fleet recovery-summary)
  "Start FLEET's commander with RECOVERY-SUMMARY, then show chat and dashboard.
For a root fleet, the owner's configured lieutenants are applied and any
lieutenant without a live commander is started alongside (docs/lieutenants.md §5)."
  (let* ((store (fleet--store)) (fid (plist-get fleet :id))
         (name (fleet-core-fleet-selector store fleet)))
    (unless (plist-get fleet :parent-id) (fleet--start-lieutenants store fleet))
    (message "Fleet: starting %s for %s…" (if (plist-get fleet :parent-id) "lieutenant" "commander") name)
    (fleet-core-start-commander
     store fid :recovery-summary recovery-summary
     :callback (lambda (op)
                 (if (equal (plist-get op :state) "done")
                     (let* ((f (fleet-store-get store "fleets" fid))
                            (conn (fleet-eca-conn (plist-get f :commander-runtime-id))))
                       (fleet-dashboard)
                       (when conn (fleet-eca-visit conn))
                       (if-let* ((over (fleet-core-context-oversize-bytes (plist-get f :artifact-root))))
                           (message "Fleet %s: commander ready — commander/context.md is %d bytes (over %d) and is loaded at every boot; the commander was asked to index it and move detail to commander/context/ and history to commander/archive/"
                                    name over fleet-core-context-warn-bytes)
                         (message "Fleet %s: commander ready" name)))
                   (fleet-dashboard)
                   (message "Fleet %s: commander start failed: %s (see fleet-doctor)" name (plist-get op :error)))))))

(defun fleet--start-lieutenants (store root)
  "Apply configured lieutenants of ROOT and start those without a live commander.
A malformed `fleets' section is reported and leaves existing lieutenants as
they are; the root still starts.  Parked lieutenants are not started."
  (condition-case err
      (let ((r (fleet-core-ensure-lieutenants store (plist-get root :id))))
        (when (plist-get r :created)
          (message "Fleet %s: created lieutenant(s) %s" (plist-get root :name)
                   (mapconcat (lambda (f) (plist-get f :name)) (plist-get r :created) ", ")))
        (when (plist-get r :unconfigured)
          (message "Fleet %s: lieutenant(s) %s are no longer in %s; kept as they are (retire with fleet-destroy)"
                   (plist-get root :name) (mapconcat (lambda (f) (plist-get f :name)) (plist-get r :unconfigured) ", ") (fleet-config-file))))
    (fleet-error (message "Fleet %s: lieutenants not applied — %s" (plist-get root :name) (fleet-error-string err))))
  (dolist (lt (fleet-core-lieutenants store (plist-get root :id)))
    (let* ((rt (and (plist-get lt :commander-runtime-id) (fleet-store-get store "runtimes" (plist-get lt :commander-runtime-id))))
           (sel (fleet-core-fleet-selector store lt)))
      (when (and (equal (plist-get lt :lifecycle) "active")
                 (or (null rt) (member (plist-get rt :lifecycle) '("stopped" "never-launched"))))
        (condition-case err
            (fleet-core-start-commander
             store (plist-get lt :id) :recovery-summary (fleet--recovery-summary store lt)
             :callback (lambda (op)
                         (fleet-supervisor--changed (plist-get lt :id))
                         (message "Lieutenant %s: %s" sel (if (equal (plist-get op :state) "done") "ready" (format "start failed: %s" (plist-get op :error))))))
          (fleet-error (message "Lieutenant %s not started — %s" sel (fleet-error-string err))))))))

;;;###autoload
(defun fleet-park (name)
  "Park fleet NAME: stop operators, retain commanders and all durable work.
NAME is a root; its lieutenants are parked with it.  A lieutenant selector
parks its root (there is no per-lieutenant park)."
  (interactive (list (fleet--read-fleet "Park fleet: " '("active" "parking") t)))
  (fleet--require-owner)
  (let* ((store (fleet--store))
         (fleet (fleet-core-root-fleet store (fleet-core-fleet store name)))
         (name (plist-get fleet :name))
         (fid (plist-get fleet :id))
         (ids (cons fid (mapcar (lambda (c) (plist-get c :id)) (fleet-core-lieutenants store fid))))
         (in (format "(%s)" (string-join (make-list (length ids) "?") ",")))
         (count (lambda (sql) (apply #'fleet-store-scalar store (format sql in) ids)))
         (live (funcall count "SELECT COUNT(*) FROM runtimes WHERE fleet_id IN %s AND role = 'operator' AND lifecycle IN ('launching','starting','ready')"))
         (tools (funcall count "SELECT COUNT(*) FROM runtimes WHERE fleet_id IN %s AND role = 'operator' AND lifecycle = 'ready' AND active_tool IS NOT NULL"))
         (jobs (funcall count "SELECT COUNT(*) FROM external_jobs WHERE fleet_id IN %s AND state IN ('running','unknown')")))
    (when (yes-or-no-p (format "Park %s%s? %d live operator(s), %d running tool(s), %d declared external job(s) left running. "
                               name (if (cdr ids) (format " and its %d lieutenant(s)" (1- (length ids))) "") live tools jobs))
      (fleet-core-park-fleet store fid
                             :callback (lambda (op)
                                         (fleet-supervisor--changed fid)
                                         (if (equal (plist-get op :state) "done")
                                             (message "Fleet %s parked%s" name (if (> jobs 0) (format "; %d external job(s) may still be running" jobs) ""))
                                           (message "Fleet %s still parking: %s (see dashboard/doctor)" name (plist-get op :error)))))
      (fleet-supervisor--changed fid)
      (message "Fleet %s parking…" name))))

;;;###autoload
(defun fleet-destroy (name)
  "Retire empty fleet NAME: archive its artifact tree and release the name."
  (interactive (list (fleet--read-fleet "Retire (destroy) empty fleet: " '("active" "parked"))))
  (fleet--require-owner)
  (let* ((store (fleet--store)) (fleet (fleet-core-fleet store name)))
    (when (yes-or-no-p (format "Retire fleet %s? Artifacts move to %s and the name is released. Nothing is deleted. "
                               name (fleet-paths-fleet-archive-dir (plist-get fleet :id))))
      (condition-case err
          (fleet-core-retire-fleet store (plist-get fleet :id)
                                   :callback (lambda (op)
                                               (fleet-supervisor--changed)
                                               (message "Fleet %s: %s%s" name (plist-get op :state) (if (plist-get op :error) (format " — %s" (plist-get op :error)) ""))))
        (fleet-error (user-error "Destroy refused — %s" (fleet-error-string err)))))))

(defun fleet--read-closable-task (store fleet)
  "Read one of FLEET's tasks that `fleet-core-close-task' could admit."
  (let* ((tasks (cl-remove-if
                 (lambda (task)
                   (let* ((rt-id (plist-get task :current-runtime-id))
                          (rt (and rt-id (fleet-store-get store "runtimes" rt-id))))
                     (or (member (plist-get task :lifecycle) '("draft" "closing"))
                         (and rt (not (member (plist-get rt :lifecycle) '("stopped" "never-launched")))))))
                 (fleet-store-tasks store (plist-get fleet :id))))
         (labels (mapcar (lambda (task)
                           (cons (format "%s  (%s, %s/%s)" (plist-get task :name) (plist-get task :kind)
                                         (plist-get task :lifecycle) (or (plist-get task :phase) "none"))
                                 task))
                         tasks)))
    (unless labels (user-error "Fleet %s has no task with a stopped operator to close" (plist-get fleet :name)))
    (cdr (assoc (completing-read "Close task: " labels nil t) labels))))

;;;###autoload
(defun fleet-task-close (name)
  "Close a task of fleet NAME on your authority: archive it without teardown.
For failed or abandoned work, or done work whose deliverables can no longer be
verified.  Nothing is stopped or deleted: the operator must already be
stopped and a change task's worktree must already be gone."
  (interactive (list (fleet--read-fleet "Close a task in fleet: ")))
  (fleet--require-owner)
  (let* ((store (fleet--store))
         (fleet (fleet-core-fleet store name))
         (task (fleet--read-closable-task store fleet))
         (reason (string-trim (read-string (format "Reason for closing %s: " (plist-get task :name))))))
    (when (string-empty-p reason) (user-error "A reason is required"))
    (when (yes-or-no-p (format "Close %s (%s/%s) without teardown? Files, branch and history stay; the task is archived. "
                               (plist-get task :name) (plist-get task :lifecycle) (or (plist-get task :phase) "none")))
      (condition-case err
          (progn
            (fleet-core-close-task store (plist-get task :id) :reason reason :expected-revision (plist-get task :entity-revision))
            (fleet-supervisor--changed (plist-get fleet :id))
            (message "Fleet %s: task %s closed and archived" name (plist-get task :name)))
        (fleet-error (user-error "Close refused — %s" (fleet-error-string err)))))))

;;;###autoload
(defun fleet--fleet-and-lieutenants (store fleet)
  "FLEET row followed by its lieutenant rows (none for a lieutenant)."
  (cons fleet (fleet-core-lieutenants store (plist-get fleet :id))))

;;;###autoload
(defun fleet-watch-start (name)
  "Enable automatic event dispatch for fleet NAME (and its lieutenants).
Replay pending events under admission."
  (interactive (list (fleet--read-fleet "Enable supervision for: ")))
  (fleet--require-owner)
  (let ((store (fleet--store)))
    (dolist (f (fleet--fleet-and-lieutenants store (fleet-core-fleet store name)))
      (fleet-core-set-supervision store (plist-get f :id) t)
      (fleet-supervisor-kick (plist-get f :id) 'human))
    (message "Fleet %s: supervision on" name)))

;;;###autoload
(defun fleet-watch-stop (name)
  "Pause automatic model dispatch for fleet NAME (and its lieutenants).
Runtimes and observation continue."
  (interactive (list (fleet--read-fleet "Pause supervision for: ")))
  (fleet--require-owner)
  (let ((store (fleet--store)))
    (dolist (f (fleet--fleet-and-lieutenants store (fleet-core-fleet store name)))
      (fleet-core-set-supervision store (plist-get f :id) nil))
    (message "Fleet %s: supervision paused (events are retained)" name)))

;;;###autoload
(defun fleet-commander-stop (name)
  "Stop fleet NAME's commander with verified service evidence.
Operators are untouched."
  (interactive (list (fleet--read-fleet "Stop commander of: ")))
  (fleet--require-owner)
  (let* ((store (fleet--store)) (fleet (fleet-core-fleet store name))
         (rt (and (plist-get fleet :commander-runtime-id) (fleet-store-get store "runtimes" (plist-get fleet :commander-runtime-id)))))
    (unless rt (user-error "Fleet %s has no commander runtime" name))
    (when (or (member (plist-get rt :turn-state) '("idle" nil))
              (yes-or-no-p (format "Commander is %s; stop anyway? " (plist-get rt :turn-state))))
      (fleet-core-stop-commander store (plist-get fleet :id)
                                 :callback (lambda (r)
                                             (fleet-supervisor--changed (plist-get fleet :id))
                                             (message "Commander of %s: %s" name (plist-get r :verdict))))
      (message "Stopping commander of %s…" name))))

;;;###autoload
(defun fleet-commander-set-model (name)
  "Pin the model/variant fleet NAME's next commander launches with.
A live commander is untouched; use `fleet-commander-replace' to switch now."
  (interactive (list (fleet--read-fleet "Set commander model of: ")))
  (fleet--require-owner)
  (let* ((store (fleet--store)) (fleet (fleet-core-fleet store name)))
    (unless (plist-get (fleet-store-eca-catalog store) :models)
      (user-error "No ECA model catalog known yet; start any Fleet runtime once, then retry"))
    (let* ((choice (fleet--read-model-and-variant store "Commander" fleet))
           (fleet (fleet-core-set-commander-model store (plist-get fleet :id) :model (car choice) :variant (cdr choice))))
      (fleet-supervisor--changed (plist-get fleet :id))
      (message "Fleet %s: next commander runs on %s%s" name
               (or (car (fleet-core-commander-model fleet)) "the ECA default")
               (if (cdr (fleet-core-commander-model fleet)) (format "/%s" (cdr (fleet-core-commander-model fleet))) "")))))

;;;###autoload
(defun fleet-commander-replace (name)
  "Stop fleet NAME's commander (verified), then start a fresh one.
The new commander receives the handoff context."
  (interactive (list (fleet--read-fleet "Replace commander of: ")))
  (fleet--require-owner)
  (let* ((store (fleet--store)) (fleet (fleet-core-fleet store name)) (fid (plist-get fleet :id))
         (old (plist-get fleet :commander-runtime-id))
         (rt (and old (fleet-store-get store "runtimes" old))))
    (cl-flet ((start ()
                (when old (fleet-supervisor-on-commander-replaced store fid old))
                (fleet--pin-and-start-commander store (fleet-store-get store "fleets" fid) (fleet--recovery-summary store fleet))))
      (if (and rt (not (member (plist-get rt :lifecycle) '("stopped" "never-launched"))))
          (when (yes-or-no-p (format "Stop commander %s (%s) and start a replacement? " (fleet-paths-short-id old) (or (plist-get rt :turn-state) (plist-get rt :lifecycle))))
            (fleet-core-stop-commander store fid
                                       :callback (lambda (r)
                                                   (if (equal (plist-get r :lifecycle) "stopped")
                                                       (start)
                                                     (message "Replacement refused: predecessor stop verdict %s" (plist-get r :verdict))))))
        (start)))))

;;;; MCP configuration (one entry, merged with backup and diff)

(defun fleet-mcp-entry ()
  "The single Fleet MCP server entry for ECA's config."
  (list :command fleet-python-executable
        :args (vector (fleet-paths-bridge-executable) "mcp")
        :env (list :FLEET_SOCKET "${env:FLEET_SOCKET:}" :FLEET_CREDENTIAL_FILE "${env:FLEET_CREDENTIAL_FILE:}")))

(defun fleet--json-pretty (value)
  "Pretty JSON for VALUE."
  (with-temp-buffer
    (insert (fleet-store-json value))
    (json-pretty-print-buffer)
    (buffer-string)))

;;;###autoload
(defun fleet-install-mcp ()
  "Merge the Fleet MCP entry into ECA's global config.
Takes a backup and shows a visible diff.
Never touches other providers/servers/rules and never enables trust."
  (interactive)
  (let* ((file (expand-file-name "config.json" (fleet-paths-eca-config-root)))
         (current (or (and (file-exists-p file) (fleet-store-unjson (fleet-paths-read-file file))) '()))
         (servers (or (plist-get current :mcpServers) '()))
         (new-servers (plist-put (copy-sequence servers) :fleet (fleet-mcp-entry)))
         (updated (plist-put (copy-sequence current) :mcpServers new-servers))
         (old-text (or (fleet-paths-read-file file) ""))
         (new-text (fleet--json-pretty updated)))
    (if (equal (plist-get servers :fleet) (fleet-mcp-entry))
        (message "Fleet MCP entry already present in %s" file)
      (let ((a (make-temp-file "eca-config-old")) (b (make-temp-file "eca-config-new")))
        (with-temp-file a (insert old-text))
        (with-temp-file b (insert new-text))
        (let ((diff-buf (get-buffer-create "*fleet-mcp-diff*")))
          (with-current-buffer diff-buf
            (let ((inhibit-read-only t))
              (erase-buffer)
              (call-process "diff" nil t nil "-u" a b)
              (goto-char (point-min))
              (diff-mode)))
          (display-buffer diff-buf))
        (when (yes-or-no-p (format "Apply this change to %s (backup kept alongside)? " file))
          (when (file-exists-p file)
            (copy-file file (format "%s.fleet-backup-%s" file (format-time-string "%Y%m%dT%H%M%S")) t))
          (fleet-paths-write-atomically file new-text)
          (message "Installed Fleet MCP entry; restart ECA sessions to pick it up"))))))

;;;; Doctor

;;;###autoload
(defun fleet-doctor ()
  "Read-only compatibility, ownership, storage, runtime and worktree checks.
Each check reports its evidence."
  (interactive)
  (let ((buf (get-buffer-create "*fleet-doctor*"))
        (probe (fleet-eca-probe)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "# fleet-doctor\n\n")
        (fleet--doctor-line "Emacs" (format "%s, sqlite %s" emacs-version (if (sqlite-available-p) "available" "MISSING (required)")) (sqlite-available-p))
        (fleet--doctor-line "Python" (format "%s %s" fleet-python-executable (if (file-executable-p fleet-python-executable) (string-trim (shell-command-to-string (format "%s --version" fleet-python-executable))) "MISSING")) (file-executable-p fleet-python-executable))
        (fleet--doctor-line "systemd" (if (executable-find fleet-runtime-systemd-run) (string-trim (car (split-string (shell-command-to-string "systemctl --user --version") "\n"))) "systemd-run MISSING") (executable-find fleet-runtime-systemd-run))
        (fleet--doctor-line "git" (string-trim (shell-command-to-string "git --version")) (executable-find "git"))
        (fleet--doctor-line "ECA" (format "client %s / server %s%s" (or (plist-get probe :client) "?") (or (plist-get probe :server) "?")
                                         (if (plist-get probe :supported) "" (format " — %s" (string-join (plist-get probe :reasons) "; "))))
                            (plist-get probe :supported))
        (fleet--doctor-line "ECA command" (format "%S" (plist-get probe :command)) (plist-get probe :command))
        (fleet--doctor-line "Runtime root" (condition-case err (fleet-paths-runtime-root) (fleet-error (fleet-error-string err))) (ignore-errors (fleet-paths-runtime-root)))
        (fleet--doctor-line "Data root" (fleet-paths-data-root) t)
        (fleet--doctor-line "Worktree root" (fleet-paths-worktree-root) t)
        (let* ((desc-file (fleet-paths-owner-descriptor))
               (desc (and (file-exists-p desc-file) (ignore-errors (fleet-store-unjson (fleet-paths-read-file desc-file))))))
          (fleet--doctor-line "Owner" (cond ((fleet-supervisor-owner-p) (format "this Emacs (pid %d, epoch %s)" (emacs-pid) (plist-get fleet-core-owner :epoch)))
                                            ((fleet-supervisor-read-only-p) "another Emacs (read-only here)")
                                            ((and desc (fleet-supervisor--previous-owner-alive-p desc)) (format "pid %s appears alive and unreleased" (plist-get desc :emacsPid)))
                                            (desc (format "stale descriptor (pid %s, released %s)" (plist-get desc :emacsPid) (plist-get desc :released)))
                                            (t "none"))
                              (or (fleet-supervisor-owner-p) (fleet-supervisor-read-only-p))))
        ;; Owner configuration: which file is read, and whether each section parses.
        (let* ((cfg (fleet-config-file))
               (models (condition-case err (progn (fleet-policy-load) "models ok") (fleet-error (fleet-error-string err))))
               (fleets (condition-case err (format "%d fleet(s) with %d lieutenant(s) declared"
                                                   (length (fleet-config-fleets))
                                                   (apply #'+ (mapcar (lambda (f) (length (plist-get f :lieutenants))) (fleet-config-fleets))))
                         (fleet-error (fleet-error-string err)))))
          (fleet--doctor-line "Owner config"
                              (if (file-exists-p cfg)
                                  (format "%s — %s; %s" cfg models fleets)
                                (format "none (%s absent; no model policy, no lieutenants)" cfg))
                              (if (file-exists-p cfg) (and (equal models "models ok") (not (string-match-p "invalid" fleets))) 'info)))
        (let* ((cfg (expand-file-name "config.json" (fleet-paths-eca-config-root)))
               (json (and (file-exists-p cfg) (ignore-errors (fleet-store-unjson (fleet-paths-read-file cfg)))))
               (entry (plist-get (plist-get json :mcpServers) :fleet)))
          ;; Fleet injects its MCP server per runtime through ECA_CONFIG, so a
          ;; global entry is optional; only a stale one is worth flagging.
          (fleet--doctor-line "MCP entry" (cond ((null json) (format "%s unreadable" cfg))
                                                ((null entry) "not in global config (per-runtime ECA_CONFIG overlay in use; fleet-install-mcp is optional)")
                                                ((equal entry (fleet-mcp-entry)) "present and current")
                                                (t "present but differs — M-x fleet-install-mcp shows the diff"))
                              (if (and json entry) (equal entry (fleet-mcp-entry)) 'info))
          (when (eq t (plist-get (plist-get json :chat) :defaultTrust))
            (insert "  note: chat.defaultTrust=true — operators and commanders auto-approve tool calls (ECA otherwise asks for paths outside workspace roots)\n"))
          (when (equal (plist-get (plist-get (plist-get json :toolCall) :approval) :byDefault) "allow")
            (insert "  note: toolCall.approval.byDefault=allow — full autonomous shell access is your explicit choice\n")))
        (when fleet-supervisor--store
          (let* ((store fleet-supervisor--store)
                 (running (fleet-store-query store "SELECT * FROM operations WHERE state = 'running' ORDER BY updated_at DESC"))
                 (failed (fleet-core-open-failed-operations store))
                 (all-failed (fleet-store-scalar store "SELECT COUNT(*) FROM operations WHERE state = 'failed'")))
            (insert (format "\n## Store\nschema %d, snapshot revision %d, %d fleet(s), %d running operation(s), %d failed operation(s)%s\n"
                            (fleet-store--current-version store) (fleet-store-snapshot-revision store)
                            (fleet-store-scalar store "SELECT COUNT(*) FROM fleets WHERE lifecycle <> 'archived'")
                            (length running) (length failed)
                            ;; A retried teardown or a destroyed fleet leaves its failure in the
                            ;; journal; say how many are history rather than raising them again.
                            (if (> all-failed (length failed)) (format " (%d superseded, kept in history)" (- all-failed (length failed))) "")))
            (dolist (op (seq-take (append running failed) 20))
              (insert (format "  op %s %s step=%s state=%s%s\n" (fleet-paths-short-id (plist-get op :id)) (plist-get op :kind) (plist-get op :step) (plist-get op :state)
                              (if (plist-get op :error) (format " error=%s" (plist-get op :error)) ""))))
            (insert "\n## Runtimes (nonterminal; units inspected asynchronously)\n")
            (let ((rows (fleet-store-query store "SELECT * FROM runtimes WHERE lifecycle NOT IN ('stopped','never-launched')")))
              (if (null rows) (insert "  none\n")
                (dolist (rt rows)
                  (insert (format "  %s %s %s lifecycle=%s turn=%s unit=%s\n" (fleet-paths-short-id (plist-get rt :id)) (plist-get rt :role)
                                  (or (plist-get rt :task-id) "") (plist-get rt :lifecycle) (or (plist-get rt :turn-state) "-") (plist-get rt :unit)))
                  (fleet--doctor-inspect-unit rt (point-marker)))))
            (insert "\n## Recovery actions (explicit)\n- fleet-commander-replace: fresh commander with handoff context\n- fleet-park: verified stop of operators\n")))
        (goto-char (point-min))
        (special-mode)))
    (pop-to-buffer buf)))

(defun fleet--doctor-inspect-unit (rt pos)
  "Asynchronously append systemd evidence for runtime RT at marker POS."
  (fleet-runtime-inspect
   (plist-get rt :unit) (plist-get rt :control-group)
   (lambda (insp)
     (when (buffer-live-p (marker-buffer pos))
       (with-current-buffer (marker-buffer pos)
         (let ((inhibit-read-only t))
           (save-excursion
             (goto-char pos)
             (insert (format "      systemd: %s verdict=%s\n"
                             (if (plist-get insp :query-ok)
                                 (format "%s/%s cgroup=%s" (plist-get insp :load-state) (plist-get insp :active-state) (plist-get insp :cgroup-populated))
                               (format "query failed: %s" (plist-get insp :error)))
                             (fleet-runtime-verdict 'created (plist-get rt :boot-id) insp))))))))))

(defun fleet--doctor-line (label text ok)
  "Insert a doctor line for LABEL with TEXT, marked by OK.
OK is t (pass), nil (fail) or `info' (neither; informational)."
  (insert (format "%s %-14s %s\n" (pcase ok ('info "○") ('nil "✗") (_ "✓")) label text)))

(provide 'fleet)
;;; fleet.el ends here
