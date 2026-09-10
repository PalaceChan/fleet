;;; fleet-rpc-tests.el --- Tests for the local RPC socket -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)
(require 'fleet-rpc)
(require 'fleet-supervisor-tests)

(defun fleet-rpc-test-call (raw &optional timeout)
  "Send RAW text to the socket and return the first reply line parsed (or raw string on parse failure)."
  (let* ((out "") (done nil)
         (proc (make-network-process :name "fleet-rpc-test" :family 'local :service (fleet-paths-socket) :noquery t
                                     :coding 'utf-8-unix
                                     :filter (lambda (_p s) (setq out (concat out s)) (when (string-match-p "\n" out) (setq done t)))
                                     :sentinel (lambda (_p _e) (setq done t)))))
    (process-send-string proc raw)
    (fleet-test-wait-for (lambda () done) (or timeout 10))
    (ignore-errors (delete-process proc))
    (or (ignore-errors (fleet-store-unjson (car (split-string out "\n" t)))) out)))

(defun fleet-rpc-test-req (operation &optional credential params key)
  "Call OPERATION with CREDENTIAL, PARAMS plist and idempotency KEY; return the parsed reply."
  (fleet-rpc-test-call (concat (fleet-store-json (append (list :protocolVersion 1 :id (fleet-paths-uuid) :operation operation :params (or params (make-hash-table)))
                                                         (and credential (list :credential credential))
                                                         (and key (list :idempotencyKey key))))
                               "\n")))

(defun fleet-rpc-test-token (runtime-id)
  "Read the credential token of RUNTIME-ID."
  (plist-get (fleet-store-unjson (fleet-paths-read-file (fleet-paths-credential-file runtime-id))) :token))

(defmacro fleet-rpc-test-with (&rest body)
  "Supervisor fakes plus a live RPC server."
  (declare (indent 0))
  `(fleet-sup-test-with
     (fleet-rpc-start)
     (unwind-protect (progn ,@body)
       (fleet-rpc-stop))))

(defun fleet-rpc-test-err (reply) "Error code string of REPLY or nil." (plist-get (plist-get reply :error) :code))

(ert-deftest fleet-rpc-socket-permissions-and-framing ()
  (fleet-rpc-test-with
    (should (= #o600 (file-modes (fleet-paths-socket))))
    (should (= #o700 (file-modes (fleet-paths-runtime-root))))
    (should (eq t (plist-get (plist-get (fleet-rpc-test-req "ping") :result) :ok)))
    (should (equal "invalid-request" (fleet-rpc-test-err (fleet-rpc-test-call "not json\n"))))
    (should (equal "invalid-request" (fleet-rpc-test-err (fleet-rpc-test-call "{\"protocolVersion\":2,\"id\":1,\"operation\":\"ping\",\"params\":{}}\n"))))
    (should (equal "unauthenticated" (fleet-rpc-test-err (fleet-rpc-test-req "tools_list"))))
    (should (equal "unknown-operation" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_nope" "x"))))
    ;; oversize request refused explicitly
    (let ((fleet-rpc-max-line-bytes 2000))
      (should (equal "invalid-request" (fleet-rpc-test-err (fleet-rpc-test-call (concat (make-string 3000 ?a) "\n"))))))))

(ert-deftest fleet-rpc-role-scoped-tools-and-authority ()
  (fleet-rpc-test-with
    (let* ((fid (fleet-core-test-fleet store)) (cid (fleet-sup-test-commander store fid))
           (t1 (plist-get (fleet-core-test-study store fid "one") :id))
           (t2 (plist-get (fleet-core-test-study store fid "two") :id)))
      (fleet-core-test-start store t1) (fleet-core-test-start store t2)
      (let* ((ctok (fleet-rpc-test-token cid))
             (otok (fleet-rpc-test-token (fleet-core-test-runtime store t1)))
             (ctools (mapcar (lambda (tl) (plist-get tl :name)) (append (plist-get (plist-get (fleet-rpc-test-req "tools_list" ctok) :result) :tools) nil)))
             (otools (mapcar (lambda (tl) (plist-get tl :name)) (append (plist-get (plist-get (fleet-rpc-test-req "tools_list" otok) :result) :tools) nil))))
        (should (member "fleet_task_create" ctools))
        (should-not (member "fleet_status" ctools))
        (should (member "fleet_status" otools))
        (should-not (member "fleet_task_create" otools))
        (should-not (member "fleet_task_teardown" otools))
        ;; operator cannot use commander tools even by name
        (should (equal "forbidden" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_task_create" otok '(:name "x" :kind "study" :brief "b") "k"))))
        ;; operator status with Unicode/multiline detail roundtrips
        (let ((r (fleet-rpc-test-req "fleet_status" otok '(:phase "working" :detail "línea 1\nlínea 2 — ünicode"))))
          (should (eq t (plist-get (plist-get r :result) :ok)))
          (should (string-match-p "ünicode" (plist-get (fleet-store-get store "tasks" t1) :detail))))
        ;; operator artifact registration lands on its own task regardless of task_id
        (let ((r (fleet-rpc-test-req "fleet_artifact_register" otok (list :kind "report" :rel_path "report.md" :task_id t2) "a1")))
          (should (equal t1 (plist-get (plist-get r :result) :task-id))))
        ;; schema validation
        (should (equal "invalid-request" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_status" otok '(:phase "flying")))))
        (should (equal "invalid-request" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_status" otok '(:detail "no phase")))))
        (should (equal "invalid-request" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_status" otok '(:phase "working" :bogus 1)))))
        ;; commander sibling control through another fleet's task is refused
        (let* ((f2 (fleet-core-test-fleet store "other")) (t3 (plist-get (fleet-core-test-study store f2 "three") :id)))
          (should (equal "forbidden" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_task_start" ctok (list :task_id t3) "s1")))))
        ;; revoked credential is stale (token captured before the file is removed)
        (let ((tok2 (fleet-rpc-test-token (fleet-core-test-runtime store t2))))
          (fleet-core-revoke-credential store (fleet-core-test-runtime store t2))
          (should (equal "stale-runtime" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_snapshot" tok2))))
          (should (equal "unauthenticated" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_snapshot" "never-issued")))))))))

(ert-deftest fleet-rpc-commander-flow-create-start-events-ack ()
  (fleet-rpc-test-with
    (let* ((fid (fleet-core-test-fleet store)) (cid (fleet-sup-test-commander store fid))
           (ctok (fleet-rpc-test-token cid)))
      (fleet-sup-test-settle)
      (let* ((r (fleet-rpc-test-req "fleet_task_create" ctok (list :name "parser" :kind "study" :brief fleet-test-brief) "c1"))
             (tid (plist-get (plist-get r :result) :task-id)))
        (should tid)
        ;; replay with same key and payload returns the same task without creating another
        (should (plist-get (plist-get (fleet-rpc-test-req "fleet_task_create" ctok (list :name "parser" :kind "study" :brief fleet-test-brief) "c1") :result) :replayed))
        (should (= 1 (fleet-store-scalar store "SELECT COUNT(*) FROM tasks WHERE fleet_id = ?" fid)))
        ;; same key, different payload refused
        (should (equal "action-payload-mismatch" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_task_create" ctok (list :name "other" :kind "study" :brief fleet-test-brief) "c1"))))
        ;; start requires idempotency key; returns an operation id; replay returns the same
        (should (equal "invalid-request" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_task_start" ctok (list :task_id tid)))))
        (let* ((s1 (plist-get (fleet-rpc-test-req "fleet_task_start" ctok (list :task_id tid) "s1") :result))
               (s2 (plist-get (fleet-rpc-test-req "fleet_task_start" ctok (list :task_id tid) "s1") :result)))
          (should (plist-get s1 :operation-id))
          (should (equal (plist-get s1 :operation-id) (plist-get s2 :operation-id)))
          (fleet-test-wait-op store (plist-get s1 :operation-id))
          (should (equal "done" (plist-get (plist-get (fleet-rpc-test-req "fleet_operation" ctok (list :operation_id (plist-get s1 :operation-id))) :result) :state))))
        ;; operator raises a decision; commander sees it pending, resolves, sends, acks
        (setq fleet-test-fake-turn 'busy)
        (let* ((otok (fleet-rpc-test-token (fleet-core-test-runtime store tid)))
               (st (plist-get (fleet-rpc-test-req "fleet_status" otok '(:phase "needs-decision" :detail "?" :decision (:question "A or B?" :options ["A" "B"] :recommendation "A"))) :result))
               (pending (plist-get (fleet-rpc-test-req "fleet_events_pending" ctok) :result))
               (ev (cl-find-if (lambda (e) (equal (plist-get e :kind) "decision-requested")) (append (plist-get pending :events) nil))))
          (should ev)
          (should (equal (plist-get st :decision-id) (plist-get (plist-get ev :payload) :decision-id)))
          ;; reading twice does not acknowledge
          (should (= 1 (length (append (plist-get (plist-get (fleet-rpc-test-req "fleet_events_pending" ctok) :result) :events) nil))))
          (should (eq t (plist-get (plist-get (fleet-rpc-test-req "fleet_decision_resolve" ctok (list :decision_id (plist-get st :decision-id) :answer "A") "d1") :result) :ok)))
          (let ((m (plist-get (fleet-rpc-test-req "fleet_message_send" ctok (list :task_id tid :text "Answer: A") "m1") :result)))
            (should (member (plist-get m :state) '("queued" "dispatching" "accepted" "turn-observed"))))
          (let ((a (plist-get (fleet-rpc-test-req "fleet_events_ack" ctok (list :event_ids (vector (plist-get ev :event-id)) :disposition "answered A") "k1") :result)))
            (should (= 1 (plist-get a :acknowledged))))
          (should (= 0 (length (cl-remove-if-not (lambda (e) (equal (plist-get e :kind) "decision-requested"))
                                                 (append (plist-get (plist-get (fleet-rpc-test-req "fleet_events_pending" ctok) :result) :events) nil)))))
          ;; snapshot scoped to the fleet
          (let ((snap (plist-get (fleet-rpc-test-req "fleet_snapshot" ctok) :result)))
            (should (= 1 (length (append (plist-get snap :fleets) nil))))
            (should (equal "parser" (plist-get (car (append (plist-get (car (append (plist-get snap :fleets) nil)) :tasks) nil)) :name)))))))))

(ert-deftest fleet-rpc-retask-failed-task-with-live-runtime-returns-operation ()
  "The commander's fleet_task_retask on a failed task whose operator is idle
returns an operation id (runtime stop first) and later a task-retasked wake."
  (fleet-rpc-test-with
    (let* ((fid (fleet-core-test-fleet store)) (cid (fleet-sup-test-commander store fid))
           (ctok (fleet-rpc-test-token cid)))
      (fleet-sup-test-settle)
      (let* ((tid (plist-get (plist-get (fleet-rpc-test-req "fleet_task_create" ctok (list :name "clone" :kind "ops" :brief fleet-test-brief :resources ["clone-x"]) "c1") :result) :task-id))
             (s1 (plist-get (fleet-rpc-test-req "fleet_task_start" ctok (list :task_id tid) "s1") :result)))
        (fleet-test-wait-op store (plist-get s1 :operation-id))
        (let* ((rt (fleet-core-test-runtime store tid)) (otok (fleet-rpc-test-token rt)))
          (fleet-test-wait-for (lambda () (null (fleet-eca-conn-turn (fleet-eca-conn rt)))) 5)
          (fleet-rpc-test-req "fleet_status" otok '(:phase "failed" :detail "source is not a git root"))
          ;; a replacement for the same resource is refused with the holder
          (let ((r (fleet-rpc-test-req "fleet_task_create" ctok (list :name "clone-2" :kind "ops" :brief fleet-test-brief :resources ["clone-x"]) "c2")))
            (should (equal "resource-claimed" (fleet-rpc-test-err r))))
          ;; a model outside the catalog is refused before anything is stopped
          (should (equal "unknown-model" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_task_retask" ctok (list :task_id tid :brief "" :model "nope/model") "r0"))))
          (should (equal "ready" (plist-get (fleet-store-get store "runtimes" rt) :lifecycle)))
          ;; retask (with a user-requested model/variant) stops the idle runtime as an operation; completion is a wake event
          (let* ((r (plist-get (fleet-rpc-test-req "fleet_task_retask" ctok (list :task_id tid :brief "Corrected scope: use the real repository root." :note "fix" :model "fake/other" :variant "low") "r1") :result)))
            (should (plist-get r :operation-id))
            (should (equal "done" (plist-get (fleet-test-wait-op store (plist-get r :operation-id)) :state))))
          (should (equal "stopped" (plist-get (fleet-store-get store "runtimes" rt) :lifecycle)))
          (should (equal "ready" (plist-get (fleet-store-get store "tasks" tid) :lifecycle)))
          (should (equal "fake/other" (plist-get (fleet-store-get store "tasks" tid) :model)))
          (should (equal "low" (plist-get (fleet-store-get store "tasks" tid) :variant)))
          (should (cl-some (lambda (e) (equal (plist-get e :kind) "task-retasked"))
                           (append (plist-get (plist-get (fleet-rpc-test-req "fleet_events_pending" ctok) :result) :events) nil)))
          ;; and the task starts again on a fresh runtime, on the requested model/variant
          (let ((s2 (plist-get (fleet-rpc-test-req "fleet_task_start" ctok (list :task_id tid) "s2") :result)))
            (should (equal "done" (plist-get (fleet-test-wait-op store (plist-get s2 :operation-id)) :state))))
          (should-not (equal rt (fleet-core-test-runtime store tid)))
          (let ((rt2 (fleet-store-get store "runtimes" (fleet-core-test-runtime store tid))))
            (should (equal "fake/other" (plist-get rt2 :model)))
            (should (equal "low" (plist-get rt2 :variant)))))))))

(provide 'fleet-rpc-tests)
;;; fleet-rpc-tests.el ends here
