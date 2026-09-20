;;; fleet-supervisor-tests.el --- Tests for fleet-supervisor -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)
(require 'fleet-supervisor)
(require 'fleet-rpc)
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
           (fleet-eca-human-sink #'fleet-supervisor--human-sink)
           ;; installed by `fleet-supervisor-start' in production
           (fleet-store-actionable-event-hook (list #'fleet-supervisor--on-actionable-event)))
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

(ert-deftest fleet-supervisor-persists-eca-catalog-from-any-runtime ()
  "The model catalog a runtime announces becomes durable so fleet-new can offer
completion and the commander can resolve casual model names."
  (fleet-sup-test-with
    (should-not (plist-get (fleet-store-eca-catalog store) :models))
    (let ((fid (fleet-core-test-fleet store)))
      (fleet-sup-test-commander store fid)
      (should (equal (fleet-store-eca-catalog store)
                     '(:models ("fake/model" "fake/other") :default-model "fake/model" :variants ("low" "high"))))
      ;; The commander's boot message carries the catalog and its own effective model.
      (let ((boot (plist-get (car (fleet-sup-test-submissions (lambda (s) (string-match-p "## Models" s)))) :text)))
        (should boot)
        (should (string-match-p "You run on `fake/model`" boot))
        (should (string-match-p "fake/model, fake/other" boot))
        (should (string-match-p "Variants announced.*low, high" boot))))))

(ert-deftest fleet-supervisor-delegation-is-a-lane-message-down-and-an-actionable-event-up ()
  "fleet_delegate opens a request and queues the brief on the lieutenant's lane;
fleet_report appends an actionable event to the parent, which wakes the root
commander; settling closes the request once; scope refusals hold."
  (fleet-sup-test-with
    (let* ((rid (fleet-core-test-fleet store "workshop"))
           (lt (fleet-core-create-fleet store "frontend" :parent-id rid :charter "UI"))
           (lid (plist-get lt :id))
           (other (fleet-core-test-fleet store "other"))
           (root-actor (fleet-core-actor-commander rid))
           (lt-actor (fleet-core-actor-commander lid)))
      ;; Not ready: refused, nothing recorded.
      (fleet-test-should-fail 'runtime-not-ready
        (fleet-supervisor-delegate store :fleet-id rid :actor root-actor :lieutenant "frontend" :subject "nav" :text "brief" :idempotency-key "k0"))
      (should (= 0 (fleet-store-scalar store "SELECT COUNT(*) FROM requests")))
      (let ((root-cid (fleet-sup-test-commander store rid)) (lt-cid (fleet-sup-test-commander store lid)))
        (fleet-sup-test-settle)
        ;; Scope: only my own lieutenant, by name or id; a root is nobody's lieutenant.
        (fleet-test-should-fail 'forbidden (fleet-supervisor-delegate store :fleet-id other :actor (fleet-core-actor-commander other) :lieutenant "frontend" :subject "s" :text "t" :idempotency-key "k1"))
        (fleet-test-should-fail 'forbidden (fleet-supervisor-delegate store :fleet-id rid :actor root-actor :lieutenant "other" :subject "s" :text "t" :idempotency-key "k1"))
        (fleet-test-should-fail 'invalid-request (fleet-supervisor-delegate store :fleet-id rid :actor root-actor :lieutenant lid :text "no subject" :idempotency-key "k1"))
        ;; Open a request: durable row + message on the lieutenant lane, prefixed with the request id.
        (let* ((r (fleet-supervisor-delegate store :fleet-id rid :actor root-actor :lieutenant "frontend" :subject "Keyboard navigation" :text "Goal: ..." :idempotency-key "k2"))
               (req-id (plist-get r :request-id))
               (req (fleet-store-get store "requests" req-id)))
          (should req-id)
          (should (equal (plist-get req :state) "open"))
          (should (equal (plist-get req :parent-fleet-id) rid))
          (should (equal (plist-get req :child-fleet-id) lid))
          (should (equal (plist-get req :message-id) (plist-get r :message-id)))
          (fleet-sup-test-settle)
          (let ((m (fleet-store-get store "messages" (plist-get r :message-id))))
            (should (equal (plist-get m :target-runtime-id) lt-cid))
            (should (equal (plist-get m :origin) "commander"))
            (should (equal (plist-get m :fleet-id) lid))
            (should (string-match-p (format "Request `%s` — Keyboard navigation" req-id) (plist-get m :text)))
            (should (string-match-p "Goal: \\.\\.\\." (plist-get m :text))))
          (should (fleet-sup-test-submissions (lambda (s) (string-match-p "Keyboard navigation" s))))
          ;; Same key replays without a second request or message.
          (let ((again (fleet-supervisor-delegate store :fleet-id rid :actor root-actor :lieutenant "frontend" :subject "Keyboard navigation" :text "Goal: ..." :idempotency-key "k2")))
            (should (plist-get again :replayed))
            (should (equal (plist-get again :request-id) req-id)))
          (should (= 1 (fleet-store-scalar store "SELECT COUNT(*) FROM requests")))
          ;; Follow-up on the open request; a stranger's or unknown request is refused.
          (should (equal (plist-get (fleet-supervisor-delegate store :fleet-id rid :actor root-actor :lieutenant lid :text "Also cover the settings menu" :request-id req-id :idempotency-key "k3") :request-id) req-id))
          (fleet-test-should-fail 'forbidden (fleet-supervisor-delegate store :fleet-id rid :actor root-actor :lieutenant lid :text "x" :request-id "nope" :idempotency-key "k4"))
          (should (= 1 (fleet-store-scalar store "SELECT COUNT(*) FROM requests")))
          ;; The root and the lieutenant both see the open request in their snapshots.
          (should (= 1 (length (plist-get (car (plist-get (fleet-store-snapshot store rid) :fleets)) :open-requests))))
          (should (= 1 (length (plist-get (car (plist-get (fleet-store-snapshot store lid) :fleets)) :open-requests))))
          ;; Reporting: only a lieutenant, only on its own open request; settled needs an outcome.
          (fleet-test-should-fail 'not-a-lieutenant (fleet-supervisor-report store :fleet-id rid :actor root-actor :kind "progress" :text "x"))
          (fleet-test-should-fail 'forbidden (fleet-supervisor-report store :fleet-id lid :actor lt-actor :kind "progress" :text "x" :request-id "nope"))
          (fleet-test-should-fail 'invalid-request (fleet-supervisor-report store :fleet-id lid :actor lt-actor :kind "settled" :text "x" :request-id req-id))
          (fleet-test-should-fail 'invalid-request (fleet-supervisor-report store :fleet-id lid :actor lt-actor :kind "settled" :text "x"))
          ;; A question wakes the root: actionable receipt in the parent fleet, wake message names the lieutenant and request.
          (setq fleet-test-fake-turn 'busy)
          (let ((q (fleet-supervisor-report store :fleet-id lid :actor lt-actor :kind "question" :text "Dark mode too?" :request-id req-id)))
            (should (plist-get q :event-id))
            (should (equal (plist-get q :state) "open")))
          (fleet-sup-test-settle)
          (let ((wakes (fleet-sup-test-wakes store rid)))
            (should (= 1 (length wakes)))
            (should (equal (plist-get (car wakes) :target-runtime-id) root-cid))
            (should (string-match-p "lieutenant-report · lieutenant `frontend` question" (plist-get (car wakes) :text)))
            (should (string-match-p (format "request `%s`" req-id) (plist-get (car wakes) :text)))
            (should (string-match-p "Dark mode too\\?" (plist-get (car wakes) :text))))
          (should (= 0 (length (fleet-sup-test-wakes store lid))))
          (should (= 1 (fleet-store-scalar store "SELECT COUNT(*) FROM event_receipts WHERE fleet_id = ? AND state = 'claimed'" rid)))
          ;; Settle once; a second settlement and further follow-ups are refused.
          (let ((s (fleet-supervisor-report store :fleet-id lid :actor lt-actor :kind "settled" :outcome "done" :text "Shipped on branch x" :request-id req-id)))
            (should (equal (plist-get s :state) "settled")))
          (let ((req (fleet-store-get store "requests" req-id)))
            (should (equal (plist-get req :state) "settled"))
            (should (equal (plist-get req :outcome) "done"))
            (should (equal (plist-get req :summary) "Shipped on branch x")))
          (fleet-test-should-fail 'request-settled (fleet-supervisor-report store :fleet-id lid :actor lt-actor :kind "settled" :outcome "done" :text "again" :request-id req-id))
          (fleet-test-should-fail 'request-settled (fleet-supervisor-delegate store :fleet-id rid :actor root-actor :lieutenant lid :text "more" :request-id req-id :idempotency-key "k5"))
          (should (= 0 (length (plist-get (car (plist-get (fleet-store-snapshot store rid) :fleets)) :open-requests))))
          ;; An out-of-band notice needs no request.  Question, settle and notice: three receipts for the root.
          (should (plist-get (fleet-supervisor-report store :fleet-id lid :actor lt-actor :kind "progress" :text "The user asked me directly to ...") :event-id))
          (should (= 3 (fleet-store-scalar store "SELECT COUNT(*) FROM event_receipts WHERE fleet_id = ?" rid)))
          ;; Wire scope: a lieutenant's tools are the commander's plus fleet_report, minus fleet_delegate.
          (let ((fleet-rpc--tools nil) ; read the checkout's schema, not a cached one
                (names (lambda (role) (mapcar (lambda (tool) (plist-get tool :name)) (fleet-rpc-tools-for-role role)))))
            (should (member "fleet_report" (funcall names "lieutenant")))
            (should-not (member "fleet_delegate" (funcall names "lieutenant")))
            (should (member "fleet_delegate" (funcall names "commander")))
            (should-not (member "fleet_report" (funcall names "commander")))
            (should (member "fleet_task_create" (funcall names "lieutenant")))
            (should-not (member "fleet_report" (funcall names "operator")))))))))

(ert-deftest fleet-supervisor-lieutenant-replace-is-non-cascading-and-wakes-the-root ()
  "The commander replaces one lieutenant's runtime: verified stop, claims to
reconciliation, successor booted with the handoff; the root, siblings and
operators continue; the root gets an actionable event; busy/foreign refusals."
  (fleet-sup-test-with
    (let* ((rid (fleet-core-test-fleet store "workshop"))
           (lid (plist-get (fleet-core-create-fleet store "frontend" :parent-id rid :charter "UI") :id))
           (sid (plist-get (fleet-core-create-fleet store "backend" :parent-id rid :charter "data") :id))
           (other (fleet-core-test-fleet store "other"))
           (root-actor (fleet-core-actor-commander rid))
           (root-cid (fleet-sup-test-commander store rid))
           (old (fleet-sup-test-commander store lid))
           (sib (fleet-sup-test-commander store sid))
           (tid (plist-get (fleet-core-test-study store lid "nav") :id)))
      (fleet-sup-test-settle)
      (fleet-core-test-start store tid)
      (let ((op-rt (fleet-core-test-runtime store tid)))
        (fleet-test-write (expand-file-name "commander/context.md" (plist-get (fleet-store-get store "fleets" lid) :artifact-root)) "# handoff\nnav is half done\n")
        ;; Foreign and mid-turn refusals.
        (fleet-test-should-fail 'forbidden (fleet-supervisor-replace-lieutenant store :fleet-id other :actor (fleet-core-actor-commander other) :lieutenant "frontend" :action-id "r0"))
        (fleet-store-transaction store (fleet-store-update store "runtimes" old (list :turn-state "running")))
        (fleet-test-should-fail 'runtime-busy (fleet-supervisor-replace-lieutenant store :fleet-id rid :actor root-actor :lieutenant "frontend" :action-id "r1"))
        (fleet-store-transaction store (fleet-store-update store "runtimes" old (list :turn-state "idle")))
        ;; Replace: same key replays the same operation.
        (let* ((r (fleet-supervisor-replace-lieutenant store :fleet-id rid :actor root-actor :lieutenant "frontend" :action-id "r2"))
               (op (plist-get r :operation-id)))
          (should (equal (plist-get r :lieutenant) "frontend"))
          (should (equal (plist-get (fleet-supervisor-replace-lieutenant store :fleet-id rid :actor root-actor :lieutenant "frontend" :action-id "r2") :operation-id) op))
          (should (equal (plist-get (fleet-test-wait-op store op) :state) "done")))
        (fleet-sup-test-settle)
        (let* ((lt (fleet-store-get store "fleets" lid)) (new (plist-get lt :commander-runtime-id)))
          (should-not (equal new old))
          (should (equal (plist-get (fleet-store-get store "runtimes" old) :lifecycle) "stopped"))
          (should (equal (plist-get (fleet-store-get store "runtimes" new) :lifecycle) "ready"))
          (should (equal (fleet-core-effective-role store (fleet-store-get store "runtimes" new)) "lieutenant"))
          ;; Successor booted with the handoff; root, sibling and the operator untouched.
          (should (string-match-p "nav is half done" (plist-get (car (fleet-sup-test-submissions (lambda (s) (string-match-p "Recovery summary" s)))) :text)))
          (should (equal (plist-get (fleet-store-get store "fleets" rid) :commander-runtime-id) root-cid))
          (should (equal (plist-get (fleet-store-get store "fleets" sid) :commander-runtime-id) sib))
          (should (equal (plist-get (fleet-store-get store "runtimes" op-rt) :lifecycle) "ready"))
          (should (equal (fleet-core-test-runtime store tid) op-rt)))
        ;; The root has an actionable lieutenant-replaced event.
        (should (= 1 (fleet-store-scalar store "SELECT COUNT(*) FROM events e JOIN event_receipts r ON r.event_id = e.id WHERE e.fleet_id = ? AND e.kind = 'lieutenant-replaced'" rid)))
        (should (member "fleet_lieutenant_replace" (let ((fleet-rpc--tools nil)) (mapcar (lambda (tool) (plist-get tool :name)) (fleet-rpc-tools-for-role "commander")))))
        (should-not (member "fleet_lieutenant_replace" (let ((fleet-rpc--tools nil)) (mapcar (lambda (tool) (plist-get tool :name)) (fleet-rpc-tools-for-role "lieutenant")))))))))

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

(ert-deftest fleet-supervisor-tick-reports-a-long-wait-once-and-wakes-the-commander ()
  "The supervisor tick runs the wait watchdog after deadline expiry; the
resulting actionable event reaches the commander as a wake naming the task
and the wait, and a second tick in the same window adds nothing."
  (fleet-sup-test-with
    (let* ((fleet-wait-watchdog-sec 1)
           (fid (fleet-core-test-fleet store)) (cid (fleet-sup-test-commander store fid))
           (tid (plist-get (fleet-core-test-study store fid) :id)))
      (fleet-sup-test-settle)
      (fleet-core-test-start store tid)
      (setq fleet-test-fake-turn 'busy)
      (fleet-core-task-status store :runtime-id (fleet-core-test-runtime store tid) :phase "paused" :detail "waiting: CI"
                              :wait (list :reason "CI run 7" :deadline (fleet-core-test-iso 1800)))
      (fleet-sup-test-settle)
      ;; task-paused is not actionable: no wake yet, and a fresh wait is not long
      (should (= 0 (length (fleet-sup-test-wakes store fid))))
      (fleet-supervisor--tick)
      (should (= 0 (fleet-store-scalar store "SELECT COUNT(*) FROM events WHERE kind = 'runtime-waiting-long'")))
      ;; past one threshold the tick reports it once
      (let ((t0 (fleet-paths-time-float (plist-get (fleet-store-query1 store "SELECT created_at FROM events WHERE kind = 'task-paused' AND task_id = ?" tid) :created-at))))
        (should (fleet-test-wait-for (lambda () (>= (- (float-time) t0) 1.05)) 5)))
      (fleet-supervisor--tick)
      (should (= 1 (fleet-store-scalar store "SELECT COUNT(*) FROM events WHERE kind = 'runtime-waiting-long'")))
      (should (= 0 (fleet-store-scalar store "SELECT COUNT(*) FROM events WHERE kind = 'wait-deadline-expired'")))
      (fleet-supervisor--tick)
      (should (= 1 (fleet-store-scalar store "SELECT COUNT(*) FROM events WHERE kind = 'runtime-waiting-long'")))
      (fleet-sup-test-settle)
      (let ((wakes (fleet-sup-test-wakes store fid)))
        (should (= 1 (length wakes)))
        (should (equal (plist-get (car wakes) :target-runtime-id) cid))
        (should (string-match-p "runtime-waiting-long" (plist-get (car wakes) :text)))
        (should (string-match-p "task `study1`" (plist-get (car wakes) :text)))
        (should (string-match-p "CI run 7" (plist-get (car wakes) :text))))
      ;; the task itself is untouched: still paused on the same wait, for the dashboard to show
      (let ((task (fleet-store-get store "tasks" tid)))
        (should (equal "paused" (plist-get task :phase)))
        (should (equal "CI run 7" (plist-get task :wait-reason)))))))

(ert-deftest fleet-supervisor-rpc-actionable-event-wakes-without-external-kick ()
  "Rehearsal 1 bug A: `fleet_status done' created a pending receipt but nothing
kicked the supervisor until an unrelated human message arrived 7 minutes later.
Any actionable event must schedule its own admission."
  (fleet-sup-test-with
    (let* ((fid (fleet-core-test-fleet store)) (cid (fleet-sup-test-commander store fid))
           (tid (plist-get (fleet-core-test-study store fid) :id)))
      (fleet-sup-test-settle)
      (fleet-core-test-start store tid)
      (setq fleet-test-fake-turn 'busy)
      ;; exactly what the RPC handler does: no kick, no --changed
      (fleet-core-task-status store :runtime-id (fleet-core-test-runtime store tid) :phase "done" :detail "report written"
                              :artifacts '((:kind "report" :rel-path "report.md")))
      (fleet-sup-test-settle)
      (let ((wakes (fleet-sup-test-wakes store fid)))
        (should (= 1 (length wakes)))
        (should (string-match-p "task-done" (plist-get (car wakes) :text)))
        (should (equal (plist-get (car wakes) :target-runtime-id) cid)))
      ;; and a non-actionable event does not
      (fleet-store-transaction store
        (fleet-store-append-event store :fleet-id fid :task-id tid :kind "tool-call" :payload '(:operation "x")))
      (fleet-sup-test-settle)
      (should (= 1 (length (fleet-sup-test-wakes store fid)))))))

(ert-deftest fleet-supervisor-tool-approval-is-attention-not-a-wake-and-clears ()
  "Rehearsal 1 bugs B and F: approvals are human-only, so they must not wake the
commander, and the stored pending list must clear when the tool proceeds."
  (fleet-sup-test-with
    (let* ((fid (fleet-core-test-fleet store)) (_cid (fleet-sup-test-commander store fid))
           (tid (plist-get (fleet-core-test-study store fid) :id)))
      (fleet-sup-test-settle)
      (fleet-core-test-start store tid)
      (let* ((rid (fleet-core-test-runtime store tid)) (conn (fleet-eca-conn rid))
             (pending (lambda () (let ((raw (plist-get (fleet-store-get store "runtimes" rid) :pending-approvals)))
                                   (and raw (append (fleet-store-unjson raw) nil))))))
        (fleet-eca--emit conn 'tool-approval-required :tool-id "call_1" :name "read_file" :summary "Reading x")
        (fleet-eca--emit conn 'tool-approval-required :tool-id "call_2" :name "shell_command" :summary "$ ls")
        (should (equal (sort (funcall pending) #'string<) '("call_1" "call_2")))
        ;; recorded for the dashboard/timeline, but not actionable
        (should (= 2 (fleet-store-scalar store "SELECT COUNT(*) FROM events WHERE kind = 'tool-approval-required' AND actionable = 0")))
        (should (= 0 (fleet-store-scalar store "SELECT COUNT(*) FROM event_receipts WHERE fleet_id = ?" fid)))
        (fleet-sup-test-settle)
        (should (= 0 (length (fleet-sup-test-wakes store fid))))
        ;; human approves call_1 in the chat => toolCallRunning => cleared; call_2 still waits
        (fleet-eca--emit conn 'tool-running :tool-id "call_1" :name "read_file")
        (should (equal (funcall pending) '("call_2")))
        ;; call_2 rejected => nothing pending; dashboard projection leaves 'decision
        (fleet-eca--emit conn 'tool-rejected :tool-id "call_2" :name "shell_command")
        (should (null (funcall pending)))
        (should (null (plist-get (fleet-store-get store "runtimes" rid) :pending-approvals)))))))

(ert-deftest fleet-supervisor-records-fleet-calls-eca-refused-before-forwarding ()
  "Live run 2026-09-17: a commander dropped name/kind/idempotency_key from a
fleet_task_create; ECA refused it against the inputSchema and Fleet never saw
the call, so telemetry counted one refusal fewer than the transcript.  Such a
refusal is now a tool-call event from source eca; Fleet's own refusals and
native tool failures are not double-counted."
  (fleet-sup-test-with
    (let* ((fid (fleet-core-test-fleet store)) (_cid (fleet-sup-test-commander store fid))
           (tid (plist-get (fleet-core-test-study store fid) :id)))
      (fleet-sup-test-settle)
      (fleet-core-test-start store tid)
      (let* ((rid (fleet-core-test-runtime store tid)) (conn (fleet-eca-conn rid))
             (count (lambda () (fleet-store-scalar store "SELECT COUNT(*) FROM events WHERE kind = 'tool-call' AND source = 'eca' AND runtime_id = ?" rid))))
        ;; ECA's schema refusal of a Fleet tool: recorded with the reason
        (fleet-eca--emit conn 'tool-finished :tool-id "c1" :name "fleet_task_create" :error t :ms 23
                         :output "INVALID_ARGS: missing required params: `idempotency_key`, `name`, `kind`")
        (should (= 1 (funcall count)))
        (let ((p (fleet-store-unjson (plist-get (fleet-store-query1 store "SELECT payload FROM events WHERE kind = 'tool-call' AND source = 'eca'") :payload))))
          (should (equal "fleet_task_create" (plist-get p :operation)))
          (should (equal "refused" (plist-get p :outcome)))
          (should (equal "eca-invalid-args" (plist-get p :code)))
          (should (equal "operator" (plist-get p :role)))
          (should (string-match-p "`name`" (plist-get p :output))))
        ;; a Fleet-side refusal already has its RPC event; a native tool failure is not a Fleet call
        (fleet-eca--emit conn 'tool-finished :tool-id "c2" :name "fleet_status" :error t :ms 1
                         :output "{\"error\": {\"code\": \"invalid-request\", \"message\": \"unexpected parameter :question\"}}")
        (fleet-eca--emit conn 'tool-finished :tool-id "c3" :name "shell_command" :error t :ms 5 :output "missing required params: `command`")
        (fleet-eca--emit conn 'tool-finished :tool-id "c4" :name "fleet_snapshot" :error nil :ms 2)
        (should (= 1 (funcall count)))))))

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

(ert-deftest fleet-supervisor-queued-human-messages-drain-in-order-after-each-turn ()
  "Two human prompts typed while the commander is mid-turn are queued and then
sent one per turn end, in order; the lane never stays busy without a turn."
  (fleet-sup-test-with
    (let* ((fid (fleet-core-test-fleet store)) (cid (fleet-sup-test-commander store fid))
           (conn (fleet-eca-conn cid)))
      (fleet-sup-test-settle)
      (setq fleet-test-fake-turn 'busy)
      (should (fleet-supervisor--human-sink conn '(:text "message A")))
      (fleet-sup-test-settle)
      (should (equal (plist-get (car fleet-test-fake-submissions) :text) "message A"))
      (should (fleet-supervisor--human-sink conn '(:text "message B")))
      (should (fleet-supervisor--human-sink conn '(:text "message C")))
      (fleet-sup-test-settle)
      (should (equal '("queued" "queued") (mapcar (lambda (m) (plist-get m :state))
                                                 (fleet-store-query store "SELECT state FROM messages WHERE origin='human' AND text IN ('message B','message C') ORDER BY created_at"))))
      (fleet-test-fake-finish conn) (fleet-sup-test-settle)
      (should (equal (plist-get (car fleet-test-fake-submissions) :text) "message B"))
      (should (fleet-supervisor--lane-busy-p store cid conn))
      (fleet-test-fake-finish conn) (fleet-sup-test-settle)
      (should (equal (plist-get (car fleet-test-fake-submissions) :text) "message C"))
      (fleet-test-fake-finish conn) (fleet-sup-test-settle)
      (should-not (fleet-supervisor--lane-busy-p store cid conn))
      (should (equal '("finished" "finished" "finished")
                     (mapcar (lambda (m) (plist-get m :state))
                             (fleet-store-query store "SELECT state FROM messages WHERE origin='human' ORDER BY created_at")))))))

(ert-deftest fleet-supervisor-empty-turn-resends-once-then-surfaces ()
  "openclaw 2026-09-11: the commander's turn on a human prompt ended in 5.7 s
with no output at all and Fleet marked the message finished; the human saw an
unanswered prompt and nothing else.  An empty turn had no side effects, so the
message is resent once; a second empty turn finishes it and is surfaced."
  (fleet-sup-test-with
    (let* ((fid (fleet-core-test-fleet store)) (cid (fleet-sup-test-commander store fid))
           (conn (fleet-eca-conn cid))
           (sent (lambda (text) (fleet-sup-test-submissions (lambda (s) (equal s text)))))
           (state (lambda (text) (plist-get (fleet-store-query1 store "SELECT state FROM messages WHERE text = ?" text) :state))))
      (fleet-sup-test-settle)
      (setq fleet-test-fake-turn 'busy)
      ;; the human sink reports the durable state, not a guess from the lane
      (let ((r (fleet-supervisor--human-sink conn '(:text "please plan"))))
        (should (plist-get r :message-id))
        ;; sent right away: the fake acknowledges synchronously, the native server a little later
        (should (member (plist-get r :state) '("dispatching" "accepted"))))
      (fleet-sup-test-settle)
      (should (= 1 (length (funcall sent "please plan"))))
      ;; a second human message while the first is in flight really is queued
      (should (equal "queued" (plist-get (fleet-supervisor--human-sink conn '(:text "and then")) :state)))
      ;; empty turn => resent once, ahead of the later message; nothing is finished yet
      (fleet-test-fake-finish conn nil t) (fleet-sup-test-settle)
      (should (= 2 (length (funcall sent "please plan"))))
      (should (= 0 (length (funcall sent "and then"))))
      (should (member (funcall state "please plan") '("dispatching" "accepted" "turn-observed")))
      (should (= 1 (fleet-store-scalar store "SELECT COUNT(*) FROM events WHERE kind = 'turn-empty'")))
      (should (string-match-p "\"retrying\":true" (plist-get (fleet-store-query1 store "SELECT payload FROM events WHERE kind = 'turn-empty'") :payload)))
      (should (= 1 (fleet-store-scalar store "SELECT COUNT(*) FROM events WHERE kind = 'turn-finished' AND payload LIKE '%\"empty\":true%'")))
      ;; empty again => finished with evidence, surfaced (non-actionable for a commander), not resent
      (fleet-test-fake-finish conn nil t) (fleet-sup-test-settle)
      (should (= 2 (length (funcall sent "please plan"))))
      (should (equal "finished" (funcall state "please plan")))
      (should (string-match-p "\"empty\":true" (plist-get (fleet-store-query1 store "SELECT evidence FROM messages WHERE text = 'please plan'") :evidence)))
      (should (= 2 (fleet-store-scalar store "SELECT COUNT(*) FROM events WHERE kind = 'turn-empty'")))
      (should (= 0 (fleet-store-scalar store "SELECT COUNT(*) FROM events WHERE kind = 'turn-empty' AND actionable = 1")))
      ;; the lane moved on to the next queued message, which finishes normally
      (should (= 1 (length (funcall sent "and then"))))
      (fleet-test-fake-finish conn) (fleet-sup-test-settle)
      (should (equal "finished" (funcall state "and then")))
      (should-not (fleet-supervisor--lane-busy-p store cid conn))
      ;; an operator's exhausted empty turn is actionable: the commander decides
      (let ((tid (plist-get (fleet-core-test-study store fid) :id)))
        (setq fleet-test-fake-turn 'finish) ; let the operator's boot turn complete normally
        (fleet-core-test-start store tid)
        (fleet-sup-test-settle)
        (let* ((rid (fleet-core-test-runtime store tid)) (oconn (fleet-eca-conn rid)))
          (setq fleet-test-fake-turn 'busy)
          (fleet-supervisor-send store :fleet-id fid :task-id tid :runtime-id rid :text "operator ping" :sender "fleet:x:commander")
          (fleet-sup-test-settle)
          (fleet-test-fake-finish oconn nil t) (fleet-sup-test-settle)
          (should (= 2 (length (funcall sent "operator ping"))))
          (fleet-test-fake-finish oconn nil t) (fleet-sup-test-settle)
          (should (equal "finished" (funcall state "operator ping")))
          (should (= 1 (fleet-store-scalar store "SELECT COUNT(*) FROM events WHERE kind = 'turn-empty' AND actionable = 1 AND runtime_id = ?" rid))))))))

(ert-deftest fleet-supervisor-barren-turn-falls-back-to-the-policy-model-once ()
  "A turn that did nothing (no text, no tool call), with or without a provider
error, is resent on the owner's fallback model: the runtime moves to it and
keeps its chat.  A barren fallback turn finishes the message and is surfaced;
a turn that did work before failing is never resent."
  (fleet-sup-test-with
    (fleet-test-write-config :models "{\"fallback\": {\"fake/model\": \"fake/other\"}}")
    (let* ((fid (fleet-core-test-fleet store)) (cid (fleet-sup-test-commander store fid))
           (conn (fleet-eca-conn cid))
           (sent (lambda (text) (fleet-sup-test-submissions (lambda (s) (equal s text)))))
           (state (lambda (text) (plist-get (fleet-store-query1 store "SELECT state FROM messages WHERE text = ?" text) :state)))
           (events (lambda (kind &optional rid) (fleet-store-scalar store "SELECT COUNT(*) FROM events WHERE kind = ? AND runtime_id = ?" kind (or rid cid)))))
      (fleet-sup-test-settle)
      ;; Supervision off: the operator's actionable give-up below must not queue a wake on
      ;; the commander lane, which this test drives with human messages only.
      (fleet-core-set-supervision store fid nil)
      (should (equal "fake/model" (plist-get (fleet-store-get store "runtimes" cid) :model)))
      (setq fleet-test-fake-turn 'busy)
      (fleet-supervisor--human-sink conn '(:text "please plan"))
      (fleet-sup-test-settle)
      ;; provider error, nothing done: no same-model resend, straight to the fallback
      (fleet-test-fake-finish conn "Error: openrouter upstream timeout" t) (fleet-sup-test-settle)
      (should (= 2 (length (funcall sent "please plan"))))
      (should (equal "fake/other" (fleet-eca-conn-model conn)))
      (should (equal "fake/other" (plist-get (fleet-store-get store "runtimes" cid) :model)))
      (should (= 1 (funcall events "model-fallback")))
      (should (= 0 (funcall events "turn-empty")))
      (let ((ev (fleet-store-unjson (plist-get (fleet-store-query1 store "SELECT payload FROM events WHERE kind = 'model-fallback'") :payload))))
        (should (equal (plist-get ev :from-model) "fake/model"))
        (should (equal (plist-get ev :model) "fake/other"))
        (should (string-match-p "upstream timeout" (plist-get ev :error-text))))
      (should (member (funcall state "please plan") '("dispatching" "accepted" "turn-observed")))
      ;; the fallback is barren too: no further fallback, finished and surfaced (non-actionable for a commander)
      (fleet-test-fake-finish conn "Error: openrouter upstream timeout" t) (fleet-sup-test-settle)
      (should (= 2 (length (funcall sent "please plan"))))
      (should (equal "finished" (funcall state "please plan")))
      (should (= 1 (funcall events "turn-failed")))
      (should (= 0 (fleet-store-scalar store "SELECT COUNT(*) FROM events WHERE kind = 'turn-failed' AND actionable = 1")))
      (should (= 1 (funcall events "model-fallback")))
      ;; a turn that did work before erroring is finished with its error and never resent
      (fleet-supervisor--human-sink conn '(:text "and then"))
      (fleet-sup-test-settle)
      (fleet-test-fake-finish conn "Error: provider overloaded" nil) (fleet-sup-test-settle)
      (should (= 1 (length (funcall sent "and then"))))
      (should (equal "finished" (funcall state "and then")))
      (should (= 1 (funcall events "turn-failed")))
      ;; an operator: empty turn => same-model resend, empty again => fallback, empty again => actionable give-up
      (let ((tid (plist-get (fleet-core-test-study store fid) :id)))
        (setq fleet-test-fake-turn 'finish)
        (fleet-core-test-start store tid)
        (fleet-sup-test-settle)
        (let* ((rid (fleet-core-test-runtime store tid)) (oconn (fleet-eca-conn rid)))
          (should (equal "fake/model" (plist-get (fleet-store-get store "runtimes" rid) :model)))
          (setq fleet-test-fake-turn 'busy)
          (fleet-supervisor-send store :fleet-id fid :task-id tid :runtime-id rid :text "operator ping" :sender "fleet:x:commander")
          (fleet-sup-test-settle)
          (fleet-test-fake-finish oconn nil t) (fleet-sup-test-settle)
          (should (= 2 (length (funcall sent "operator ping"))))
          (should (equal "fake/model" (plist-get (fleet-store-get store "runtimes" rid) :model)))
          (fleet-test-fake-finish oconn nil t) (fleet-sup-test-settle)
          (should (= 3 (length (funcall sent "operator ping"))))
          (should (equal "fake/other" (plist-get (fleet-store-get store "runtimes" rid) :model)))
          (should (= 1 (funcall events "model-fallback" rid)))
          ;; the task's own request is untouched: a later operator starts on the preferred model again
          (should-not (plist-get (fleet-store-get store "tasks" tid) :model))
          (fleet-test-fake-finish oconn nil t) (fleet-sup-test-settle)
          (should (= 3 (length (funcall sent "operator ping"))))
          (should (equal "finished" (funcall state "operator ping")))
          (should (= 1 (fleet-store-scalar store "SELECT COUNT(*) FROM events WHERE kind = 'turn-empty' AND actionable = 1 AND runtime_id = ?" rid)))))
      ;; a fallback ECA does not offer is not tried: the failure is surfaced directly
      (fleet-test-write-config :models "{\"fallback\": {\"fake/other\": \"fake/unknown\"}}")
      (fleet-supervisor--human-sink conn '(:text "once more"))
      (fleet-sup-test-settle)
      (fleet-test-fake-finish conn "Error: still down" t) (fleet-sup-test-settle)
      (should (= 1 (length (funcall sent "once more"))))
      (should (equal "finished" (funcall state "once more")))
      (should (= 2 (funcall events "turn-failed")))
      (should (equal "fake/other" (plist-get (fleet-store-get store "runtimes" cid) :model))))))

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
