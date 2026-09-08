;;; fleet.el --- Emacs-native orchestration of ECA agents -*- lexical-binding: t; -*-

;; Author: Alejandro Velazquez
;; URL: https://github.com/PalaceChan/fleet
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools

;;; Commentary:

;; Public commands: `fleet-new', `fleet-dashboard', `fleet-park',
;; `fleet-destroy', `fleet-doctor', `fleet-watch-start', `fleet-watch-stop',
;; `fleet-commander-stop', `fleet-commander-replace', `fleet-install-mcp'.
;; Requiring this file launches nothing.  See quickstart.md.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'fleet-paths)
(require 'fleet-store)
(require 'fleet-core)
(require 'fleet-eca)
(require 'fleet-runtime)
(require 'fleet-supervisor)
(require 'fleet-rpc)
(require 'fleet-dashboard)

;;;; Startup

(defun fleet-dashboard-ensure-started (callback)
  "Start the supervisor (owner or read-only) if needed, then call CALLBACK with the mode plist."
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

(defun fleet--fleet-names (&optional lifecycles)
  "Names of fleets in LIFECYCLES (default active+parked+parking)."
  (mapcar (lambda (f) (plist-get f :name))
          (cl-remove-if-not (lambda (f) (member (plist-get f :lifecycle) (or lifecycles '("active" "parked" "parking"))))
                            (fleet-store-fleets (fleet--store)))))

(defun fleet--read-fleet (prompt &optional lifecycles)
  "Read an existing fleet name with PROMPT."
  (let ((names (fleet--fleet-names lifecycles)))
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
  "Create fleet NAME, or resume/visit it when it exists."
  (interactive
   (progn
     (unless fleet-supervisor--store (user-error "Run M-x fleet-dashboard first so Fleet can start"))
     (list (completing-read "Fleet: " (fleet--fleet-names) nil nil))))
  (fleet--require-owner)
  (let* ((store (fleet--store))
         (existing (fleet-store-fleet-by-name store name)))
    (cond
     ((null existing)
      (unless (fleet-paths-valid-name-p name) (user-error "Invalid fleet name %S (use [A-Za-z0-9][A-Za-z0-9._-]*)" name))
      (when (yes-or-no-p (format "Create new fleet %s and start its commander? " name))
        (fleet-eca-assert-supported)
        (let ((fleet (fleet-core-create-fleet store name)))
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
          (fleet--start-commander-and-show existing (fleet--recovery-summary store existing)))))))))

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
      (fleet-core-resume-fleet store (plist-get fleet :id))
      (fleet-supervisor-kick (plist-get fleet :id) 'resume))
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
       (t (fleet--start-commander-and-show fleet (fleet--recovery-summary store fleet)))))))

(defun fleet--recovery-summary (store fleet)
  "Deterministic recovery summary text for FLEET."
  (let ((tasks (fleet-store-tasks store (plist-get fleet :id))))
    (concat (format "Fleet `%s` is %s. Tasks:\n" (plist-get fleet :name) (plist-get fleet :lifecycle))
            (mapconcat (lambda (task)
                         (format "- `%s` (%s): lifecycle %s, phase %s, brief rev %d — %s" (plist-get task :name) (plist-get task :kind)
                                 (plist-get task :lifecycle) (or (plist-get task :phase) "none") (plist-get task :brief-revision) (or (plist-get task :detail) "")))
                       tasks "\n")
            (format "\nDone tasks are verified/finalized, not rerun. Unfinished suspended tasks may be started again under their existing scope with fleet_task_start once the fleet is active. Held messages: %d. Read commander/context.md for the previous handoff."
                    (fleet-store-scalar store "SELECT COUNT(*) FROM messages WHERE fleet_id = ? AND state = 'held'" (plist-get fleet :id))))))

(defun fleet--start-commander-and-show (fleet recovery-summary)
  "Start FLEET's commander with RECOVERY-SUMMARY, then show chat and dashboard."
  (let ((store (fleet--store)) (fid (plist-get fleet :id)))
    (message "Fleet: starting commander for %s…" (plist-get fleet :name))
    (fleet-core-start-commander
     store fid :recovery-summary recovery-summary
     :callback (lambda (op)
                 (if (equal (plist-get op :state) "done")
                     (let* ((f (fleet-store-get store "fleets" fid))
                            (conn (fleet-eca-conn (plist-get f :commander-runtime-id))))
                       (fleet-dashboard)
                       (when conn (fleet-eca-visit conn))
                       (message "Fleet %s: commander ready" (plist-get fleet :name)))
                   (fleet-dashboard)
                   (message "Fleet %s: commander start failed: %s (see fleet-doctor)" (plist-get fleet :name) (plist-get op :error)))))))

;;;###autoload
(defun fleet-park (name)
  "Park fleet NAME: stop operators, retain commander and all durable work."
  (interactive (list (fleet--read-fleet "Park fleet: " '("active" "parking"))))
  (fleet--require-owner)
  (let* ((store (fleet--store))
         (fleet (fleet-core-fleet store name))
         (fid (plist-get fleet :id))
         (live (fleet-store-scalar store "SELECT COUNT(*) FROM runtimes WHERE fleet_id = ? AND role = 'operator' AND lifecycle IN ('launching','starting','ready')" fid))
         (tools (fleet-store-scalar store "SELECT COUNT(*) FROM runtimes WHERE fleet_id = ? AND role = 'operator' AND lifecycle = 'ready' AND active_tool IS NOT NULL" fid))
         (jobs (fleet-store-scalar store "SELECT COUNT(*) FROM external_jobs WHERE fleet_id = ? AND state IN ('running','unknown')" fid)))
    (when (yes-or-no-p (format "Park %s? %d live operator(s), %d running tool(s), %d declared external job(s) left running. " name live tools jobs))
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

;;;###autoload
(defun fleet-watch-start (name)
  "Enable automatic event dispatch for fleet NAME and replay pending events under admission."
  (interactive (list (fleet--read-fleet "Enable supervision for: ")))
  (fleet--require-owner)
  (let* ((store (fleet--store)) (fleet (fleet-core-fleet store name)))
    (fleet-core-set-supervision store (plist-get fleet :id) t)
    (fleet-supervisor-kick (plist-get fleet :id) 'human)
    (message "Fleet %s: supervision on" name)))

;;;###autoload
(defun fleet-watch-stop (name)
  "Pause automatic model dispatch for fleet NAME.  Runtimes and observation continue."
  (interactive (list (fleet--read-fleet "Pause supervision for: ")))
  (fleet--require-owner)
  (let* ((store (fleet--store)) (fleet (fleet-core-fleet store name)))
    (fleet-core-set-supervision store (plist-get fleet :id) nil)
    (message "Fleet %s: supervision paused (events are retained)" name)))

;;;###autoload
(defun fleet-commander-stop (name)
  "Stop fleet NAME's commander with verified service evidence; operators are untouched."
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
(defun fleet-commander-replace (name)
  "Stop fleet NAME's commander (verified), then start a fresh one with the handoff context."
  (interactive (list (fleet--read-fleet "Replace commander of: ")))
  (fleet--require-owner)
  (let* ((store (fleet--store)) (fleet (fleet-core-fleet store name)) (fid (plist-get fleet :id))
         (old (plist-get fleet :commander-runtime-id))
         (rt (and old (fleet-store-get store "runtimes" old))))
    (cl-flet ((start ()
                (when old (fleet-supervisor-on-commander-replaced store fid old))
                (fleet--start-commander-and-show (fleet-store-get store "fleets" fid) (fleet--recovery-summary store fleet))))
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
  "Merge the Fleet MCP entry into ECA's global config with a backup and visible diff.
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
  "Read-only compatibility, ownership, storage, runtime and worktree checks with evidence."
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
        (fleet--doctor-line "ECA pair" (format "client %s / server %s — %s" (plist-get probe :client) (plist-get probe :server)
                                              (if (plist-get probe :supported) "verified" (format "UNSUPPORTED: %s" (string-join (plist-get probe :reasons) "; "))))
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
        (let* ((cfg (expand-file-name "config.json" (fleet-paths-eca-config-root)))
               (json (and (file-exists-p cfg) (ignore-errors (fleet-store-unjson (fleet-paths-read-file cfg)))))
               (entry (plist-get (plist-get json :mcpServers) :fleet)))
          (fleet--doctor-line "MCP entry" (cond ((null json) (format "%s unreadable" cfg))
                                                ((null entry) "absent — M-x fleet-install-mcp")
                                                ((equal entry (fleet-mcp-entry)) "present and current")
                                                (t "present but differs — M-x fleet-install-mcp shows the diff"))
                              (equal entry (fleet-mcp-entry)))
          (when (equal (plist-get (plist-get (plist-get json :toolCall) :approval) :byDefault) "allow")
            (insert "  note: toolCall.approval.byDefault=allow — full autonomous shell access is your explicit choice\n")))
        (when fleet-supervisor--store
          (let ((store fleet-supervisor--store))
            (insert (format "\n## Store\nschema %d, snapshot revision %d, %d fleet(s), %d running operation(s), %d failed operation(s)\n"
                            (fleet-store--current-version store) (fleet-store-snapshot-revision store)
                            (fleet-store-scalar store "SELECT COUNT(*) FROM fleets WHERE lifecycle <> 'archived'")
                            (fleet-store-scalar store "SELECT COUNT(*) FROM operations WHERE state = 'running'")
                            (fleet-store-scalar store "SELECT COUNT(*) FROM operations WHERE state = 'failed'")))
            (dolist (op (fleet-store-query store "SELECT * FROM operations WHERE state IN ('running','failed') ORDER BY updated_at DESC LIMIT 20"))
              (insert (format "  op %s %s step=%s state=%s%s\n" (fleet-paths-short-id (plist-get op :id)) (plist-get op :kind) (plist-get op :step) (plist-get op :state)
                              (if (plist-get op :error) (format " error=%s" (plist-get op :error)) ""))))
            (insert "\n## Runtimes (nonterminal; units inspected asynchronously)\n")
            (let ((rows (fleet-store-query store "SELECT * FROM runtimes WHERE lifecycle NOT IN ('stopped','never-launched')")))
              (if (null rows) (insert "  none\n")
                (dolist (rt rows)
                  (insert (format "  %s %s %s lifecycle=%s turn=%s unit=%s\n" (fleet-paths-short-id (plist-get rt :id)) (plist-get rt :role)
                                  (or (plist-get rt :task-id) "") (plist-get rt :lifecycle) (or (plist-get rt :turn-state) "-") (plist-get rt :unit)))
                  (fleet--doctor-inspect-unit rt (point-marker)))))
            (insert "\n## Recovery actions (explicit)\n- fleet-commander-replace: fresh commander with handoff context\n- fleet-park: verified stop of operators\n- fleet-install-mcp: merge the MCP entry with backup\n")))
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
  "Insert a doctor line for LABEL with TEXT, marked by OK."
  (insert (format "%s %-14s %s\n" (if ok "✓" "✗") label text)))

(provide 'fleet)
;;; fleet.el ends here
