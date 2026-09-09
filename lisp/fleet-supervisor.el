;;; fleet-supervisor.el --- Owner lease, event routing, message lane, wakes -*- lexical-binding: t; -*-

;;; Commentary:

;; The single supervisor of a data root.  Owns:
;;  - the kernel-held lease (a tiny Python helper holds flock; its death
;;    fences every later admission) and the owner descriptor;
;;  - normalized adapter events -> durable runtime observations and
;;    actionable events with receipts;
;;  - the per-runtime message lane (one in-flight prompt per chat; human
;;    messages before automatic wakes; never a blind resend);
;;  - zero-token supervision: one wake message per claimed receipt batch,
;;    dispatched only when the §9.2 admission rule holds; one bounded
;;    reminder per batch, then hold for a human.
;;
;; Nothing here polls a model.  Timers only expire declared waits.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'fleet-paths)
(require 'fleet-store)
(require 'fleet-eca)
(require 'fleet-core)

;;;; State

(defvar fleet-supervisor--store nil "Open store, or nil.")
(defvar fleet-supervisor--lease nil "Lease helper process while we own the root.")
(defvar fleet-supervisor--descriptor nil "Published owner descriptor plist.")
(defvar fleet-supervisor--fenced nil "Non-nil once the lease was lost or released.")
(defvar fleet-supervisor--read-only nil "Non-nil when another Emacs owns the root.")
(defvar fleet-supervisor--wait-timer nil)
(defvar fleet-supervisor--kick-timers (make-hash-table :test 'equal) "fleet-id -> coalescing timer.")
(defvar fleet-supervisor--wake-incident (make-hash-table :test 'equal) "fleet-id -> reason blocking auto wake retry.")
(defvar fleet-supervisor-change-hook nil "Run after committed state changes; the dashboard subscribes.")

(defconst fleet-supervisor-wait-tick-sec 30 "Interval for declared-wait deadline checks.")
(defconst fleet-supervisor-wake-batch-limit 25 "Receipts claimed per wake message.")

(defun fleet-supervisor-store ()
  "The open store, or signal `not-started'."
  (or fleet-supervisor--store (fleet-fail 'not-started "Fleet is not started in this Emacs (M-x fleet-dashboard first)")))

(defun fleet-supervisor-owner-p () "Non-nil while this Emacs holds a live lease." (and fleet-supervisor--lease (process-live-p fleet-supervisor--lease) (not fleet-supervisor--fenced)))
(defun fleet-supervisor-read-only-p () "Non-nil in second-Emacs read-only mode." fleet-supervisor--read-only)

(defun fleet-supervisor--changed (&optional fleet-id)
  "Notify subscribers that state changed (FLEET-ID optional)."
  (run-hook-with-args 'fleet-supervisor-change-hook fleet-id))

;;;; Lease (design §6.4)

(defun fleet-supervisor--proc-start-ticks (pid)
  "Kernel process start time (clock ticks since boot) of PID, or nil."
  (when-let* ((stat (fleet-paths-read-file (format "/proc/%d/stat" pid))))
    ;; The command field may contain spaces/parens; fields after the last ')' are stable.
    (let* ((after (substring stat (1+ (cl-position ?\) stat :from-end t))))
           (fields (split-string after " " t)))
      ;; after ')' the fields start at index 3 (state), so starttime (22) is index 19
      (nth 19 fields))))

(defun fleet-supervisor--previous-owner-alive-p (desc)
  "Non-nil when descriptor DESC names a live, unreleased Emacs on this boot."
  (and desc
       (not (eq (plist-get desc :released) t))
       (equal (plist-get desc :bootId) (fleet-paths-boot-id))
       (let ((pid (plist-get desc :emacsPid)))
         (and (integerp pid) (/= pid (emacs-pid))
              (file-exists-p (format "/proc/%d" pid))
              (equal (fleet-supervisor--proc-start-ticks pid) (plist-get desc :emacsStartTicks))))))

(defun fleet-supervisor-acquire (callback)
  "Try to acquire ownership of the data root.
CALLBACK gets (:owner t) or (:owner nil :reason ...).
Runs the lease helper; never unlinks or renames the lock file."
  (let* ((lock (fleet-paths-owner-lock))
         (desc-file (fleet-paths-owner-descriptor))
         (prev (ignore-errors (fleet-store-unjson (fleet-paths-read-file desc-file))))
         (buf (generate-new-buffer " *fleet-lease*" t))
         (done nil))
    (fleet-paths-ensure-dir (fleet-paths-data-root))
    (unless (file-exists-p lock) (fleet-paths-write-atomically lock ""))
    (cond
     ((fleet-supervisor--previous-owner-alive-p prev)
      (kill-buffer buf)
      (funcall callback (list :owner nil :reason 'owner-alive :descriptor prev)))
     (t
      (let ((proc (make-process :name "fleet-lease" :buffer buf :noquery t :connection-type 'pipe
                                :command (list fleet-python-executable (fleet-paths-bridge-executable) "lease" lock)
                                :filter (lambda (p out)
                                          (with-current-buffer (process-buffer p) (insert out))
                                          (unless done
                                            (cond
                                             ((string-match-p "^acquired" out)
                                              (setq done t)
                                              (fleet-supervisor--publish-descriptor p)
                                              (funcall callback (list :owner t)))
                                             ((string-match-p "^busy" out)
                                              (setq done t)
                                              (funcall callback (list :owner nil :reason 'busy :descriptor prev))))))
                                :sentinel (lambda (p _e)
                                            (unless (process-live-p p)
                                              (if (not done)
                                                  (progn (setq done t)
                                                         (funcall callback (list :owner nil :reason 'helper-exited
                                                                                 :output (with-current-buffer buf (buffer-string)))))
                                                (when (eq p fleet-supervisor--lease)
                                                  (fleet-supervisor--fence "lease helper exited"))))))))
        proc)))))

(defun fleet-supervisor--publish-descriptor (proc)
  "Record PROC as the lease holder and publish owner.json under the lock."
  (let ((desc (list :ownerId (fleet-paths-uuid) :epoch (fleet-paths-uuid) :bootId (fleet-paths-boot-id)
                    :emacsPid (emacs-pid) :emacsStartTicks (fleet-supervisor--proc-start-ticks (emacs-pid))
                    :socket (ignore-errors (fleet-paths-socket)) :acquiredAt (fleet-paths-now) :released :false)))
    (setq fleet-supervisor--lease proc
          fleet-supervisor--descriptor desc
          fleet-supervisor--fenced nil
          fleet-core-owner (list :epoch (plist-get desc :epoch)
                                 :live-p (lambda () (fleet-supervisor-owner-p))))
    (fleet-paths-write-atomically (fleet-paths-owner-descriptor) (fleet-store-json desc) #o600)))

(defun fleet-supervisor--fence (reason)
  "Fence all further admissions because of REASON."
  (setq fleet-supervisor--fenced t)
  (message "Fleet: ownership fenced (%s); no further launches or mutations from this Emacs" reason)
  (fleet-supervisor--changed))

(defun fleet-supervisor-release ()
  "Normal release: refuse while owned runtimes live.
Otherwise mark released and drop the lease."
  (when (fleet-supervisor-owner-p)
    (let ((live (fleet-store-scalar (fleet-supervisor-store) "SELECT COUNT(*) FROM runtimes WHERE lifecycle NOT IN ('stopped','never-launched')")))
      (when (> live 0)
        (fleet-fail 'runtimes-live "Stop all runtimes (park, then fleet-commander-stop) before releasing ownership" :live live)))
    (setq fleet-supervisor--fenced t)
    (when fleet-supervisor--descriptor
      (fleet-paths-write-atomically (fleet-paths-owner-descriptor)
                                    (fleet-store-json (plist-put (copy-sequence fleet-supervisor--descriptor) :released t)) #o600))
    (delete-process fleet-supervisor--lease)
    (setq fleet-supervisor--lease nil)
    t))

;;;; Start / stop

(defun fleet-supervisor-start (callback)
  "Open the store as owner (or read-only), install sinks, reconcile.
CALLBACK gets a mode plist."
  (if fleet-supervisor--store
      (funcall callback (list :mode (if fleet-supervisor--read-only 'read-only 'owner)))
    (fleet-supervisor-acquire
     (lambda (r)
       (condition-case err
           (if (plist-get r :owner)
               (progn
                 (setq fleet-supervisor--store (fleet-store-open (fleet-paths-db-file))
                       fleet-supervisor--read-only nil
                       fleet-core-event-sink #'fleet-supervisor-handle-event
                       fleet-eca-human-sink #'fleet-supervisor--human-sink)
                 (add-hook 'fleet-store-actionable-event-hook #'fleet-supervisor--on-actionable-event)
                 (fleet-supervisor--start-timers)
                 (fleet-core-reconcile-runtimes
                  fleet-supervisor--store
                  (lambda (summary)
                    (fleet-supervisor--changed)
                    (funcall callback (list :mode 'owner :reconciled summary)))))
             (setq fleet-supervisor--store (fleet-store-open (fleet-paths-db-file) t)
                   fleet-supervisor--read-only t)
             (funcall callback (list :mode 'read-only :reason (plist-get r :reason) :descriptor (plist-get r :descriptor))))
         (fleet-error (funcall callback (list :mode 'error :error (fleet-error-string err))))
         (error (funcall callback (list :mode 'error :error (error-message-string err)))))))))

(defun fleet-supervisor--start-timers ()
  "Start the declared-wait deadline timer."
  (unless fleet-supervisor--wait-timer
    (setq fleet-supervisor--wait-timer
          (run-with-timer fleet-supervisor-wait-tick-sec fleet-supervisor-wait-tick-sec #'fleet-supervisor--tick))))

(defun fleet-supervisor--tick ()
  "Periodic: expire declared waits.  Emits events; never sends a wake by itself."
  (when (and fleet-supervisor--store (fleet-supervisor-owner-p))
    (condition-case err
        (when (> (fleet-core-expire-waits fleet-supervisor--store) 0)
          (dolist (f (fleet-store-fleets fleet-supervisor--store)) (fleet-supervisor-kick (plist-get f :id) 'event)))
      (error (message "fleet-supervisor: tick error: %s" (error-message-string err))))))

(defun fleet-supervisor--on-actionable-event (fleet-id _event-id _kind)
  "Schedule a wake admission for FLEET-ID after an actionable event.
Installed on `fleet-store-actionable-event-hook' so that actionable events
raised by RPC tool calls (task done/failed/blocked, decisions) and by the
operations journal are delivered without waiting for an unrelated kick."
  (fleet-supervisor-kick fleet-id 'event))

(defun fleet-supervisor-stop ()
  "Close the store and timers in this Emacs without stopping any runtime."
  (remove-hook 'fleet-store-actionable-event-hook #'fleet-supervisor--on-actionable-event)
  (when fleet-supervisor--wait-timer (cancel-timer fleet-supervisor--wait-timer) (setq fleet-supervisor--wait-timer nil))
  (maphash (lambda (_k tm) (cancel-timer tm)) fleet-supervisor--kick-timers)
  (clrhash fleet-supervisor--kick-timers)
  (when fleet-supervisor--store (fleet-store-close fleet-supervisor--store))
  (setq fleet-supervisor--store nil fleet-core-event-sink nil fleet-eca-human-sink nil))

;;;; Runtime observations from adapter events

(defun fleet-supervisor-handle-event (ev)
  "Sink for normalized adapter events EV.
Records observations, routes lane and wakes."
  (let* ((store fleet-supervisor--store)
         (rid (plist-get ev :runtime-id))
         (rt (and store rid (fleet-store-get store "runtimes" rid))))
    (when (and rt (equal (plist-get rt :owner-epoch) (plist-get ev :owner-epoch)))
      (condition-case err
          (fleet-supervisor--handle store rt ev)
        (error (message "fleet-supervisor: event %s failed: %s" (plist-get ev :kind) (error-message-string err))))
      (fleet-supervisor--changed (plist-get rt :fleet-id)))))

(defun fleet-supervisor--seconds-between (from to)
  "Float seconds between ISO timestamps FROM and TO, or nil."
  (fleet-paths-seconds-between from to))

(defun fleet-supervisor--approval-cleared (rt tool-id)
  "Observation plist removing TOOL-ID from RT's stored pending approvals.
A tool that starts running, finishes, or is answered by Fleet is no longer
waiting for approval, whichever side (human, trust mode, Fleet) resolved it.
Returns nil when nothing changes so callers can append it unconditionally."
  (let* ((raw (plist-get rt :pending-approvals))
         (current (and raw (append (fleet-store-unjson raw) nil))))
    (when (and current tool-id (member tool-id current))
      (let ((rest (delete tool-id current)))
        (list :pending-approvals (and rest (fleet-store-json (vconcat rest))))))))

(defun fleet-supervisor--observe (store rid plist)
  "Record observation PLIST on runtime RID."
  (fleet-store-transaction store
    (fleet-store-exec store "UPDATE runtimes SET observation_revision = observation_revision + 1 WHERE id = ?" rid)
    (fleet-store-update store "runtimes" rid (fleet-store-touch (append (list :last-activity-at (fleet-paths-now)) plist)))))

(defun fleet-supervisor--handle (store rt ev)
  "Dispatch EV for runtime RT."
  (let ((rid (plist-get rt :id)) (fid (plist-get rt :fleet-id)) (tid (plist-get rt :task-id)) (kind (plist-get ev :kind)))
    (pcase kind
      ('turn-started (fleet-supervisor--observe store rid (list :turn-state "running"))
                     (fleet-supervisor--message-transition store (plist-get ev :message-id) "turn-observed" nil))
      ('prompt-accepted (fleet-supervisor--message-transition store (plist-get ev :message-id) "accepted" (list :model (plist-get ev :model))))
      ('turn-stopping (fleet-supervisor--observe store rid (list :turn-state "stopping")))
      ('turn-idle-observed
       (fleet-supervisor--observe store rid (list :turn-state "idle" :active-tool nil))
       (let ((mid (plist-get ev :message-id))
             (m (and (plist-get ev :message-id) (fleet-store-get store "messages" (plist-get ev :message-id)))))
         (when mid
           (fleet-supervisor--message-transition store mid "finished"
                                                 (list :source (plist-get ev :source) :error-text (plist-get ev :error-text)
                                                       :usage (plist-get ev :usage))))
         ;; Telemetry: one non-actionable event per finished turn with usage and duration.
         (fleet-store-transaction store
           (fleet-store-append-event store :fleet-id fid :task-id tid :runtime-id rid :kind "turn-finished" :source "eca"
                                     :payload (list :message-id mid :origin (and m (plist-get m :origin))
                                                    :stopped (plist-get ev :was-stopping) :error (and (plist-get ev :error-text) t)
                                                    :usage (plist-get ev :usage)
                                                    :seconds (fleet-supervisor--seconds-between (plist-get ev :submitted-at) (plist-get ev :at)))))
         (when mid (fleet-supervisor--on-message-finished store rt mid)))
       (fleet-supervisor--dispatch-lane store rid)
       (when (equal (plist-get rt :role) "commander") (fleet-supervisor-kick fid 'turn-end)))
      ((or 'tool-running 'tool-preparing)
       (fleet-supervisor--observe store rid (append (list :active-tool (fleet-store-json (list :id (plist-get ev :tool-id) :name (plist-get ev :name) :since (plist-get ev :at))))
                                                    (fleet-supervisor--approval-cleared rt (plist-get ev :tool-id)))))
      ('tool-finished (fleet-supervisor--observe store rid (append (list :active-tool nil)
                                                                   (fleet-supervisor--approval-cleared rt (plist-get ev :tool-id)))))
      ((or 'tool-approved-by-fleet 'tool-rejected-by-fleet)
       (fleet-supervisor--observe store rid (fleet-supervisor--approval-cleared rt (plist-get ev :tool-id))))
      ('tool-approval-required
       (fleet-supervisor--observe store rid (list :pending-approvals (fleet-store-json (vconcat (cl-adjoin (plist-get ev :tool-id)
                                                                                                              (let ((raw (plist-get rt :pending-approvals)))
                                                                                                                (and raw (append (fleet-store-unjson raw) nil)))
                                                                                                              :test #'equal)))))
       ;; Not actionable: only a human can approve a native tool call (in the
       ;; chat, or by trust mode).  Waking the commander for it produced paid
       ;; turns and fabricated "approved" dispositions in rehearsal 1.  The
       ;; dashboard surfaces it as attention instead.
       (fleet-store-transaction store
         (fleet-store-append-event store :fleet-id fid :task-id tid :runtime-id rid :kind "tool-approval-required"
                                   :payload (list :tool-id (plist-get ev :tool-id) :name (plist-get ev :name) :summary (plist-get ev :summary)))))
      ('tool-rejected (fleet-supervisor--observe store rid (fleet-supervisor--approval-cleared rt (plist-get ev :tool-id))))
      ('question-opened
       (fleet-supervisor--observe store rid (list :pending-question (fleet-store-json (list :request-id (plist-get ev :request-id) :question (plist-get ev :question)
                                                                                         :options (vconcat (plist-get ev :options)) :at (plist-get ev :at)))))
       (fleet-store-transaction store
         (fleet-store-append-event store :fleet-id fid :task-id tid :runtime-id rid :kind "question-opened"
                                   :payload (list :question (plist-get ev :question) :options (vconcat (plist-get ev :options)) :request-id (plist-get ev :request-id))
                                   :actionable (equal (plist-get rt :role) "operator")))
       (fleet-supervisor-kick fid 'event))
      ('question-answered (fleet-supervisor--observe store rid (list :pending-question nil)))
      ;; The model catalog is the same for every runtime of this ECA install;
      ;; keep the latest durably so fleet-new and the commander can offer it.
      ('catalog-updated
       (fleet-store-record-eca-catalog store :models (plist-get ev :models) :variants (plist-get ev :variants)
                                       :default-model (plist-get ev :default-model)))
      ('delivery-unknown
       (fleet-supervisor--observe store rid (list :turn-state "unknown"))
       (fleet-supervisor--message-transition store (plist-get ev :message-id) "delivery-unknown" nil)
       (fleet-supervisor--freeze-batch-for store (plist-get ev :message-id) "held-unknown" "needs-reconciliation")
       (fleet-store-transaction store
         (fleet-store-append-event store :fleet-id fid :task-id tid :runtime-id rid :kind "delivery-unknown"
                                   :payload (list :message-id (plist-get ev :message-id)) :actionable (equal (plist-get rt :role) "operator"))))
      ('prompt-rejected
       (fleet-supervisor--message-transition store (plist-get ev :message-id) "rejected" (list :error (plist-get ev :error) :status (plist-get ev :status)))
       (fleet-supervisor--release-batch-for store (plist-get ev :message-id))
       (puthash fid (format "wake rejected: %s" (or (plist-get ev :error) (plist-get ev :status))) fleet-supervisor--wake-incident))
      ('connection-lost
       (unless (member (plist-get rt :lifecycle) '("stopping" "stopped" "stop-unknown"))
         (fleet-supervisor--observe store rid (list :connection-state "lost" :turn-state nil))
         (when-let* ((mid (plist-get ev :in-flight-message)))
           (fleet-supervisor--message-transition store mid "delivery-unknown" (list :reason "connection lost mid-turn"))
           (fleet-supervisor--freeze-batch-for store mid "held-unknown" "needs-reconciliation"))
         (fleet-store-transaction store
           (fleet-store-update store "runtimes" rid (fleet-store-touch (list :lifecycle "lost")))
           (when tid
             (fleet-store-update store "tasks" tid (fleet-store-touch (list :detail "runtime connection lost; service not yet proven stopped" :detail-at (fleet-paths-now)))))
           (fleet-store-append-event store :fleet-id fid :task-id tid :runtime-id rid :kind "runtime-lost"
                                     :payload (list :exit-status (plist-get ev :exit-status)) :actionable t))
         (fleet-supervisor-kick fid 'event)))
      ('protocol-error
       (fleet-store-transaction store
         (fleet-store-append-event store :fleet-id fid :task-id tid :runtime-id rid :kind "protocol-error" :payload (list :error (plist-get ev :error)) :actionable t)))
      (_ nil))))

;;;; Message lane

(defun fleet-supervisor--message-transition (store mid state evidence)
  "Move message MID to STATE with EVIDENCE when it exists."
  (when (and mid (fleet-store-get store "messages" mid))
    (fleet-store-transaction store
      (fleet-store-update store "messages" mid (fleet-store-touch (list :state state :evidence (and evidence (fleet-store-json evidence))))))))

(cl-defun fleet-supervisor-enqueue (store &key fleet-id task-id target-runtime-id origin text sender idempotency-key brief-revision)
  "Durably queue TEXT for TARGET-RUNTIME-ID.
Return (:message-id ID :state STATE :replayed BOOL)."
  (when (and idempotency-key (fleet-store-query1 store "SELECT id, state FROM messages WHERE sender = ? AND idempotency_key = ?" sender idempotency-key))
    (let ((m (fleet-store-query1 store "SELECT id, state FROM messages WHERE sender = ? AND idempotency_key = ?" sender idempotency-key)))
      (cl-return-from fleet-supervisor-enqueue (list :message-id (plist-get m :id) :state (plist-get m :state) :replayed t))))
  (let* ((fleet (fleet-store-get store "fleets" fleet-id))
         (rt (fleet-store-get store "runtimes" target-runtime-id))
         (id (fleet-paths-uuid)) (now (fleet-paths-now))
         (state (if (and (equal (plist-get rt :role) "operator") (member (plist-get fleet :lifecycle) '("parking" "parked"))) "held" "queued")))
    (unless rt (fleet-fail 'no-such-runtime "Unknown target runtime" :runtime-id target-runtime-id))
    (fleet-store-transaction store
      (fleet-store-insert store "messages"
                          (list :id id :idempotency-key idempotency-key :sender sender :fleet-id fleet-id :task-id task-id
                                :target-runtime-id target-runtime-id :origin origin :text text :state state
                                :brief-revision brief-revision :created-at now :updated-at now)))
    (fleet-supervisor--dispatch-lane store target-runtime-id)
    (let ((m (fleet-store-get store "messages" id)))
      (list :message-id id :state (plist-get m :state) :replayed nil))))

(defun fleet-supervisor--lane-busy-p (store rid conn)
  "Non-nil when RID's chat lane already has an in-flight prompt."
  (or (and conn (fleet-eca-conn-turn conn))
      (> (fleet-store-scalar store "SELECT COUNT(*) FROM messages WHERE target_runtime_id = ? AND state IN ('dispatching','accepted','turn-observed','delivery-unknown')" rid) 0)))

(defun fleet-supervisor--next-message (store rid)
  "Oldest queued message for RID, humans first."
  (fleet-store-query1 store "SELECT * FROM messages WHERE target_runtime_id = ? AND state = 'queued'
                             ORDER BY CASE origin WHEN 'human' THEN 0 WHEN 'boot' THEN 1 WHEN 'commander' THEN 2 ELSE 3 END, created_at ASC LIMIT 1" rid))

(defun fleet-supervisor--dispatch-lane (store rid)
  "Dispatch the next queued message for runtime RID.
Only when the lane is free and admission holds."
  (when (fleet-supervisor-owner-p)
    (let* ((rt (fleet-store-get store "runtimes" rid))
           (conn (fleet-eca-conn rid)))
      (when (and rt conn (eq (fleet-eca-conn-state conn) 'ready) (equal (plist-get rt :lifecycle) "ready")
                 (not (fleet-supervisor--lane-busy-p store rid conn)))
        (when-let* ((m (fleet-supervisor--next-message store rid)))
          (cond
           ;; Target must still be the current runtime and scope unchanged.
           ((not (fleet-supervisor--target-current-p store rt m))
            (fleet-supervisor--message-transition store (plist-get m :id) "cancelled-before-dispatch" (list :reason "target runtime or brief revision changed"))
            (fleet-supervisor--release-batch-for store (plist-get m :id))
            (fleet-supervisor--dispatch-lane store rid))
           ;; A pending question/approval on the target: control replies, not prompts, are needed.
           ((or (fleet-eca-conn-pending-question conn) (fleet-eca-conn-pending-approvals conn)) nil)
           (t
            (fleet-supervisor--message-transition store (plist-get m :id) "dispatching" nil)
            (fleet-eca-submit conn :message-id (plist-get m :id) :text (plist-get m :text)
                              :callback (lambda (r) (fleet-supervisor--on-submit-outcome store rid m r))))))))))

(defun fleet-supervisor--target-current-p (store rt m)
  "Non-nil when message M may still be sent to runtime RT."
  (and (equal (plist-get rt :lifecycle) "ready")
       (if (equal (plist-get rt :role) "operator")
           (let ((task (fleet-store-get store "tasks" (plist-get rt :task-id))))
             (and (equal (plist-get task :current-runtime-id) (plist-get rt :id))
                  (or (null (plist-get m :brief-revision)) (eql (plist-get m :brief-revision) (plist-get task :brief-revision)))))
         (equal (plist-get (fleet-store-get store "fleets" (plist-get rt :fleet-id)) :commander-runtime-id) (plist-get rt :id)))))

(defun fleet-supervisor--on-submit-outcome (store rid m r)
  "Record submission outcome R for message M on runtime RID."
  (let ((mid (plist-get m :id)))
    (pcase (plist-get r :outcome)
      ('accepted (fleet-supervisor--message-transition store mid "accepted" (plist-get r :evidence))
                 (fleet-supervisor--batch-transition store mid "delivered"))
      ('observed-unacknowledged (fleet-supervisor--message-transition store mid "turn-observed" (list :ack "timeout" :running-seen t))
                                (fleet-supervisor--batch-transition store mid "delivered"))
      ('rejected
       (fleet-supervisor--message-transition store mid "rejected" (append (list :code (plist-get r :code)) (plist-get r :evidence)))
       (fleet-supervisor--release-batch-for store mid)
       (when (member (plist-get m :origin) '("wake" "reminder"))
         (puthash (plist-get m :fleet-id) (format "wake rejected: %s" (or (plist-get r :code) (plist-get (plist-get r :evidence) :status))) fleet-supervisor--wake-incident))
       (unless (eq (plist-get r :code) 'lane-busy)
         (fleet-store-transaction store
           (fleet-store-append-event store :fleet-id (plist-get m :fleet-id) :task-id (plist-get m :task-id) :runtime-id rid :kind "message-rejected"
                                     :payload (list :message-id mid :origin (plist-get m :origin) :code (plist-get r :code))
                                     :actionable (not (member (plist-get m :origin) '("wake" "reminder")))))))
      (_ (fleet-supervisor--message-transition store mid "delivery-unknown" (plist-get r :evidence))
         (fleet-supervisor--freeze-batch-for store mid "held-unknown" "needs-reconciliation")))
    (when (member (plist-get m :origin) '("human" "commander"))
      (fleet-supervisor--sent-since-detail store m (plist-get r :outcome)))
    (fleet-supervisor--changed (plist-get m :fleet-id))))

(defun fleet-supervisor--sent-since-detail (store m outcome)
  "Append `sent since:' detail on the operator task of accepted message M."
  (when (and (plist-get m :task-id) (memq outcome '(accepted observed-unacknowledged)))
    (let ((task (fleet-store-get store "tasks" (plist-get m :task-id))))
      (when task
        (fleet-store-transaction store
          (fleet-store-update store "tasks" (plist-get task :id)
                              (list :detail (fleet-eca--clip (format "%s · sent since:%s" (or (plist-get task :detail) "") (fleet-eca--clip (or (plist-get m :text) "") 40)) 300))))))))

(defun fleet-supervisor--on-message-finished (store rt mid)
  "Turn of message MID ended on RT.
For wake messages check acknowledgment (one reminder, then hold)."
  (let ((m (fleet-store-get store "messages" mid)))
    (when (and m (member (plist-get m :origin) '("wake" "reminder")))
      (when-let* ((batch (fleet-store-query1 store "SELECT * FROM wake_batches WHERE message_id = ?" mid)))
        (let ((unacked (fleet-store-query store "SELECT id, event_id FROM event_receipts WHERE batch_id = ? AND state = 'claimed'" (plist-get batch :id))))
          (cond
           ((null unacked) (fleet-store-transaction store (fleet-store-update store "wake_batches" (plist-get batch :id) (fleet-store-touch (list :state "finished")))))
           ((eql 0 (plist-get batch :reminder-used))
            ;; One bounded protocol reminder for this batch, then no more model dispatch for it.
            (fleet-store-transaction store
              (fleet-store-update store "wake_batches" (plist-get batch :id) (fleet-store-touch (list :reminder-used 1 :state "queued"))))
            (let ((r (fleet-supervisor-enqueue store :fleet-id (plist-get rt :fleet-id) :target-runtime-id (plist-get rt :id) :origin "reminder" :sender "fleet"
                                               :text (format "Protocol reminder: your last turn ended with %d unacknowledged Fleet event(s) (%s). Call fleet_events_pending, handle them, then fleet_events_ack the exact ids. If you already acted, acknowledge with disposition \"already-handled\"."
                                                             (length unacked) (string-join (mapcar (lambda (u) (plist-get u :event-id)) unacked) ", ")))))
              (fleet-store-transaction store
                (fleet-store-update store "wake_batches" (plist-get batch :id) (fleet-store-touch (list :message-id (plist-get r :message-id)))))))
           (t
            (fleet-store-transaction store
              (fleet-store-update store "wake_batches" (plist-get batch :id) (fleet-store-touch (list :state "held")))
              (fleet-store-append-event store :fleet-id (plist-get rt :fleet-id) :runtime-id (plist-get rt :id) :kind "wake-batch-held"
                                        :payload (list :batch-id (plist-get batch :id) :unacknowledged (length unacked)))))))))))

;;;; Wake batches (design §9.2)

(defun fleet-supervisor--batch-transition (store mid state)
  "Set the batch carrying message MID to STATE."
  (when-let* ((b (fleet-store-query1 store "SELECT id FROM wake_batches WHERE message_id = ?" mid)))
    (fleet-store-transaction store (fleet-store-update store "wake_batches" (plist-get b :id) (fleet-store-touch (list :state state))))))

(defun fleet-supervisor--release-batch-for (store mid)
  "Pre-dispatch cancellation or definite rejection: claims return to pending."
  (when-let* ((b (fleet-store-query1 store "SELECT id FROM wake_batches WHERE message_id = ?" mid)))
    (fleet-store-transaction store
      (fleet-store-exec store "UPDATE event_receipts SET state = 'pending', batch_id = NULL, updated_at = ? WHERE batch_id = ? AND state = 'claimed'" (fleet-paths-now) (plist-get b :id))
      (fleet-store-update store "wake_batches" (plist-get b :id) (fleet-store-touch (list :state "released"))))))

(defun fleet-supervisor--freeze-batch-for (store mid receipt-state batch-state)
  "Delivery unknown: hold claims (RECEIPT-STATE) and mark the batch BATCH-STATE."
  (when-let* ((b (fleet-store-query1 store "SELECT id FROM wake_batches WHERE message_id = ?" mid)))
    (fleet-store-transaction store
      (fleet-store-exec store "UPDATE event_receipts SET state = ?, updated_at = ? WHERE batch_id = ? AND state = 'claimed'" receipt-state (fleet-paths-now) (plist-get b :id))
      (fleet-store-update store "wake_batches" (plist-get b :id) (fleet-store-touch (list :state batch-state))))))

(defun fleet-supervisor-kick (fleet-id reason)
  "Schedule a coalesced admission check for FLEET-ID because of REASON."
  (when (memq reason '(event human resume turn-end)) (remhash fleet-id fleet-supervisor--wake-incident))
  (when (and fleet-supervisor--store (fleet-supervisor-owner-p))
    (unless (gethash fleet-id fleet-supervisor--kick-timers)
      (puthash fleet-id (run-with-timer 0.2 nil (lambda ()
                                                  (remhash fleet-id fleet-supervisor--kick-timers)
                                                  (condition-case err
                                                      (fleet-supervisor-admit-wake fleet-supervisor--store fleet-id)
                                                    (error (message "fleet-supervisor: wake admission failed: %s" (error-message-string err))))))
               fleet-supervisor--kick-timers))))

(defun fleet-supervisor-wake-admission (store fleet-id)
  "Return nil when a wake may be dispatched for FLEET-ID.
Otherwise return a symbol naming the blocker."
  (let* ((fleet (fleet-store-get store "fleets" fleet-id))
         (rid (plist-get fleet :commander-runtime-id))
         (rt (and rid (fleet-store-get store "runtimes" rid)))
         (conn (and rid (fleet-eca-conn rid))))
    (cond
     ((null fleet) 'no-fleet)
     ((not (member (plist-get fleet :lifecycle) '("active"))) 'fleet-not-active)
     ((not (eql 1 (plist-get fleet :supervision))) 'supervision-paused)
     ((or (null rt) (not (equal (plist-get rt :lifecycle) "ready"))) 'commander-unavailable)
     ((or (null conn) (not (eq (fleet-eca-conn-state conn) 'ready))) 'commander-unavailable)
     ((gethash fleet-id fleet-supervisor--wake-incident) 'wake-incident)
     ((fleet-supervisor--lane-busy-p store rid conn) 'commander-busy)
     ((fleet-eca-conn-pending-question conn) 'commander-question)
     ((fleet-eca-conn-pending-approvals conn) 'commander-approval)
     ((fleet-eca-draft conn) 'human-draft)
     ((> (fleet-store-scalar store "SELECT COUNT(*) FROM messages WHERE target_runtime_id = ? AND state = 'queued'" rid) 0) 'queued-messages-first)
     ((= 0 (fleet-store-scalar store "SELECT COUNT(*) FROM event_receipts WHERE fleet_id = ? AND state IN ('pending','needs-reconciliation')" fleet-id)) 'nothing-pending)
     (t nil))))

(defun fleet-supervisor-admit-wake (store fleet-id)
  "Claim pending receipts of FLEET-ID into one batch and queue a single wake.
The wake message is queued only if admitted.
Returns the message id or the blocker symbol."
  (let ((blocker (fleet-supervisor-wake-admission store fleet-id)))
    (if blocker
        (progn (fleet-supervisor--changed fleet-id) blocker)
      (let* ((fleet (fleet-store-get store "fleets" fleet-id))
             (rid (plist-get fleet :commander-runtime-id))
             (receipts (fleet-store-pending-receipts store fleet-id '("pending" "needs-reconciliation") fleet-supervisor-wake-batch-limit))
             (batch (fleet-paths-uuid)) (mid (fleet-paths-uuid)) (now (fleet-paths-now)))
        (fleet-store-transaction store
          (fleet-store-insert store "wake_batches" (list :id batch :fleet-id fleet-id :message-id mid :runtime-id rid :state "queued" :created-at now :updated-at now))
          (dolist (r receipts)
            ;; Enforce one active claim per receipt even under reentrancy.
            (unless (= 1 (fleet-store-exec store "UPDATE event_receipts SET state = 'claimed', batch_id = ?, runtime_id = ?, updated_at = ? WHERE id = ? AND state IN ('pending','needs-reconciliation')"
                                           batch rid now (plist-get r :receipt-id)))
              (fleet-fail 'claim-race "Receipt claimed concurrently" :receipt (plist-get r :receipt-id))))
          (fleet-store-insert store "messages"
                              (list :id mid :sender "fleet" :fleet-id fleet-id :target-runtime-id rid :origin "wake"
                                    :text (fleet-supervisor--wake-text store receipts) :state "queued" :created-at now :updated-at now)))
        (fleet-supervisor--dispatch-lane store rid)
        (fleet-supervisor--changed fleet-id)
        mid))))

(defun fleet-supervisor--wake-text (store receipts)
  "Concise wake message listing RECEIPTS with facts and artifact pointers."
  (concat "Fleet events require your attention. Read them with fleet_events_pending, act, then fleet_events_ack the exact ids. Do not poll.\n\n"
          (mapconcat (lambda (r)
                       (let* ((task (and (plist-get r :task-id) (fleet-store-get store "tasks" (plist-get r :task-id))))
                              (payload (fleet-store-unjson (plist-get r :payload))))
                         (format "- event %s: %s%s%s%s"
                                 (plist-get r :event-id) (plist-get r :kind)
                                 (if task (format " · task `%s`" (plist-get task :name)) "")
                                 (if (plist-get payload :detail) (format " · %s" (fleet-eca--clip (plist-get payload :detail) 120)) "")
                                 (if (equal (plist-get r :state) "needs-reconciliation") " · (unresolved from a previous commander: inspect before acting)" ""))))
                     receipts "\n")))

(cl-defun fleet-supervisor-ack (store &key fleet-id receipt-ids outcome actor)
  "Acknowledge RECEIPT-IDS of FLEET-ID with OUTCOME by ACTOR.
RECEIPT-IDS are event ids or receipt ids.  Returns counts."
  (let ((acked 0) (unknown nil) (now (fleet-paths-now)))
    (fleet-store-transaction store
      (dolist (id receipt-ids)
        (let ((n (fleet-store-exec store "UPDATE event_receipts SET state = 'acknowledged', outcome = ?, acked_at = ?, updated_at = ? WHERE fleet_id = ? AND (id = ? OR event_id = ?) AND state <> 'acknowledged'"
                                   outcome now now fleet-id id id)))
          (if (> n 0) (cl-incf acked n) (push id unknown))))
      (fleet-store-append-event store :fleet-id fleet-id :kind "events-acknowledged" :actor actor
                                :payload (list :ids (vconcat receipt-ids) :outcome outcome))
      ;; Batches whose every receipt is acknowledged are finished.
      (fleet-store-exec store "UPDATE wake_batches SET state = 'finished', updated_at = ? WHERE fleet_id = ? AND state IN ('delivered','held','queued') AND NOT EXISTS (SELECT 1 FROM event_receipts r WHERE r.batch_id = wake_batches.id AND r.state <> 'acknowledged')" now fleet-id))
    (fleet-supervisor--changed fleet-id)
    (list :acknowledged acked :unknown (nreverse unknown))))

(defun fleet-supervisor-pending-for-commander (store fleet-id &optional limit)
  "Non-destructive view of unhandled receipts and started actions for FLEET-ID."
  (list :revision (fleet-store-snapshot-revision store)
        :events (mapcar (lambda (r) (list :event-id (plist-get r :event-id) :kind (plist-get r :kind) :task-id (plist-get r :task-id)
                                          :state (plist-get r :state) :payload (fleet-store-unjson (plist-get r :payload)) :created-at (plist-get r :created-at)))
                        (fleet-store-pending-receipts store fleet-id '("pending" "claimed" "held-unknown" "needs-reconciliation") (or limit 100)))
        :started-actions (fleet-store-query store "SELECT a.action_id, a.operation_id, o.kind, o.state, o.step, o.error FROM actions a LEFT JOIN operations o ON o.id = a.operation_id WHERE a.actor = ? ORDER BY a.created_at DESC LIMIT 50"
                                            (fleet-core-actor-commander fleet-id))))

(defun fleet-supervisor-on-commander-replaced (store fleet-id old-runtime-id)
  "Claims of OLD-RUNTIME-ID become needs-reconciliation.
Their evidence is retained."
  (fleet-store-transaction store
    (fleet-store-exec store "UPDATE event_receipts SET state = 'needs-reconciliation', updated_at = ? WHERE fleet_id = ? AND runtime_id = ? AND state IN ('claimed','held-unknown')" (fleet-paths-now) fleet-id old-runtime-id)
    (fleet-store-exec store "UPDATE wake_batches SET state = 'needs-reconciliation', updated_at = ? WHERE fleet_id = ? AND runtime_id = ? AND state IN ('queued','delivered','held')" (fleet-paths-now) fleet-id old-runtime-id)
    (fleet-store-exec store "UPDATE messages SET state = 'cancelled-before-dispatch', updated_at = ? WHERE fleet_id = ? AND target_runtime_id = ? AND state = 'queued'" (fleet-paths-now) fleet-id old-runtime-id))
  (remhash fleet-id fleet-supervisor--wake-incident))

;;;; Human sends

(defun fleet-supervisor--human-sink (conn envelope)
  "Admit a human message typed into CONN's chat.
Return non-nil on durable admission."
  (let ((store (fleet-supervisor-store)))
    (unless (fleet-supervisor-owner-p) (fleet-fail 'owner-unproven "This Emacs does not own Fleet; message not sent"))
    (let ((r (fleet-supervisor-enqueue store :fleet-id (fleet-eca-conn-fleet-id conn) :task-id (fleet-eca-conn-task-id conn)
                                       :target-runtime-id (fleet-eca-conn-runtime-id conn) :origin "human" :sender fleet-core-actor-human
                                       :text (plist-get envelope :text))))
      (fleet-supervisor--changed (fleet-eca-conn-fleet-id conn))
      (plist-get r :message-id))))

(cl-defun fleet-supervisor-send (store &key fleet-id task-id runtime-id text sender idempotency-key)
  "Queue TEXT for RUNTIME-ID from SENDER.
Dashboard `s' and fleet_message_send share this."
  (let ((rt (or (fleet-store-get store "runtimes" runtime-id) (fleet-fail 'no-such-runtime "Unknown runtime" :runtime-id runtime-id))))
    (unless (equal (plist-get rt :lifecycle) "ready")
      (fleet-fail 'runtime-not-ready "Target runtime is not ready; it will not be restarted implicitly" :lifecycle (plist-get rt :lifecycle)))
    (let ((task (and task-id (fleet-store-get store "tasks" task-id))))
      (fleet-supervisor-enqueue store :fleet-id fleet-id :task-id task-id :target-runtime-id runtime-id
                                :origin (if (equal sender fleet-core-actor-human) "human" "commander") :sender sender
                                :idempotency-key idempotency-key :text text :brief-revision (and task (plist-get task :brief-revision))))))

(provide 'fleet-supervisor)
;;; fleet-supervisor.el ends here
