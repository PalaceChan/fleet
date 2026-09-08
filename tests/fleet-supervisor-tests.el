;;; fleet-supervisor-tests.el --- Tests for fleet-supervisor -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)
(require 'fleet-supervisor)
(require 'fleet-test-fakes)
(require 'fleet-core-tests)

(defmacro fleet-sup-test-with (&rest body)
  "Fakes plus a supervisor bound to the fake store, with a fake owner lease."
  (declare (indent 0))
  `(fleet-test-with-fakes
     (let ((fleet-supervisor--store store)
           (fleet-supervisor--read-only nil)
           (fleet-supervisor--fenced nil)
           (fleet-supervisor--kick-timers (make-hash-table :test 'equal))
           (fleet-supervisor--wake-incident (make-hash-table :test 'equal))
           (fleet-core-event-sink #'fleet-supervisor-handle-event)
           (fleet-eca-human-sink #'fleet-supervisor--human-sink))
       (cl-letf (((symbol-function 'fleet-supervisor-owner-p) (lambda () (not fleet-supervisor--fenced))))
         ,@body))))

(defun fleet-sup-test-commander (store fid)
  "Start a fake commander for FID; return its runtime id."
  (let ((op (fleet-core-start-commander store fid)))
    (fleet-test-wait-op store op)
    (plist-get (fleet-store-get store "fleets" fid) :commander-runtime-id)))

(defun fleet-sup-test-wakes (store fid &optional include-reminders)
  "Wake messages of FID oldest first (reminders too when INCLUDE-REMINDERS)."
  (fleet-store-query store (if include-reminders
                               "SELECT * FROM messages WHERE fleet_id = ? AND origin IN ('wake','reminder') ORDER BY created_at"
                             "SELECT * FROM messages WHERE fleet_id = ? AND origin = 'wake' ORDER BY created_at")
                     fid))

(defun fleet-sup-test-submissions (pred)
  "Fake submissions whose text satisfies PRED, oldest first."
  (cl-remove-if-not (lambda (s) (funcall pred (plist-get s :text))) (reverse fleet-test-fake-submissions)))

(defun fleet-sup-test-settle ()
  "Let coalescing timers and fake turns run."
  (fleet-test-wait-for (lambda () nil) 0.5))

(ert-deftest fleet-supervisor-wake-requires-idle-commander-and-pending-events ()
  (fleet-sup-test-with
    (let* ((fid (fleet-core-test-fleet store)) (cid (fleet-sup-test-commander store fid))
           (tid (plist-get (fleet-core-test-study store fid) :id)))
      ;; once the boot turn is idle nothing is pending
      (fleet-sup-test-settle)
      (should (eq 'nothing-pending (fleet-supervisor-wake-admission store fid)))
      (fleet-core-test-start store tid)
      (setq fleet-test-fake-turn 'busy) ; keep the wake turn open so no reminder logic runs here
      (fleet-core-task-status store :runtime-id (fleet-core-test-runtime store tid) :phase "blocked" :detail "need creds")
      (should (null (fleet-supervisor-wake-admission store fid)))
      (fleet-supervisor-kick fid 'event)
      (fleet-sup-test-settle)
      (let ((wakes (fleet-sup-test-wakes store fid)))
        (should (= 1 (length wakes)))
        (should (string-match-p "task-blocked" (plist-get (car wakes) :text)))
        (should (equal (plist-get (car wakes) :target-runtime-id) cid))
        ;; receipts claimed into exactly one batch; reading pending does not ack
        (should (= 1 (fleet-store-scalar store "SELECT COUNT(*) FROM event_receipts WHERE fleet_id = ? AND state = 'claimed'" fid)))
        (should (= 1 (fleet-store-scalar store "SELECT COUNT(*) FROM wake_batches WHERE fleet_id = ?" fid)))
        (should (= 1 (length (plist-get (fleet-supervisor-pending-for-commander store fid) :events))))
        (should (= 1 (fleet-store-scalar store "SELECT COUNT(*) FROM event_receipts WHERE fleet_id = ? AND state = 'claimed'" fid)))))))

(ert-deftest fleet-supervisor-enqueue-blocked-by-busy-draft-parked-paused ()
  (fleet-sup-test-with
    (let* ((fid (fleet-core-test-fleet store)) (cid (fleet-sup-test-commander store fid))
           (conn (fleet-eca-conn cid))
           (tid (plist-get (fleet-core-test-study store fid) :id)))
      (fleet-sup-test-settle)
      (fleet-core-test-start store tid)
      (fleet-core-task-status store :runtime-id (fleet-core-test-runtime store tid) :phase "failed" :detail "boom")
      ;; commander busy => retained
      (setf (fleet-eca-conn-turn conn) '(:message-id "x" :state running))
      (should (eq 'commander-busy (fleet-supervisor-wake-admission store fid)))
      (setf (fleet-eca-conn-turn conn) nil)
      ;; human draft => retained
      (cl-letf (((symbol-function 'fleet-eca-draft) (lambda (_c) "typing…")))
        (should (eq 'human-draft (fleet-supervisor-wake-admission store fid))))
      ;; commander pending question => retained
      (setf (fleet-eca-conn-pending-question conn) '(:request-id 1))
      (should (eq 'commander-question (fleet-supervisor-wake-admission store fid)))
      (setf (fleet-eca-conn-pending-question conn) nil)
      ;; supervision paused => retained
      (fleet-core-set-supervision store fid nil)
      (should (eq 'supervision-paused (fleet-supervisor-wake-admission store fid)))
      (fleet-core-set-supervision store fid t)
      ;; parked => retained
      (fleet-test-wait-op store (fleet-core-park-fleet store fid))
      (should (eq 'fleet-not-active (fleet-supervisor-wake-admission store fid)))
      (should (= 0 (length (fleet-sup-test-wakes store fid))))
      ;; the event is still pending, untouched
      (should (= 1 (length (fleet-store-pending-receipts store fid))))
      ;; resume => admitted
      (fleet-core-resume-fleet store fid)
      (should (null (fleet-supervisor-wake-admission store fid)))
      (should (stringp (fleet-supervisor-admit-wake store fid))))))

(ert-deftest fleet-supervisor-human-message-precedes-wake-and-single-lane ()
  (fleet-sup-test-with
    (let* ((fid (fleet-core-test-fleet store)) (cid (fleet-sup-test-commander store fid))
           (conn (fleet-eca-conn cid))
           (tid (plist-get (fleet-core-test-study store fid) :id)))
      (fleet-sup-test-settle)
      (fleet-core-test-start store tid)
      (setq fleet-test-fake-turn 'busy) ; turns stay open until we finish them
      (fleet-core-task-status store :runtime-id (fleet-core-test-runtime store tid) :phase "blocked" :detail "x")
      ;; human types into the commander chat: admitted through the sink, queued, dispatched first
      (should (fleet-supervisor--human-sink conn '(:text "hello commander")))
      (fleet-sup-test-settle)
      (should (equal (plist-get (car fleet-test-fake-submissions) :text) "hello commander"))
      (should (eq 'commander-busy (fleet-supervisor-wake-admission store fid)))
      ;; only one prompt in flight on the commander lane; the wake waits
      (should (= 0 (length (fleet-sup-test-submissions (lambda (s) (string-match-p "Fleet events" s))))))
      (fleet-test-fake-finish conn)
      (fleet-sup-test-settle)
      (should (= 1 (length (fleet-sup-test-submissions (lambda (s) (string-match-p "Fleet events" s))))))
      (should (string-match-p "Fleet events" (plist-get (car fleet-test-fake-submissions) :text)))
      (should (equal "finished" (plist-get (fleet-store-query1 store "SELECT state FROM messages WHERE origin='human'") :state))))))

(ert-deftest fleet-supervisor-ack-lifecycle-and-reminder-once ()
  (fleet-sup-test-with
    (let* ((fid (fleet-core-test-fleet store)) (cid (fleet-sup-test-commander store fid))
           (conn (fleet-eca-conn cid))
           (tid (plist-get (fleet-core-test-study store fid) :id)))
      (fleet-sup-test-settle)
      (fleet-core-test-start store tid)
      (setq fleet-test-fake-turn 'busy)
      (fleet-core-task-status store :runtime-id (fleet-core-test-runtime store tid) :phase "blocked" :detail "x")
      (fleet-supervisor-kick fid 'event) (fleet-sup-test-settle)
      (should (= 1 (length (fleet-sup-test-wakes store fid t))))
      ;; commander ends the turn without acknowledging => exactly one reminder
      (fleet-test-fake-finish conn) (fleet-sup-test-settle)
      (should (= 2 (length (fleet-sup-test-wakes store fid t))))
      (should (equal "reminder" (plist-get (cadr (fleet-sup-test-wakes store fid t)) :origin)))
      (should (eql 1 (plist-get (fleet-store-query1 store "SELECT reminder_used FROM wake_batches WHERE fleet_id = ?" fid) :reminder-used)))
      ;; second unacknowledged finish => batch held, no third message, attention event
      (fleet-test-fake-finish conn) (fleet-sup-test-settle)
      (should (= 2 (length (fleet-sup-test-wakes store fid t))))
      (should (equal "held" (plist-get (fleet-store-query1 store "SELECT state FROM wake_batches WHERE fleet_id = ?" fid) :state)))
      (should (fleet-store-query1 store "SELECT 1 FROM events WHERE kind = 'wake-batch-held'"))
      ;; ack by event id finishes the batch
      (let* ((ev-id (plist-get (car (plist-get (fleet-supervisor-pending-for-commander store fid) :events)) :event-id))
             (r (fleet-supervisor-ack store :fleet-id fid :receipt-ids (list ev-id "bogus") :outcome "handled" :actor "c")))
        (should (= 1 (plist-get r :acknowledged)))
        (should (equal '("bogus") (plist-get r :unknown)))
        (should (equal "finished" (plist-get (fleet-store-query1 store "SELECT state FROM wake_batches WHERE fleet_id = ?" fid) :state)))
        (should (= 0 (fleet-store-scalar store "SELECT COUNT(*) FROM event_receipts WHERE fleet_id = ? AND state <> 'acknowledged'" fid)))))))

(ert-deftest fleet-supervisor-rejected-wake-releases-claims-and-blocks-retry ()
  (fleet-sup-test-with
    (let* ((fid (fleet-core-test-fleet store)) (_cid (fleet-sup-test-commander store fid))
           (tid (plist-get (fleet-core-test-study store fid) :id)))
      (fleet-sup-test-settle)
      (fleet-core-test-start store tid)
      (fleet-core-task-status store :runtime-id (fleet-core-test-runtime store tid) :phase "blocked" :detail "x")
      (setq fleet-test-fake-turn 'reject)
      (fleet-supervisor-kick fid 'retry) (fleet-sup-test-settle)
      (let ((wake (car (fleet-sup-test-wakes store fid))))
        (should (equal "rejected" (plist-get wake :state))))
      ;; claims back to pending, batch released, auto retry blocked until a new event/human action
      (should (= 1 (fleet-store-scalar store "SELECT COUNT(*) FROM event_receipts WHERE fleet_id = ? AND state = 'pending'" fid)))
      (should (equal "released" (plist-get (fleet-store-query1 store "SELECT state FROM wake_batches WHERE fleet_id = ?" fid) :state)))
      (should (eq 'wake-incident (fleet-supervisor-wake-admission store fid)))
      (setq fleet-test-fake-turn 'finish)
      (fleet-supervisor-kick fid 'human) (fleet-sup-test-settle)
      (should (= 2 (length (fleet-sup-test-wakes store fid)))))))

(ert-deftest fleet-supervisor-unknown-delivery-freezes-lane-never-resends ()
  (fleet-sup-test-with
    (let* ((fid (fleet-core-test-fleet store)) (cid (fleet-sup-test-commander store fid))
           (tid (plist-get (fleet-core-test-study store fid) :id)))
      (fleet-sup-test-settle)
      (fleet-core-test-start store tid)
      (fleet-core-task-status store :runtime-id (fleet-core-test-runtime store tid) :phase "blocked" :detail "x")
      (setq fleet-test-fake-turn 'unknown)
      (fleet-supervisor-kick fid 'event) (fleet-sup-test-settle)
      (should (equal "delivery-unknown" (plist-get (car (fleet-sup-test-wakes store fid)) :state)))
      (should (= 1 (fleet-store-scalar store "SELECT COUNT(*) FROM event_receipts WHERE fleet_id = ? AND state = 'held-unknown'" fid)))
      (should (equal "needs-reconciliation" (plist-get (fleet-store-query1 store "SELECT state FROM wake_batches WHERE fleet_id = ?" fid) :state)))
      ;; lane frozen: admission blocked as busy, no second send even after kicks
      (should (eq 'commander-busy (fleet-supervisor-wake-admission store fid)))
      (fleet-supervisor-kick fid 'human) (fleet-sup-test-settle)
      (should (= 1 (length (fleet-sup-test-wakes store fid))))
      (should (= 1 (length (fleet-sup-test-submissions (lambda (s) (string-match-p "Fleet events" s))))))
      ;; only verified commander replacement reconciles the claims
      (fleet-supervisor-on-commander-replaced store fid cid)
      (should (= 1 (fleet-store-scalar store "SELECT COUNT(*) FROM event_receipts WHERE fleet_id = ? AND state = 'needs-reconciliation'" fid))))))

(ert-deftest fleet-supervisor-operator-events-observed-and-lost-connection ()
  (fleet-sup-test-with
    (let* ((fid (fleet-core-test-fleet store))
           (tid (plist-get (fleet-core-test-study store fid) :id)))
      (fleet-core-test-start store tid)
      (let* ((rid (fleet-core-test-runtime store tid)) (conn (fleet-eca-conn rid)))
        (fleet-eca--emit conn 'tool-running :tool-id "t1" :name "shell")
        (should (string-match-p "shell" (plist-get (fleet-store-get store "runtimes" rid) :active-tool)))
        (fleet-eca--emit conn 'question-opened :request-id 7 :question "Red or blue?" :options '("Red" "Blue"))
        (should (string-match-p "Red or blue" (plist-get (fleet-store-get store "runtimes" rid) :pending-question)))
        (should (cl-some (lambda (r) (equal (plist-get r :kind) "question-opened")) (fleet-store-pending-receipts store fid)))
        (fleet-eca--emit conn 'question-answered :request-id 7)
        (should (null (plist-get (fleet-store-get store "runtimes" rid) :pending-question)))
        ;; stale epoch events are ignored
        (fleet-eca--emit (fleet-eca-conn--make :runtime-id rid :owner-epoch "old" :sink #'fleet-supervisor-handle-event) 'tool-running :tool-id "zz" :name "nope")
        (should-not (string-match-p "nope" (or (plist-get (fleet-store-get store "runtimes" rid) :active-tool) "")))
        ;; connection lost while working: runtime lost, actionable event, no automatic respawn
        (fleet-eca--emit conn 'connection-lost :exit-status 137 :in-flight-message nil)
        (should (equal "lost" (plist-get (fleet-store-get store "runtimes" rid) :lifecycle)))
        (should (cl-some (lambda (r) (equal (plist-get r :kind) "runtime-lost")) (fleet-store-pending-receipts store fid)))
        (should (= 1 (fleet-store-scalar store "SELECT COUNT(*) FROM runtimes WHERE task_id = ?" tid)))
        ;; start refused until the lost runtime is proven stopped
        (fleet-test-should-fail 'task-not-startable (fleet-core-start-task store tid))))))

(ert-deftest fleet-supervisor-send-to-operator-records-outcome-and-detail ()
  (fleet-sup-test-with
    (let* ((fid (fleet-core-test-fleet store))
           (tid (plist-get (fleet-core-test-study store fid) :id)))
      (fleet-core-test-start store tid)
      (let* ((rid (fleet-core-test-runtime store tid))
             (r (fleet-supervisor-send store :fleet-id fid :task-id tid :runtime-id rid :text "please hurry" :sender (fleet-core-actor-commander fid) :idempotency-key "k1")))
        (fleet-sup-test-settle)
        (should (equal "finished" (plist-get (fleet-store-get store "messages" (plist-get r :message-id)) :state)))
        (should (string-match-p "sent since:please hurry" (plist-get (fleet-store-get store "tasks" tid) :detail)))
        ;; idempotent replay
        (should (plist-get (fleet-supervisor-send store :fleet-id fid :task-id tid :runtime-id rid :text "please hurry" :sender (fleet-core-actor-commander fid) :idempotency-key "k1") :replayed))
        (should (= 1 (fleet-store-scalar store "SELECT COUNT(*) FROM messages WHERE origin = 'commander'")))
        ;; stopped target: refused, not restarted
        (fleet-test-wait-op store (fleet-core-park-fleet store fid))
        (fleet-test-should-fail 'runtime-not-ready (fleet-supervisor-send store :fleet-id fid :task-id tid :runtime-id rid :text "x" :sender "human"))))))

(ert-deftest fleet-supervisor-stale-brief-revision-message-cancelled ()
  (fleet-sup-test-with
    (let* ((fid (fleet-core-test-fleet store))
           (tid (plist-get (fleet-core-test-study store fid) :id)))
      (fleet-core-test-start store tid)
      (setq fleet-test-fake-turn 'busy)
      (let* ((rid (fleet-core-test-runtime store tid)) (conn (fleet-eca-conn rid)))
        ;; occupy the lane, queue an answer bound to revision 1, then the scope changes
        (fleet-supervisor-send store :fleet-id fid :task-id tid :runtime-id rid :text "first" :sender "human")
        (fleet-sup-test-settle)
        (fleet-supervisor-send store :fleet-id fid :task-id tid :runtime-id rid :text "old answer" :sender "human")
        (fleet-store-transaction store (fleet-store-update store "tasks" tid (list :brief-revision 2)))
        (fleet-test-fake-finish conn) (fleet-sup-test-settle)
        (should (equal "cancelled-before-dispatch" (plist-get (fleet-store-query1 store "SELECT state FROM messages WHERE text = 'old answer'") :state)))
        (should (= 1 (cl-count-if (lambda (s) (equal (plist-get s :text) "first")) fleet-test-fake-submissions)))))))

(ert-deftest fleet-supervisor-lease-acquire-busy-and-release ()
  (fleet-test-with-roots
    (let ((r1 nil) (r2 nil)
          (fleet-supervisor--lease nil) (fleet-supervisor--descriptor nil) (fleet-supervisor--fenced nil))
      (fleet-supervisor-acquire (lambda (r) (setq r1 r)))
      (should (fleet-test-wait-for (lambda () r1) 10))
      (should (plist-get r1 :owner))
      (should (fleet-supervisor-owner-p))
      (should (file-exists-p (fleet-paths-owner-descriptor)))
      (let ((desc (fleet-store-unjson (fleet-paths-read-file (fleet-paths-owner-descriptor)))))
        (should (equal (plist-get desc :emacsPid) (emacs-pid)))
        (should (eq :false (plist-get desc :released))))
      ;; a second acquirer in the same Emacs sees the live descriptor/pid... it is *us*, so the
      ;; descriptor check is skipped and the kernel lock answers: busy.
      (let ((first fleet-supervisor--lease))
        (fleet-supervisor-acquire (lambda (r) (setq r2 r)))
        (should (fleet-test-wait-for (lambda () r2) 10))
        (should-not (plist-get r2 :owner))
        (should (eq 'busy (plist-get r2 :reason)))
        (should (eq first fleet-supervisor--lease)))
      ;; helper death fences
      (let ((store (fleet-store-open (fleet-paths-db-file))))
        (setq fleet-supervisor--store store)
        (unwind-protect
            (progn
              (should (fleet-supervisor-release))
              (should-not (fleet-supervisor-owner-p))
              (should (eq t (plist-get (fleet-store-unjson (fleet-paths-read-file (fleet-paths-owner-descriptor))) :released))))
          (fleet-store-close store)
          (setq fleet-supervisor--store nil))))))

(ert-deftest fleet-supervisor-refuses-takeover-from-live-unreleased-owner ()
  (fleet-test-with-roots
    (let ((fleet-supervisor--lease nil) (fleet-supervisor--descriptor nil) (r nil))
      ;; a descriptor naming a live process (our own parent shell is not us; use pid 1 with its real ticks)
      (fleet-paths-write-atomically (fleet-paths-owner-descriptor)
                                    (fleet-store-json (list :bootId (fleet-paths-boot-id) :emacsPid 1
                                                            :emacsStartTicks (fleet-supervisor--proc-start-ticks 1) :released :false)))
      (fleet-supervisor-acquire (lambda (x) (setq r x)))
      (should (fleet-test-wait-for (lambda () r) 5))
      (should-not (plist-get r :owner))
      (should (eq 'owner-alive (plist-get r :reason)))
      ;; released descriptor permits takeover; stale pid (start ticks mismatch) permits takeover
      (fleet-paths-write-atomically (fleet-paths-owner-descriptor)
                                    (fleet-store-json (list :bootId (fleet-paths-boot-id) :emacsPid 1 :emacsStartTicks "0" :released :false)))
      (setq r nil)
      (fleet-supervisor-acquire (lambda (x) (setq r x)))
      (should (fleet-test-wait-for (lambda () r) 10))
      (should (plist-get r :owner))
      (delete-process fleet-supervisor--lease))))

(provide 'fleet-supervisor-tests)
;;; fleet-supervisor-tests.el ends here
