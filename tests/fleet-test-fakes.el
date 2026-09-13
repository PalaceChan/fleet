;;; fleet-test-fakes.el --- In-memory doubles for ECA and systemd -*- lexical-binding: t; -*-

;;; Commentary:

;; `fleet-test-with-fakes' replaces the process-spawning seams of fleet-eca
;; and fleet-runtime with controllable in-memory doubles so core/supervisor
;; tests never launch anything.  Turn behaviour is scripted through
;; `fleet-test-fake-turn', stop verdicts through `fleet-test-fake-stop-verdict'.

;;; Code:

(require 'cl-lib)
(require 'fleet-core)
(require 'fleet-test-helpers)

(defvar fleet-test-fake-submissions nil "List of (:conn CONN :message-id ID :text TEXT) newest first.")
(defvar fleet-test-fake-turn 'finish
  "How a fake submission behaves: `finish' (accepted, running, idle), `busy' (accepted, running, no
idle until `fleet-test-fake-finish'), `reject', `unknown', or `noack'.")
(defvar fleet-test-fake-stop-verdict 'stopped "Verdict the fake systemd stop reports.")
(defvar fleet-test-fake-started nil "Connections started, newest first.")

(defun fleet-test-fake-finish (conn &optional error-text empty)
  "Complete the in-flight turn of fake CONN like a server idle would.
EMPTY marks the turn as having produced no text and no tool call; with
ERROR-TEXT it is barren but not empty (see `fleet-eca--turn-barren-p' and
`fleet-eca--turn-empty-p')."
  (when-let* ((turn (fleet-eca-conn-turn conn)))
    (setf (fleet-eca-conn-turn conn) nil)
    (fleet-eca--emit conn 'turn-idle-observed :message-id (plist-get turn :message-id) :source "fake" :error-text error-text
                     :barren (and empty (plist-get turn :accepted) t)
                     :empty (and empty (not error-text) (plist-get turn :accepted) t)
                     :accepted (plist-get turn :accepted) :submitted-at (plist-get turn :submitted-at))))

(defun fleet-test-fake-start (&rest args)
  "Double for `fleet-eca-start'."
  (let* ((conn (fleet-eca-conn--make :runtime-id (plist-get args :runtime-id) :owner-epoch (plist-get args :owner-epoch)
                                     :role (plist-get args :role) :fleet-id (plist-get args :fleet-id) :task-id (plist-get args :task-id)
                                     :display-name (plist-get args :display-name) :chat-id (fleet-paths-uuid)
                                     :sink (plist-get args :sink) :transcript-file (plist-get args :transcript-file)
                                     :default-model "fake/model"
                                     :model (or (plist-get args :model) "fake/model") :variant (plist-get args :variant)
                                     :state 'ready)))
    (puthash (plist-get args :runtime-id) conn fleet-eca--conns)
    (push conn fleet-test-fake-started)
    (fleet-eca--emit conn 'catalog-updated :models '("fake/model" "fake/other") :default-model "fake/model" :variants '("low" "high"))
    (fleet-eca--emit conn 'connection-ready)
    (run-with-timer 0 nil (plist-get args :callback) (list :ok t :conn conn))
    conn))

(cl-defun fleet-test-fake-submit (conn &key message-id text callback)
  "Double for `fleet-eca-submit'."
  (cond
   ((not (eq (fleet-eca-conn-state conn) 'ready))
    (funcall callback (list :outcome 'rejected :message-id message-id :code 'connection-not-ready)))
   ((fleet-eca-conn-turn conn)
    (funcall callback (list :outcome 'rejected :message-id message-id :code 'lane-busy)))
   (t
    (push (list :conn conn :message-id message-id :text text) fleet-test-fake-submissions)
    (pcase fleet-test-fake-turn
      ('reject (funcall callback (list :outcome 'rejected :message-id message-id :evidence '(:status "error"))))
      ('unknown (setf (fleet-eca-conn-turn conn) (list :message-id message-id :state 'delivery-unknown))
                (funcall callback (list :outcome 'delivery-unknown :message-id message-id)))
      (_
       (setf (fleet-eca-conn-turn conn) (list :message-id message-id :state 'running :running-seen t :accepted (not (eq fleet-test-fake-turn 'noack))
                                              :submitted-at (fleet-paths-now)))
       (fleet-eca--emit conn 'turn-started :message-id message-id)
       (funcall callback (list :outcome (if (eq fleet-test-fake-turn 'noack) 'observed-unacknowledged 'accepted) :message-id message-id))
       (when (eq fleet-test-fake-turn 'finish)
         (run-with-timer 0 nil #'fleet-test-fake-finish conn)))))))

(defun fleet-test-fake-request-cancel (conn)
  "Double for `fleet-eca-request-cancel': finishes the turn as stopping."
  (when-let* ((turn (fleet-eca-conn-turn conn)))
    (fleet-eca--emit conn 'cancel-requested :message-id (plist-get turn :message-id))
    (run-with-timer 0 nil (lambda ()
                            (when (eq (fleet-eca-conn-turn conn) turn)
                              (setf (fleet-eca-conn-turn conn) nil)
                              (fleet-eca--emit conn 'turn-idle-observed :message-id (plist-get turn :message-id) :was-stopping t))))
    'cancel-requested))

(defun fleet-test-fake-runtime-stop (unit _cgroup _boot callback)
  "Double for `fleet-runtime-stop'."
  (run-with-timer 0 nil callback
                  (list :verdict fleet-test-fake-stop-verdict :stop-exit 0
                        :inspection (list :query-ok t :unit unit :load-state "not-found" :active-state "inactive" :cgroup-populated 'absent))))

(defun fleet-test-fake-runtime-inspect (unit _cgroup callback)
  "Double for `fleet-runtime-inspect'."
  (run-with-timer 0 nil callback (list :query-ok t :unit unit :load-state "loaded" :active-state "active" :control-group (concat "/fake/" unit)
                                       :invocation-id "fake-inv" :cgroup-populated t :boot-id (fleet-paths-boot-id))))

(defmacro fleet-test-with-fakes (&rest body)
  "Run BODY with fake ECA/systemd seams, a live fake owner, and a fresh store bound to `store'."
  (declare (indent 0) (debug t))
  `(fleet-test-with-roots
     (let* ((fleet-test-fake-submissions nil) (fleet-test-fake-started nil)
            (fleet-test-fake-turn 'finish) (fleet-test-fake-stop-verdict 'stopped)
            (fleet-core-owner (list :epoch "test-epoch" :live-p (lambda () t)))
            (fleet-core-event-sink nil)
            (fleet-eca--conns (make-hash-table :test 'equal))
            (store (fleet-store-open (fleet-paths-db-file))))
       (cl-letf (((symbol-function 'fleet-eca-assert-supported) (lambda () '(:supported t)))
                 ((symbol-function 'fleet-eca-server-command) (lambda () '("/fake/eca" "server")))
                 ((symbol-function 'fleet-eca-start) #'fleet-test-fake-start)
                 ((symbol-function 'fleet-eca-submit) #'fleet-test-fake-submit)
                 ((symbol-function 'fleet-eca-request-cancel) #'fleet-test-fake-request-cancel)
                 ((symbol-function 'fleet-runtime-stop) #'fleet-test-fake-runtime-stop)
                 ((symbol-function 'fleet-runtime-inspect) #'fleet-test-fake-runtime-inspect))
         (unwind-protect (progn ,@body)
           (fleet-store-close store))))))

(defun fleet-test-wait-op (store op-id &optional timeout)
  "Wait until operation OP-ID leaves the running state; return its row."
  (fleet-test-wait-for (lambda ()
                         (let ((op (fleet-store-get store "operations" op-id)))
                           (and op (not (equal (plist-get op :state) "running")) op)))
                       (or timeout 10)))

(defconst fleet-test-brief
  "Goal: verify the widget.\nNon-goals: none.\nAcceptance: report.md exists.\nDeliverable: report.\nStop rules: ask if unclear.\n")

(provide 'fleet-test-fakes)
;;; fleet-test-fakes.el ends here
