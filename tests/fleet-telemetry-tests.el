;;; fleet-telemetry-tests.el --- Tests for telemetry recording and views -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)
(require 'fleet-telemetry)
(require 'fleet-rpc-tests)

(ert-deftest fleet-telemetry-records-tool-calls-turns-and-latencies ()
  (fleet-rpc-test-with
    (let* ((fid (fleet-core-test-fleet store "tele")) (cid (fleet-sup-test-commander store fid))
           (ctok (fleet-rpc-test-token cid)))
      (fleet-sup-test-settle)
      ;; a successful call, a refusal, and an operator status through the socket
      (let* ((tid (plist-get (plist-get (fleet-rpc-test-req "fleet_task_create" ctok (list :name "t" :kind "study" :brief fleet-test-brief) "c1") :result) :task-id)))
        (fleet-rpc-test-req "fleet_task_start" ctok (list :task_id "nope") "bad")   ; forbidden
        (fleet-test-wait-op store (plist-get (plist-get (fleet-rpc-test-req "fleet_task_start" ctok (list :task_id tid) "s1") :result) :operation-id))
        (let ((otok (fleet-rpc-test-token (fleet-core-test-runtime store tid))))
          (fleet-rpc-test-req "fleet_status" otok '(:phase "blocked" :detail "help")))
        (fleet-supervisor-kick fid 'event) (fleet-sup-test-settle)
        (let* ((ev (car (plist-get (fleet-rpc-test-req "fleet_events_pending" ctok) :result)))
               (pending (append (plist-get (plist-get (fleet-rpc-test-req "fleet_events_pending" ctok) :result) :events) nil))
               (blocked (cl-find-if (lambda (e) (equal (plist-get e :kind) "task-blocked")) pending)))
          (ignore ev)
          (fleet-rpc-test-req "fleet_events_ack" ctok (list :event_ids (vector (plist-get blocked :event-id)) :disposition "handled") "a1"))
        (let ((s (fleet-telemetry-summary store fid)))
          ;; tool calls counted by operation, refusal recorded with code
          (should (>= (cdr (assoc "fleet_task_create" (plist-get s :tool-calls))) 1))
          (should (>= (cdr (assoc "fleet_status" (plist-get s :tool-calls))) 1))
          (should (cl-some (lambda (r) (string-match-p "fleet_task_start: forbidden" (car r))) (plist-get s :refusals)))
          ;; turns finished with durations (boot turns + wake turn)
          (should (>= (plist-get s :turns) 2))
          (should (> (plist-get (plist-get s :turn-seconds) :n) 0))
          ;; latencies computed for the acknowledged receipt
          (should (= 1 (plist-get (plist-get s :event->ack) :n)))
          (should (>= (plist-get s :wakes) 1))
          (should (= 0 (plist-get s :unacknowledged))))
        ;; timeline rows carry task names and latency annotations on actionable events
        (let* ((rows (fleet-telemetry-timeline store fid))
               (blocked-row (cl-find-if (lambda (r) (equal (plist-get r :kind) "task-blocked")) rows)))
          (should (equal (plist-get blocked-row :task) "t"))
          (should (plist-get blocked-row :actionable))
          (should (string-match-p "wake .* · ack " (plist-get blocked-row :latency)))
          (should (cl-some (lambda (r) (and (equal (plist-get r :kind) "tool-call") (string-match-p "forbidden" (plist-get r :summary)))) rows)))
        ;; the commands render without error
        (save-window-excursion
          (fleet-stats "tele") (should (string-match-p "Tool calls" (buffer-string)))
          (fleet-timeline "tele") (should (string-match-p "task-blocked" (buffer-string))))))))

(ert-deftest fleet-telemetry-usage-flows-from-adapter-to-turn-event ()
  (fleet-sup-test-with
    (let* ((fid (fleet-core-test-fleet store))
           (tid (plist-get (fleet-core-test-study store fid) :id)))
      (fleet-core-test-start store tid)
      (let* ((rid (fleet-core-test-runtime store tid)) (conn (fleet-eca-conn rid)))
        (setq fleet-test-fake-turn 'busy)
        (fleet-supervisor-send store :fleet-id fid :task-id tid :runtime-id rid :text "go" :sender "human")
        (fleet-sup-test-settle)
        (let ((turn (fleet-eca-conn-turn conn)))
          (plist-put turn :usage '(:message-input-tokens 120 :message-output-tokens 30 :message-cost 0.01))
          (fleet-eca--emit conn 'turn-idle-observed :message-id (plist-get turn :message-id) :usage (plist-get turn :usage)
                           :submitted-at (plist-get turn :submitted-at))
          (setf (fleet-eca-conn-turn conn) nil))
        (let ((s (fleet-telemetry-summary store fid)))
          (should (= 120 (plist-get s :tokens-in)))
          (should (= 30 (plist-get s :tokens-out)))
          (should (< (abs (- 0.01 (plist-get s :cost))) 1e-9)))))))

(provide 'fleet-telemetry-tests)
;;; fleet-telemetry-tests.el ends here
