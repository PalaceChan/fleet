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
        ;; 2026-09-17: every operator first sent the decision fields at the top level and was
        ;; refused with "unexpected parameter :question"; that shape now folds under `decision'.
        (let ((r (fleet-rpc-test-req "fleet_status" otok '(:phase "needs-decision" :detail "flat" :question "A or B?" :options ["A" "B"] :recommendation "A" :authority "human"))))
          (should (plist-get (plist-get r :result) :decision-id))
          (let* ((did (plist-get (plist-get r :result) :decision-id))
                 (d (fleet-store-get store "decisions" did)))
            (should (equal "A or B?" (plist-get d :question)))
            (should (equal "human" (plist-get d :authority)))
            ;; human authority: refused as a commander ruling, accepted as a relay of the owner's answer
            (should (equal "forbidden" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_decision_resolve" ctok (list :decision_id did :answer "A") "h1"))))
            (should (eq t (plist-get (plist-get (fleet-rpc-test-req "fleet_decision_resolve" ctok (list :decision_id did :answer "A" :owner_approved t) "h2") :result) :ok)))
            (let ((d2 (fleet-store-get store "decisions" did)))
              (should (equal "resolved" (plist-get d2 :state)))
              (should (eq t (plist-get (fleet-store-unjson (plist-get d2 :evidence)) :owner-relayed))))
            (should (equal "human" (plist-get (fleet-store-unjson (plist-get (car (fleet-store-query store "SELECT * FROM events WHERE kind = 'decision-resolved' ORDER BY seq DESC LIMIT 1")) :payload)) :authority)))))
        ;; ...but only when `decision' is absent; a mixed shape is still a schema error
        (should (equal "invalid-request" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_status" otok '(:phase "needs-decision" :decision (:question "q") :question "q2")))))
        ;; commander sibling control through another fleet's task is refused
        (let* ((f2 (fleet-core-test-fleet store "other")) (t3 (plist-get (fleet-core-test-study store f2 "three") :id)))
          (should (equal "forbidden" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_task_start" ctok (list :task_id t3) "s1")))))
        ;; revoked credential is stale (token captured before the file is removed)
        (let ((tok2 (fleet-rpc-test-token (fleet-core-test-runtime store t2))))
          (fleet-core-revoke-credential store (fleet-core-test-runtime store t2))
          (should (equal "stale-runtime" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_snapshot" tok2))))
          (should (equal "unauthenticated" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_snapshot" "never-issued")))))))))

(ert-deftest fleet-rpc-root-commander-relays-the-humans-answer-into-a-lieutenants-decision ()
  "Lieutenant fleet 2026-09-19: a lieutenant's operator raised human-authority
decisions; the lieutenant was refused `owner_approved' (its user is the
commander) and the root commander was refused by fleet scope, so ten rows
stayed open after the human had answered.  The root commander now relays the
human's answer into its lieutenant's human-authority row; the row and event
record human authority by relay, the relaying commander and the lieutenant
fleet; the event is actionable for the lieutenant, which delivers.  Both
original refusals still hold, as do an unrelated commander, an operator, a
stale revision, a duplicate and a commander-authority row."
  (fleet-rpc-test-with
    (let* ((rid (fleet-core-test-fleet store "workshop"))
           (lid (plist-get (fleet-core-create-fleet store "frontend" :parent-id rid :charter "UI") :id))
           (other (fleet-core-test-fleet store "other"))
           (root-cid (fleet-sup-test-commander store rid))
           (lt-cid (fleet-sup-test-commander store lid))
           (other-cid (fleet-sup-test-commander store other))
           (tid (plist-get (fleet-core-test-study store lid "nav") :id)))
      (fleet-sup-test-settle)
      (fleet-core-test-start store tid)
      (let* ((rtok (fleet-rpc-test-token root-cid)) (ltok (fleet-rpc-test-token lt-cid)) (xtok (fleet-rpc-test-token other-cid))
             (otok (fleet-rpc-test-token (fleet-core-test-runtime store tid))))
        (setq fleet-test-fake-turn 'busy)
        (let* ((st (plist-get (fleet-rpc-test-req "fleet_status" otok '(:phase "needs-decision" :detail "?" :decision (:question "Delete the old branch?" :options ["yes" "no"] :recommendation "no" :authority "human"))) :result))
               (did (plist-get st :decision-id))
               (cst (plist-get (fleet-rpc-test-req "fleet_status" otok '(:phase "needs-decision" :detail "?" :decision (:question "Tabs or spaces?" :authority "commander"))) :result))
               (cdid (plist-get cst :decision-id))
               (rev (plist-get (fleet-store-get store "tasks" tid) :entity-revision))
               (open-p (lambda (id) (equal "open" (plist-get (fleet-store-get store "decisions" id) :state)))))
          (should (and did cdid))
          ;; Incident refusal 1: the lieutenant may not assert owner_approved; nor rule on a human row.
          (should (equal "forbidden" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_decision_resolve" ltok (list :decision_id did :answer "no" :owner_approved t) "l1"))))
          (should (equal "forbidden" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_decision_resolve" ltok (list :decision_id did :answer "no") "l2"))))
          ;; Incident refusal 2: the root commander without the human's answer is out of scope.
          (should (equal "forbidden" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_decision_resolve" rtok (list :decision_id did :answer "no") "r1"))))
          ;; An unrelated root, an operator, and the lieutenant's commander-authority row from the root.
          (should (equal "forbidden" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_decision_resolve" xtok (list :decision_id did :answer "no" :owner_approved t) "x1"))))
          (should (equal "forbidden" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_decision_resolve" otok (list :decision_id did :answer "no" :owner_approved t) "o1"))))
          (should (equal "forbidden" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_decision_resolve" rtok (list :decision_id cdid :answer "tabs" :owner_approved t) "r2"))))
          ;; A stale revision is refused before anything changes.
          (should (equal "revision-mismatch" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_decision_resolve" rtok (list :decision_id did :answer "no" :owner_approved t :expected_revision (1+ rev)) "r3"))))
          (should (funcall open-p did))
          (should (= 0 (fleet-store-scalar store "SELECT COUNT(*) FROM events WHERE kind = 'decision-resolved'")))
          ;; The sanctioned path: the root relays the human's answer with owner_approved.
          (let ((r (plist-get (fleet-rpc-test-req "fleet_decision_resolve" rtok (list :decision_id did :answer "no — keep it" :owner_approved t :evidence "user said no in chat" :expected_revision rev) "r4") :result)))
            (should (eq t (plist-get r :ok)))
            (should (equal lid (plist-get r :fleet-id)))
            (should (equal "human" (plist-get r :authority)))
            (should (equal "frontend" (plist-get r :lieutenant)))
            (should (string-match-p "separate" (plist-get r :delivery))))
          (let* ((d (fleet-store-get store "decisions" did)) (ev (fleet-store-unjson (plist-get d :evidence))))
            (should (equal "resolved" (plist-get d :state)))
            (should (equal "no — keep it" (plist-get d :answer)))
            (should (equal (fleet-core-actor-commander rid) (plist-get d :resolved-by)))
            (should (eq t (plist-get ev :owner-relayed)))
            (should (equal root-cid (plist-get ev :relayed-by-runtime)))
            (should (equal rid (plist-get ev :relayed-by-fleet)))
            (should (equal lid (plist-get ev :lieutenant-fleet-id)))
            (should (equal "user said no in chat" (plist-get ev :text))))
          ;; The event lives in the lieutenant's fleet, names the relay, and is actionable there only.
          (let* ((e (car (fleet-store-query store "SELECT * FROM events WHERE kind = 'decision-resolved'")))
                 (payload (fleet-store-unjson (plist-get e :payload))))
            (should (equal lid (plist-get e :fleet-id)))
            (should (eql 1 (plist-get e :actionable)))
            (should (equal "human" (plist-get payload :authority)))
            (should (equal (fleet-core-actor-commander rid) (plist-get payload :resolved-by)))
            (should (equal root-cid (plist-get (plist-get payload :evidence) :relayed-by-runtime)))
            (should (= 1 (fleet-store-scalar store "SELECT COUNT(*) FROM event_receipts WHERE event_id = ? AND fleet_id = ?" (plist-get e :id) lid)))
            (should (cl-find (plist-get e :id) (append (plist-get (plist-get (fleet-rpc-test-req "fleet_events_pending" ltok) :result) :events) nil)
                             :key (lambda (x) (plist-get x :event-id)) :test #'equal))
            (should-not (cl-find (plist-get e :id) (append (plist-get (plist-get (fleet-rpc-test-req "fleet_events_pending" rtok) :result) :events) nil)
                                 :key (lambda (x) (plist-get x :event-id)) :test #'equal)))
          ;; Duplicate: same key replays, a new key is refused as closed.
          (should (eq t (plist-get (plist-get (fleet-rpc-test-req "fleet_decision_resolve" rtok (list :decision_id did :answer "no — keep it" :owner_approved t :evidence "user said no in chat" :expected_revision rev) "r4") :result) :ok)))
          (should (equal "decision-closed" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_decision_resolve" rtok (list :decision_id did :answer "yes" :owner_approved t) "r5"))))
          (should (= 1 (fleet-store-scalar store "SELECT COUNT(*) FROM events WHERE kind = 'decision-resolved'")))
          ;; The lieutenant's own commander-authority row is still its own, and resolving it wakes nobody.
          (should (eq t (plist-get (plist-get (fleet-rpc-test-req "fleet_decision_resolve" ltok (list :decision_id cdid :answer "spaces") "l3") :result) :ok)))
          (should (= 1 (fleet-store-scalar store "SELECT COUNT(*) FROM events WHERE kind = 'decision-resolved' AND actionable = 1"))))))))

(ert-deftest fleet-rpc-lieutenant-reports-a-verified-result-before-teardown-over-the-socket ()
  "The report guardrail on the wire: a lieutenant's fleet_task_teardown of a
verified, unreported task on an open request is refused `report-pending';
fleet_report accepts `task_ids' as an array (and refuses another shape), and
after it the same teardown call is admitted."
  (fleet-rpc-test-with
    (let* ((rid (fleet-core-test-fleet store "workshop"))
           (lid (plist-get (fleet-core-create-fleet store "frontend" :parent-id rid :charter "UI") :id))
           (root-cid (fleet-sup-test-commander store rid))
           (lt-cid (fleet-sup-test-commander store lid)))
      (fleet-sup-test-settle)
      (let* ((ltok (fleet-rpc-test-token lt-cid))
             (req (plist-get (plist-get (fleet-rpc-test-req "fleet_delegate" (fleet-rpc-test-token root-cid) (list :lieutenant "frontend" :subject "nav" :text "Goal: nav") "d1") :result) :request-id))
             (tid (fleet-core-test-verified-study store lid "nav"))
             (report-tool (cl-find "fleet_report" (append (plist-get (plist-get (fleet-rpc-test-req "tools_list" ltok) :result) :tools) nil)
                                   :key (lambda (tl) (plist-get tl :name)) :test #'equal)))
        (should req)
        (should (plist-get (plist-get (plist-get report-tool :inputSchema) :properties) :task_ids))
        (let ((err (plist-get (fleet-rpc-test-req "fleet_task_teardown" ltok (list :task_id tid) "t1") :error)))
          (should (equal "report-pending" (plist-get err :code)))
          (should (equal (vector req) (plist-get (plist-get err :evidence) :open-requests))))
        (should (equal "invalid-request" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_report" ltok (list :kind "progress" :text "nav verified" :request_id req :task_ids "nav") "p0"))))
        (let ((r (plist-get (fleet-rpc-test-req "fleet_report" ltok (list :kind "progress" :text "nav verified" :request_id req :task_ids (vector "nav")) "p1") :result)))
          (should (equal "open" (plist-get r :state)))
          (should (equal "nav" (plist-get (aref (plist-get r :tasks) 0) :name))))
        (let ((op (plist-get (plist-get (fleet-rpc-test-req "fleet_task_teardown" ltok (list :task_id tid) "t1") :result) :operation-id)))
          (should op)
          (should (equal "done" (plist-get (fleet-test-wait-op store op) :state))))
        (should (equal "open" (plist-get (fleet-store-get store "requests" req) :state)))))))

(ert-deftest fleet-rpc-external-job-refuses-another-tasks-job-id ()
  "F04: over the socket, an operator naming a sibling task's job id gets
`forbidden'; the sibling's record and its events are untouched, while the
owner's own update succeeds."
  (fleet-rpc-test-with
    (let* ((fid (fleet-core-test-fleet store))
           (t1 (plist-get (fleet-core-test-study store fid "one") :id))
           (t2 (plist-get (fleet-core-test-study store fid "two") :id)))
      (fleet-core-test-start store t1) (fleet-core-test-start store t2)
      (let* ((tok1 (fleet-rpc-test-token (fleet-core-test-runtime store t1)))
             (tok2 (fleet-rpc-test-token (fleet-core-test-runtime store t2)))
             (r (fleet-rpc-test-req "fleet_external_job" tok1 '(:system "ci" :job_ref "run/1" :state "running") "j1"))
             (jid (plist-get (plist-get r :result) :job-id)))
        (should jid)
        (let ((before (fleet-store-get store "external_jobs" jid))
              (events (fleet-store-scalar store "SELECT COUNT(*) FROM events WHERE kind = 'external-job'")))
          (should (equal "forbidden" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_external_job" tok2 (list :job_id jid :state "cancelled") "j2"))))
          (should (equal before (fleet-store-get store "external_jobs" jid)))
          (should (= events (fleet-store-scalar store "SELECT COUNT(*) FROM events WHERE kind = 'external-job'"))))
        (should (eq t (plist-get (plist-get (fleet-rpc-test-req "fleet_external_job" tok1 (list :job_id jid :state "completed") "j3") :result) :ok)))
        (should (equal "completed" (plist-get (fleet-store-get store "external_jobs" jid) :state)))))))

(ert-deftest fleet-rpc-wait-returns-terminal-job-state-and-refuses-bad-deadlines ()
  "openclaw 2026-09-19: over the socket, `fleet_wait' on one's own external job
that is already terminal does not pause and answers with the job's state and
disposition; a deadline beyond the maximum or not ISO-8601 is refused with a
stable code; another task's job id is `forbidden'.  `fleet_status paused'
follows the same rules through the same core path."
  (fleet-rpc-test-with
    (let* ((fleet-wait-deadline-max-sec 3600)
           (fid (fleet-core-test-fleet store))
           (t1 (plist-get (fleet-core-test-study store fid "one") :id))
           (t2 (plist-get (fleet-core-test-study store fid "two") :id)))
      (fleet-core-test-start store t1) (fleet-core-test-start store t2)
      (let* ((tok1 (fleet-rpc-test-token (fleet-core-test-runtime store t1)))
             (tok2 (fleet-rpc-test-token (fleet-core-test-runtime store t2)))
             (soon (fleet-core-test-iso 600))
             (jid (plist-get (plist-get (fleet-rpc-test-req "fleet_external_job" tok1 '(:system "ci" :job_ref "run/1" :state "running") "j1") :result) :job-id)))
        (should jid)
        ;; running: pauses as declared
        (let ((r (plist-get (fleet-rpc-test-req "fleet_wait" tok1 (list :reason "CI run 1" :deadline soon :job_id jid)) :result)))
          (should (equal "paused" (plist-get r :phase)))
          (should (equal "paused" (plist-get (fleet-store-get store "tasks" t1) :phase)))
          (should (equal jid (plist-get (fleet-store-get store "tasks" t1) :wait-job-id))))
        (fleet-rpc-test-req "fleet_status" tok1 '(:phase "working" :detail "result read"))
        ;; completed: the tool answers instead of parking the task
        (should (eq t (plist-get (plist-get (fleet-rpc-test-req "fleet_external_job" tok1 (list :job_id jid :state "completed" :disposition "merged") "j2") :result) :ok)))
        (let ((r (plist-get (fleet-rpc-test-req "fleet_wait" tok1 (list :reason "CI run 1" :deadline soon :job_id jid)) :result)))
          (should (eq t (plist-get r :ok)))
          (should (eq :false (plist-get r :paused)))
          (should (equal "working" (plist-get r :phase)))
          (should (equal "completed" (plist-get r :job-state)))
          (should (equal "merged" (plist-get r :disposition)))
          (should (string-match-p "already completed" (plist-get r :message))))
        (should (equal "working" (plist-get (fleet-store-get store "tasks" t1) :phase)))
        (let ((r (plist-get (fleet-rpc-test-req "fleet_status" tok1 (list :phase "paused" :detail "waiting" :wait (list :reason "CI run 1" :deadline soon :job_id jid))) :result)))
          (should (eq :false (plist-get r :paused)))
          (should (equal "completed" (plist-get r :job-state))))
        (should (equal "working" (plist-get (fleet-store-get store "tasks" t1) :phase)))
        ;; refusals: deadline bound, malformed deadline, another task's job
        (should (equal "wait-deadline-too-far" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_wait" tok1 (list :reason "long" :deadline (fleet-core-test-iso (* 2 3600)))))))
        (should (equal "wait-deadline-too-far" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_status" tok1 (list :phase "paused" :wait (list :reason "long" :deadline (fleet-core-test-iso (* 2 3600))))))))
        (should (equal "invalid-wait" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_wait" tok1 '(:reason "bad" :deadline "in 14 minutes")))))
        (should (equal "forbidden" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_wait" tok2 (list :reason "theirs" :deadline soon :job_id jid)))))
        (should (equal "working" (plist-get (fleet-store-get store "tasks" t1) :phase)))
        (should-not (equal "paused" (plist-get (fleet-store-get store "tasks" t2) :phase)))
        (should (= 0 (fleet-store-scalar store "SELECT COUNT(*) FROM events WHERE kind = 'task-paused' AND task_id = ?" t2)))
        ;; the refusals are visible in telemetry with their codes
        (should (= 1 (fleet-store-scalar store "SELECT COUNT(*) FROM events WHERE kind = 'tool-call' AND payload LIKE '%\"code\":\"invalid-wait\"%'")))
        (should (= 2 (fleet-store-scalar store "SELECT COUNT(*) FROM events WHERE kind = 'tool-call' AND payload LIKE '%\"code\":\"wait-deadline-too-far\"%'")))))))

(ert-deftest fleet-rpc-brief-path-reads-a-file-under-the-fleet-directory ()
  "Live run 2026-09-17: a commander could not fit a 6k brief and the other
arguments into one tool call.  brief_path keeps the call small; the file must
be the commander's own (under its fleet directory) and exactly one of the two
forms is accepted."
  (fleet-rpc-test-with
    (let* ((fid (fleet-core-test-fleet store)) (cid (fleet-sup-test-commander store fid))
           (ctok (fleet-rpc-test-token cid))
           (root (plist-get (fleet-store-get store "fleets" fid) :artifact-root))
           (rel "commander/briefs/parser.md")
           (file (expand-file-name rel root))
           (outside (expand-file-name "outside-brief.md" fleet-test--roots)))
      (fleet-sup-test-settle)
      (make-directory (file-name-directory file) t)
      (fleet-test-write file (concat fleet-test-brief "\nfrom file\n"))
      (fleet-test-write outside fleet-test-brief)
      ;; neither form: refused by Fleet (the schema no longer hard-requires brief, so the refusal is ours and logged)
      (should (equal "invalid-request" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_task_create" ctok (list :name "parser" :kind "study" :model_reason "test default") "k0"))))
      ;; both forms: refused
      (should (equal "invalid-request" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_task_create" ctok (list :name "parser" :kind "study" :model_reason "test default" :brief fleet-test-brief :brief_path rel) "k1"))))
      ;; a file outside the fleet directory, or missing: refused, nothing created
      (should (equal "invalid-request" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_task_create" ctok (list :name "parser" :kind "study" :model_reason "test default" :brief_path outside) "k2"))))
      (should (equal "invalid-request" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_task_create" ctok (list :name "parser" :kind "study" :model_reason "test default" :brief_path "commander/briefs/nope.md") "k3"))))
      (should (= 0 (fleet-store-scalar store "SELECT COUNT(*) FROM tasks WHERE fleet_id = ?" fid)))
      (should (= 4 (fleet-store-scalar store "SELECT COUNT(*) FROM events WHERE kind = 'tool-call' AND payload LIKE '%\"outcome\":\"refused\"%'")))
      ;; relative to the fleet directory: the brief is the file's text, copied into the task's revision
      (let* ((r (fleet-rpc-test-req "fleet_task_create" ctok (list :name "parser" :kind "study" :model_reason "test default" :brief_path rel) "k4"))
             (tid (plist-get (plist-get r :result) :task-id)))
        (should tid)
        (should (string-match-p "from file" (fleet-paths-read-file (fleet-core-brief-file store (fleet-store-get store "tasks" tid)))))
        (should (file-exists-p file))
        ;; absolute path under the fleet directory works the same for a retask
        (fleet-test-write file (concat fleet-test-brief "\nsecond scope\n"))
        (let ((r2 (fleet-rpc-test-req "fleet_task_retask" ctok (list :task_id tid :brief_path file) "k5")))
          (should (= 2 (plist-get (plist-get r2 :result) :brief-revision)))
          (should (string-match-p "second scope" (fleet-paths-read-file (fleet-core-brief-file store (fleet-store-get store "tasks" tid))))))
        ;; retask with neither form only changes model/variant (empty scope) and is still accepted
        (should (plist-get (fleet-rpc-test-req "fleet_task_retask" ctok (list :task_id tid :variant "low") "k6") :result))))))

(ert-deftest fleet-rpc-commander-flow-create-start-events-ack ()
  (fleet-rpc-test-with
    (let* ((fid (fleet-core-test-fleet store)) (cid (fleet-sup-test-commander store fid))
           (ctok (fleet-rpc-test-token cid)))
      (fleet-sup-test-settle)
      (let* ((r (fleet-rpc-test-req "fleet_task_create" ctok (list :name "parser" :kind "study" :model_reason "test default" :brief fleet-test-brief) "c1"))
             (tid (plist-get (plist-get r :result) :task-id)))
        (should tid)
        ;; replay with same key and payload returns the same task without creating another
        (should (plist-get (plist-get (fleet-rpc-test-req "fleet_task_create" ctok (list :name "parser" :kind "study" :model_reason "test default" :brief fleet-test-brief) "c1") :result) :replayed))
        (should (= 1 (fleet-store-scalar store "SELECT COUNT(*) FROM tasks WHERE fleet_id = ?" fid)))
        ;; same key, different payload refused
        (should (equal "action-payload-mismatch" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_task_create" ctok (list :name "other" :kind "study" :model_reason "test default" :brief fleet-test-brief) "c1"))))
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

(ert-deftest fleet-rpc-operator-can-read-its-own-cleanup-evidence ()
  "openclaw 2026-09-10: teardown refused on two untracked __pycache__ files the
operator left behind.  The operator can now run the same check before `done'
(own task only, task_id ignored) and sees the dirty paths; a study task has
no cleanup evidence."
  (fleet-rpc-test-with
    (let* ((repo (fleet-git-test-repo "rpcproj"))
           (fid (fleet-core-test-fleet store "fl")) (cid (fleet-sup-test-commander store fid))
           (change (plist-get (fleet-core-create-task store fid :name "feat" :kind "change" :brief fleet-test-brief :repo repo :delivery "local-ready") :id))
           (study (plist-get (fleet-core-test-study store fid "look") :id)))
      (fleet-sup-test-settle)
      (fleet-core-test-start store change) (fleet-core-test-start store study)
      (let* ((ws (plist-get (fleet-store-get store "tasks" change) :workspace-path))
             (otok (fleet-rpc-test-token (fleet-core-test-runtime store change)))
             (stok (fleet-rpc-test-token (fleet-core-test-runtime store study)))
             (ctok (fleet-rpc-test-token cid)))
        (should (member "fleet_cleanup_evidence"
                        (mapcar (lambda (tl) (plist-get tl :name)) (append (plist-get (plist-get (fleet-rpc-test-req "tools_list" otok) :result) :tools) nil))))
        (fleet-test-write (expand-file-name "pkg/__pycache__/m.cpython-314.pyc" ws) "bytecode")
        ;; the operator's task_id (even another task's) is ignored: own task only
        (let ((r (plist-get (fleet-rpc-test-req "fleet_cleanup_evidence" otok (list :task_id study)) :result)))
          (should (eq t (plist-get r :dirty)))
          (should (equal ["?? pkg/__pycache__/m.cpython-314.pyc"] (plist-get (plist-get r :status) :paths)))
          (should (cl-some (lambda (s) (string-match-p "__pycache__" s)) (append (plist-get (plist-get r :decision) :refusals) nil))))
        ;; a study operator has nothing to inspect; the commander still needs task_id
        (should (equal "invalid-request" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_cleanup_evidence" stok nil))))
        (should (equal "invalid-request" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_cleanup_evidence" ctok nil))))
        (should (eq t (plist-get (plist-get (fleet-rpc-test-req "fleet_cleanup_evidence" ctok (list :task_id change)) :result) :dirty)))
        ;; cleaned up => clean
        (delete-directory (expand-file-name "pkg" ws) t)
        (should-not (plist-get (plist-get (fleet-rpc-test-req "fleet_cleanup_evidence" otok nil) :result) :dirty))
        ;; 2026-09-17: the owner's delivery change travels through fleet_task_delivery, commander only,
        ;; owner_approved required by schema and honoured by core; the operator never sees the tool
        (should-not (member "fleet_task_delivery"
                            (mapcar (lambda (tl) (plist-get tl :name)) (append (plist-get (plist-get (fleet-rpc-test-req "tools_list" otok) :result) :tools) nil))))
        (should (equal "invalid-request" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_task_delivery" ctok (list :task_id change :delivery "integrated") "dl1"))))
        (should (equal "delivery-needs-approval" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_task_delivery" ctok (list :task_id change :delivery "integrated" :owner_approved :false) "dl2"))))
        (should (equal "delivery-needs-remote" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_task_delivery" ctok (list :task_id change :delivery "remote-review" :owner_approved t) "dl3"))))
        (should (equal "invalid-task" (fleet-rpc-test-err (fleet-rpc-test-req "fleet_task_delivery" ctok (list :task_id study :delivery "integrated" :owner_approved t) "dl4"))))
        (let ((r (plist-get (fleet-rpc-test-req "fleet_task_delivery" ctok (list :task_id change :delivery "integrated" :owner_approved t :note "owner: merge locally") "dl5") :result)))
          (should (equal "integrated" (plist-get r :delivery)))
          (should (equal "integrated" (plist-get (fleet-store-get store "tasks" change) :delivery-mode))))))))

(ert-deftest fleet-rpc-retask-failed-task-with-live-runtime-returns-operation ()
  "The commander's fleet_task_retask on a failed task whose operator is idle
returns an operation id (runtime stop first) and later a task-retasked wake."
  (fleet-rpc-test-with
    (let* ((fid (fleet-core-test-fleet store)) (cid (fleet-sup-test-commander store fid))
           (ctok (fleet-rpc-test-token cid)))
      (fleet-sup-test-settle)
      (let* ((tid (plist-get (plist-get (fleet-rpc-test-req "fleet_task_create" ctok (list :name "clone" :kind "ops" :model_reason "test default" :brief fleet-test-brief :resources ["clone-x"]) "c1") :result) :task-id))
             (s1 (plist-get (fleet-rpc-test-req "fleet_task_start" ctok (list :task_id tid) "s1") :result)))
        (fleet-test-wait-op store (plist-get s1 :operation-id))
        (let* ((rt (fleet-core-test-runtime store tid)) (otok (fleet-rpc-test-token rt)))
          (fleet-test-wait-for (lambda () (null (fleet-eca-conn-turn (fleet-eca-conn rt)))) 5)
          (fleet-rpc-test-req "fleet_status" otok '(:phase "failed" :detail "source is not a git root"))
          ;; a replacement for the same resource is refused with the holder
          (let ((r (fleet-rpc-test-req "fleet_task_create" ctok (list :name "clone-2" :kind "ops" :model_reason "test default" :brief fleet-test-brief :resources ["clone-x"]) "c2")))
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
