;;; fleet-rpc.el --- Local socket protocol and actor authorization -*- lexical-binding: t; -*-

;;; Commentary:

;; Serves schema/rpc-v1.json on a Unix-domain socket (mode 0600 in a 0700
;; directory).  Filters only parse, validate and dispatch; every operation
;; maps to the same fleet-core/fleet-supervisor function the dashboard uses,
;; so tools cannot skip a safety check.  Authority derives from the runtime
;; credential; task/fleet ids in parameters never grant it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'fleet-paths)
(require 'fleet-store)
(require 'fleet-core)
(require 'fleet-supervisor)
(require 'fleet-git)

(defconst fleet-rpc-protocol-version 1)
(defconst fleet-rpc-max-line-bytes (* 1024 1024))
(defconst fleet-rpc-max-page 200)

(defvar fleet-rpc--server nil "Listening process, or nil.")
(defvar fleet-rpc--tools nil "Parsed schema/tools-v1.json.")
(defvar fleet-rpc-request-log nil
  "Recent (OPERATION . ACTOR-ROLE) requests, newest first, bounded.
Diagnostics only.")

;;;; Tool schema

(defun fleet-rpc-tools ()
  "Tool definitions from schema/tools-v1.json (cached)."
  (or fleet-rpc--tools
      (setq fleet-rpc--tools
            (append (plist-get (fleet-store-unjson (fleet-paths-read-file (fleet-paths-schema-file "tools-v1.json"))) :tools) nil))))

(defun fleet-rpc-tools-for-role (role)
  "Tool definitions visible to ROLE."
  (cl-remove-if-not (lambda (tool) (member role (append (plist-get tool :roles) nil))) (fleet-rpc-tools)))

;;;; Server lifecycle

(defun fleet-rpc-start ()
  "Start the control socket server (idempotent).  Requires an open owner store."
  (unless (and fleet-rpc--server (process-live-p fleet-rpc--server))
    (let* ((dir (fleet-paths-ensure-dir (fleet-paths-runtime-root) #o700))
           (path (fleet-paths-socket)))
      (fleet-paths-ensure-dir (fleet-paths-credentials-dir) #o700)
      (when (file-exists-p path) (delete-file path))
      (setq fleet-rpc--server
            (make-network-process :name "fleet-rpc" :server t :family 'local :service path :noquery t
                                  :coding 'utf-8-unix
                                  :filter #'fleet-rpc--filter
                                  :sentinel (lambda (_p _e) nil)
                                  :plist (list :dir dir)))
      (set-file-modes path #o600)
      fleet-rpc--server)))

(defun fleet-rpc-stop ()
  "Stop the control socket server."
  (when fleet-rpc--server
    (ignore-errors (delete-process fleet-rpc--server))
    (setq fleet-rpc--server nil)
    (ignore-errors (delete-file (fleet-paths-socket)))))

;;;; Framing

(defun fleet-rpc--filter (conn chunk)
  "Accumulate CHUNK for CONN and handle complete lines."
  (let ((buf (concat (or (process-get conn :buf) "") chunk)))
    (if (> (string-bytes buf) fleet-rpc-max-line-bytes)
        (progn (fleet-rpc--reply conn nil (fleet-rpc--error 'invalid-request "request exceeds size limit" nil))
               (process-put conn :buf "")
               (delete-process conn))
      (let ((lines (split-string buf "\n")))
        (process-put conn :buf (car (last lines)))
        (dolist (line (butlast lines))
          (unless (string-blank-p line)
            (fleet-rpc--handle-line conn line)))))))

(defun fleet-rpc--reply (conn id payload)
  "Send PAYLOAD (plist with :result or :error) for request ID on CONN."
  (when (process-live-p conn)
    (process-send-string conn (concat (fleet-store-json (append (list :id id) payload)) "\n"))))

(defun fleet-rpc--error (code message evidence &optional retryable)
  "Build an error payload."
  (list :error (list :code (format "%s" code) :message message :evidence evidence :retryable (if retryable t :false))))

(defun fleet-rpc--handle-line (conn line)
  "Parse and dispatch one request LINE on CONN."
  (let ((req (condition-case nil (fleet-store-unjson line) (error nil))))
    (cond
     ((not (and req (listp req)))
      (fleet-rpc--reply conn nil (fleet-rpc--error 'invalid-request "malformed JSON" nil)))
     ((not (eql (plist-get req :protocolVersion) fleet-rpc-protocol-version))
      (fleet-rpc--reply conn (plist-get req :id) (fleet-rpc--error 'invalid-request "unsupported protocolVersion" (list :expected fleet-rpc-protocol-version))))
     ((not (stringp (plist-get req :operation)))
      (fleet-rpc--reply conn (plist-get req :id) (fleet-rpc--error 'invalid-request "operation must be a string" nil)))
     (t
      (fleet-rpc--reply conn (plist-get req :id)
                        (condition-case err
                            (list :result (fleet-rpc-dispatch (plist-get req :operation) (plist-get req :credential)
                                                              (plist-get req :idempotencyKey) (or (plist-get req :params) '())))
                          (fleet-error (fleet-rpc--error (fleet-error-code err) (fleet-error-message err) (fleet-error-evidence err)
                                                         (memq (fleet-error-code err) '(operation-in-progress unavailable))))
                          (error (fleet-rpc--error 'internal (error-message-string err) nil))))))))

;;;; Authentication

(defun fleet-rpc-authenticate (store token)
  "Actor plist for credential TOKEN, or signal `unauthenticated'/`stale-runtime'."
  (unless (stringp token) (fleet-fail 'unauthenticated "credential required"))
  (let ((rt (fleet-store-query1 store "SELECT * FROM runtimes WHERE credential_hash = ?" (fleet-paths-sha256-string token))))
    (unless rt (fleet-fail 'unauthenticated "unknown credential"))
    (fleet-core-runtime-authorized store (plist-get rt :id))
    (list :role (plist-get rt :role) :runtime-id (plist-get rt :id) :fleet-id (plist-get rt :fleet-id) :task-id (plist-get rt :task-id)
          :logical (if (equal (plist-get rt :role) "commander")
                       (fleet-core-actor-commander (plist-get rt :fleet-id))
                     (fleet-core-actor-operator (plist-get rt :task-id))))))

;;;; Dispatch

(defun fleet-rpc-dispatch (operation credential idempotency-key params)
  "Run OPERATION for CREDENTIAL with IDEMPOTENCY-KEY and PARAMS.
Return a result plist."
  (let ((store (fleet-supervisor-store)))
    (pcase operation
      ("ping" (list :ok t :owner (and (fleet-supervisor-owner-p) t)))
      ("tools_list"
       (let ((actor (fleet-rpc-authenticate store credential)))
         (push (cons "tools_list" (plist-get actor :role)) fleet-rpc-request-log)
         (list :tools (vconcat (mapcar (lambda (tool) (list :name (plist-get tool :name) :description (plist-get tool :description) :inputSchema (plist-get tool :inputSchema)))
                                       (fleet-rpc-tools-for-role (plist-get actor :role)))))))
      (_
       (let* ((tool (cl-find-if (lambda (tool) (equal (plist-get tool :name) operation)) (fleet-rpc-tools))))
         (unless tool (fleet-fail 'unknown-operation "No such operation" :operation operation))
         (let ((actor (fleet-rpc-authenticate store credential)))
           (push (cons operation (plist-get actor :role)) fleet-rpc-request-log)
           (when (> (length fleet-rpc-request-log) 200) (setcdr (nthcdr 199 fleet-rpc-request-log) nil))
           (unless (member (plist-get actor :role) (append (plist-get tool :roles) nil))
             (fleet-fail 'forbidden "Operation not available to this role" :role (plist-get actor :role) :operation operation))
           (unless (fleet-supervisor-owner-p) (fleet-fail 'owner-unproven "Fleet owner lease not live"))
           ;; The key may travel in the envelope (bridge) or in the arguments (model); they are one fact.
           (let* ((key (or idempotency-key (plist-get params :idempotency_key)))
                  (params (if (and key (not (plist-member params :idempotency_key)))
                              (append (list :idempotency_key key) params)
                            params)))
             (when (and idempotency-key (plist-get params :idempotency_key)
                        (not (equal idempotency-key (plist-get params :idempotency_key))))
               (fleet-fail 'invalid-request "idempotency key differs between envelope and arguments"))
             (fleet-rpc--validate params tool)
             (fleet-rpc--run store actor operation key params))))))))

(defun fleet-rpc--validate (params tool)
  "Minimal structural validation of PARAMS against TOOL's inputSchema.
Checks required keys, types and enums."
  (let* ((schema (plist-get tool :inputSchema))
         (props (plist-get schema :properties)))
    (dolist (req (append (plist-get schema :required) nil))
      (unless (plist-member params (intern (concat ":" req)))
        (fleet-fail 'invalid-request (format "missing required parameter %s" req) :operation (plist-get tool :name))))
    (cl-loop for (k v) on params by #'cddr
             for prop = (plist-get props k)
             do (cond
                 ((null prop)
                  (when (eq (plist-get schema :additionalProperties) :false)
                    (fleet-fail 'invalid-request (format "unexpected parameter %s" k))))
                 ((and (plist-get prop :enum) (not (member v (append (plist-get prop :enum) nil))))
                  (fleet-fail 'invalid-request (format "parameter %s must be one of %s" k (append (plist-get prop :enum) nil))))
                 ((and (equal (plist-get prop :type) "string") v (not (stringp v)))
                  (fleet-fail 'invalid-request (format "parameter %s must be a string" k)))
                 ((and (equal (plist-get prop :type) "integer") v (not (integerp v)))
                  (fleet-fail 'invalid-request (format "parameter %s must be an integer" k)))
                 ((and (equal (plist-get prop :type) "array") v (not (vectorp v)))
                  (fleet-fail 'invalid-request (format "parameter %s must be an array" k)))))))

(defun fleet-rpc--task-in-fleet (store actor task-id)
  "Task row TASK-ID if it belongs to ACTOR's fleet, else signal `forbidden'."
  (let ((task (fleet-store-get store "tasks" task-id)))
    (unless (and task (equal (plist-get task :fleet-id) (plist-get actor :fleet-id)))
      (fleet-fail 'forbidden "Task is not in your fleet" :task-id task-id))
    task))

(defun fleet-rpc--lst (v) "Vector V as list." (append v nil))

(defun fleet-rpc--run (store actor operation key params)
  "Execute OPERATION for authenticated ACTOR."
  (let ((fid (plist-get actor :fleet-id)) (logical (plist-get actor :logical)))
    (cl-flet ((mutation (payload thunk)
                (unless key (fleet-fail 'invalid-request "idempotencyKey (idempotency_key) required for mutations"))
                (fleet-store-with-action store logical key payload (funcall thunk))))
      (pcase operation
        ("fleet_snapshot"
         (if (equal (plist-get actor :role) "operator")
             (let ((task (fleet-store-get store "tasks" (plist-get actor :task-id))))
               (list :revision (fleet-store-snapshot-revision store)
                     :task (fleet-core--compact-task (fleet-store--task-projection store task))))
           (let ((snap (fleet-store-snapshot store fid)))
             (when-let* ((tid (plist-get params :task_id)))
               (fleet-rpc--task-in-fleet store actor tid)
               (setq snap (list :revision (plist-get snap :revision)
                                :fleets (list (plist-put (copy-sequence (car (plist-get snap :fleets))) :tasks
                                                         (cl-remove-if-not (lambda (task) (equal (plist-get task :id) tid)) (plist-get (car (plist-get snap :fleets)) :tasks)))))))
             (fleet-core--compact-snapshot snap))))
        ("fleet_task_create"
         (mutation params
                   (lambda ()
                     (let ((task (fleet-core-create-task store fid
                                                         :name (plist-get params :name) :kind (plist-get params :kind) :brief (plist-get params :brief)
                                                         :repo (plist-get params :repo) :base-ref (plist-get params :base_ref) :branch (plist-get params :branch)
                                                         :delivery (plist-get params :delivery)
                                                         :workspace-mode (intern (or (plist-get params :workspace_mode) "new"))
                                                         :adopt-path (plist-get params :adopt_path)
                                                         :dependencies (fleet-rpc--lst (plist-get params :dependencies))
                                                         :resources (fleet-rpc--lst (plist-get params :resources))
                                                         :context-paths (fleet-rpc--lst (plist-get params :context_paths))
                                                         :model (plist-get params :model) :actor logical)))
                       (fleet-supervisor--changed fid)
                       (list :task-id (plist-get task :id) :name (plist-get task :name) :lifecycle (plist-get task :lifecycle)
                             :brief-revision (plist-get task :brief-revision) :entity-revision (plist-get task :entity-revision))))))
        ("fleet_task_start"
         (fleet-rpc--task-in-fleet store actor (plist-get params :task_id))
         (unless key (fleet-fail 'invalid-request "idempotency_key required"))
         (prog1 (fleet-core-start-task store (plist-get params :task_id) :expected-revision (plist-get params :expected_revision) :actor logical :action-id key)
           (fleet-supervisor--changed fid)))
        ("fleet_task_retask"
         (fleet-rpc--task-in-fleet store actor (plist-get params :task_id))
         (mutation params (lambda ()
                            (let ((task (fleet-core-retask store (plist-get params :task_id) (plist-get params :brief) :expected-revision (plist-get params :expected_revision)
                                                           :note (plist-get params :note) :actor logical)))
                              (fleet-supervisor--changed fid)
                              (list :task-id (plist-get task :id) :brief-revision (plist-get task :brief-revision) :lifecycle (plist-get task :lifecycle))))))
        ("fleet_message_send"
         (let ((task (fleet-rpc--task-in-fleet store actor (plist-get params :task_id))))
           (unless key (fleet-fail 'invalid-request "idempotency_key required"))
           (unless (plist-get task :current-runtime-id) (fleet-fail 'runtime-not-ready "Task has no runtime"))
           (fleet-supervisor-send store :fleet-id fid :task-id (plist-get task :id) :runtime-id (plist-get task :current-runtime-id)
                                  :text (plist-get params :text) :sender logical :idempotency-key key)))
        ("fleet_status"
         (fleet-core-task-status store :runtime-id (plist-get actor :runtime-id) :phase (plist-get params :phase) :detail (plist-get params :detail)
                                 :decision (fleet-rpc--decision (plist-get params :decision))
                                 :wait (let ((w (plist-get params :wait))) (and w (list :reason (plist-get w :reason) :deadline (plist-get w :deadline) :job-id (plist-get w :job_id))))
                                 :artifacts (mapcar #'fleet-rpc--artifact (fleet-rpc--lst (plist-get params :artifacts)))))
        ("fleet_wait"
         (fleet-core-task-status store :runtime-id (plist-get actor :runtime-id) :phase "paused"
                                 :detail (format "waiting: %s" (plist-get params :reason))
                                 :wait (list :reason (plist-get params :reason) :deadline (plist-get params :deadline) :job-id (plist-get params :job_id))))
        ("fleet_artifact_register"
         (mutation params (lambda ()
                            (when (and (equal (plist-get actor :role) "commander") (plist-get params :task_id))
                              (fleet-rpc--task-in-fleet store actor (plist-get params :task_id)))
                            (fleet-core-artifact-register store :runtime-id (plist-get actor :runtime-id)
                                                          :task-id (if (equal (plist-get actor :role) "commander") (plist-get params :task_id) (plist-get actor :task-id))
                                                          :kind (plist-get params :kind) :rel-path (plist-get params :rel_path) :external-ref (plist-get params :external_ref)
                                                          :description (plist-get params :description) :expected-identity (plist-get params :expected_identity)))))
        ("fleet_artifact_verify"
         (mutation params (lambda ()
                            (let ((art (fleet-store-get store "artifacts" (plist-get params :artifact_id))))
                              (unless art (fleet-fail 'no-such-artifact "Unknown artifact"))
                              (fleet-rpc--task-in-fleet store actor (plist-get art :task-id))
                              (prog1 (fleet-core-artifact-verify store :artifact-id (plist-get params :artifact_id) :actor logical
                                                                 :criteria (plist-get params :criteria) :evidence (plist-get params :evidence)
                                                                 :accepted (eq t (plist-get params :accepted)) :limitations (plist-get params :limitations))
                                (fleet-supervisor--changed fid))))))
        ("fleet_decision_resolve"
         (mutation params (lambda ()
                            (let ((d (fleet-store-get store "decisions" (plist-get params :decision_id))))
                              (unless (and d (equal (plist-get d :fleet-id) fid)) (fleet-fail 'forbidden "Decision is not in your fleet"))
                              (prog1 (fleet-core-decision-resolve store :decision-id (plist-get params :decision_id) :answer (plist-get params :answer)
                                                                  :actor logical :authority "commander" :expected-revision (plist-get params :expected_revision)
                                                                  :evidence (and (plist-get params :evidence) (list :text (plist-get params :evidence))))
                                (fleet-supervisor--changed fid))))))
        ("fleet_external_job"
         (mutation params (lambda ()
                            (fleet-core-external-job store :runtime-id (plist-get actor :runtime-id) :job-id (plist-get params :job_id) :system (plist-get params :system)
                                                     :job-ref (plist-get params :job_ref) :state (plist-get params :state) :completion-source (plist-get params :completion_source)
                                                     :deadline (plist-get params :deadline) :cancel-policy (plist-get params :cancel_policy) :disposition (plist-get params :disposition)))))
        ("fleet_events_pending"
         (fleet-supervisor-pending-for-commander store fid (min (or (plist-get params :limit) 100) fleet-rpc-max-page)))
        ("fleet_events_ack"
         (mutation params (lambda ()
                            (fleet-supervisor-ack store :fleet-id fid :receipt-ids (fleet-rpc--lst (plist-get params :event_ids))
                                                  :outcome (plist-get params :disposition) :actor logical))))
        ("fleet_cleanup_evidence"
         (let ((task (fleet-rpc--task-in-fleet store actor (plist-get params :task_id))))
           (unless (and (equal (plist-get task :kind) "change") (plist-get task :workspace-path))
             (fleet-fail 'invalid-request "Only change tasks with a workspace have cleanup evidence"))
           (fleet-rpc--sync-evidence task)))
        ("fleet_task_teardown"
         (fleet-rpc--task-in-fleet store actor (plist-get params :task_id))
         (unless key (fleet-fail 'invalid-request "idempotency_key required"))
         (prog1 (fleet-core-teardown-task store (plist-get params :task_id) :expected-revision (plist-get params :expected_revision) :actor logical :action-id key)
           (fleet-supervisor--changed fid)))
        ("fleet_operation"
         (let ((op (fleet-store-get store "operations" (plist-get params :operation_id))))
           (unless (and op (equal (plist-get op :fleet-id) fid)) (fleet-fail 'forbidden "Operation is not in your fleet"))
           (list :operation-id (plist-get op :id) :kind (plist-get op :kind) :state (plist-get op :state) :step (plist-get op :step)
                 :error (plist-get op :error) :evidence (fleet-store-unjson (plist-get op :evidence)) :updated-at (plist-get op :updated-at))))
        (_ (fleet-fail 'unknown-operation "No such operation" :operation operation))))))

(defun fleet-rpc--decision (d)
  "Convert JSON decision object D to core keywords."
  (and d (list :question (plist-get d :question) :options (fleet-rpc--lst (plist-get d :options))
               :recommendation (plist-get d :recommendation) :authority (plist-get d :authority))))

(defun fleet-rpc--artifact (a)
  "Convert JSON artifact object A to core keywords."
  (list :kind (plist-get a :kind) :rel-path (plist-get a :rel_path) :external-ref (plist-get a :external_ref)
        :description (plist-get a :description) :expected-identity (plist-get a :expected_identity)))

(defun fleet-rpc--sync-evidence (task)
  "Collect Git evidence for TASK, waiting briefly for the asynchronous pass.
Bounded by `fleet-git-remote-timeout-sec'; the filter itself never blocks on Git
because this runs from the request handler after parsing."
  (let ((result nil))
    (fleet-git-collect-evidence :workspace (plist-get task :workspace-path) :repo (plist-get task :repo-path) :branch (plist-get task :branch)
                                :remote (plist-get task :remote) :target (plist-get task :target-ref) :base-oid (plist-get task :base-oid)
                                :task-id (plist-get task :id) :callback (lambda (ev) (setq result ev)))
    (let ((deadline (+ (float-time) fleet-git-remote-timeout-sec 5)))
      (while (and (not result) (< (float-time) deadline)) (accept-process-output nil 0.05)))
    (unless result (fleet-fail 'unavailable "Git evidence did not complete in time" :timeout t))
    (append (fleet-core--evidence-summary result)
            (list :decision (fleet-git-removal-decision :ev result :workspace-ownership (plist-get task :workspace-ownership)
                                                        :branch-ownership (plist-get task :branch-ownership)
                                                        :delivery-mode (plist-get task :delivery-mode)
                                                        :verified (fleet-core-task-verified-p (fleet-supervisor-store) task))))))

(defun fleet-core--compact-task (task)
  "Model-facing view of an enriched TASK plist."
  (list :id (plist-get task :id) :name (plist-get task :name) :kind (plist-get task :kind) :lifecycle (plist-get task :lifecycle)
        :phase (plist-get task :phase) :detail (plist-get task :detail) :brief-revision (plist-get task :brief-revision)
        :entity-revision (plist-get task :entity-revision) :workspace (plist-get task :workspace-path) :branch (plist-get task :branch)
        :delivery (plist-get task :delivery-mode)
        :open-decisions (mapcar (lambda (d) (list :id (plist-get d :id) :question (plist-get d :question) :state (plist-get d :state))) (plist-get task :decisions))
        :artifacts (mapcar (lambda (a) (list :id (plist-get a :id) :kind (plist-get a :kind) :path (plist-get a :rel-path) :verified (plist-get a :verified))) (plist-get task :artifacts))
        :external-jobs (mapcar (lambda (j) (list :id (plist-get j :id) :system (plist-get j :system) :state (plist-get j :state))) (plist-get task :external-jobs))))

(provide 'fleet-rpc)
;;; fleet-rpc.el ends here
