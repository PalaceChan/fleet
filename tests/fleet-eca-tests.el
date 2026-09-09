;;; fleet-eca-tests.el --- Tests for the ECA adapter with a fake server -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)
(require 'fleet-eca)
(require 'fleet-test-helpers)

(defvar fleet-eca-test--events nil)

(defun fleet-eca-test-fake-command ()
  "Argument vector running tests/fake_eca.py."
  (list fleet-python-executable
        (expand-file-name "tests/fake_eca.py" (fleet-paths-source-root))))

(defmacro fleet-eca-test-with-conn (var &rest body)
  "Start a fake-backed connection bound to VAR, run BODY, then stop the process."
  (declare (indent 1))
  `(fleet-test-with-roots
     (let* ((log (expand-file-name "fake.log" fleet-test--roots))
            (fleet-eca-test--events nil)
            (fleet-eca-human-sink nil)
            (result nil) (,var nil))
       (progn
         (setq ,var
               (fleet-eca-start :runtime-id (fleet-paths-uuid) :owner-epoch "epoch-1" :role "operator"
                                :fleet-id "f1" :task-id "t1" :display-name "*eca:operator:f:t*"
                                :command (fleet-eca-test-fake-command) :roots (list fleet-test--roots)
                                :environment (list (cons "FAKE_ECA_LOG" log))
                                :model "fake/model" :agent nil
                                :transcript-file (expand-file-name "transcript.jsonl" fleet-test--roots)
                                :sink (lambda (ev) (push ev fleet-eca-test--events))
                                :callback (lambda (r) (setq result r))))
         (should (fleet-test-wait-for (lambda () result) 15))
         (should (plist-get result :ok))
         (unwind-protect
             (progn ,@body)
           (when (process-live-p (fleet-eca-conn-process ,var))
             (delete-process (fleet-eca-conn-process ,var)))
           (fleet-eca-detach ,var)
           (when (buffer-live-p (fleet-eca-conn-buffer ,var))
             (let ((kill-buffer-query-functions nil)) (kill-buffer (fleet-eca-conn-buffer ,var)))))))))

(defun fleet-eca-test-kinds ()
  "Event kinds in emission order."
  (mapcar (lambda (e) (plist-get e :kind)) (reverse fleet-eca-test--events)))

(defun fleet-eca-test-submit (conn text)
  "Submit TEXT and return the submission outcome plist."
  (let (out)
    (fleet-eca-submit conn :message-id (fleet-paths-uuid) :text text :callback (lambda (r) (setq out r)))
    (fleet-test-wait-for (lambda () out) 20)
    out))

(defun fleet-eca-test-wait-kind (kind &optional timeout)
  "Wait until an event of KIND was emitted."
  (fleet-test-wait-for (lambda () (memq kind (fleet-eca-test-kinds))) (or timeout 10)))

(defun fleet-eca-test-log-methods (log)
  "Methods the fake received, in order."
  (mapcar (lambda (l) (plist-get (fleet-store-unjson l) :method))
          (split-string (or (fleet-paths-read-file log) "") "\n" t)))

(ert-deftest fleet-eca-probe-checks-dependencies-not-versions ()
  (let ((p (fleet-eca-probe)))
    (should (plist-get p :supported))
    (should (listp (plist-get p :reasons)))
    ;; Versions are informational: an unknown server version is still supported.
    (cl-letf (((symbol-function 'fleet-eca--server-version) (lambda (_) "0.0.1")))
      (should (plist-get (fleet-eca-probe) :supported)))
    ;; A frontend symbol the adapter relies on going missing is a refusal.
    (cl-letf (((symbol-function 'eca-chat--steer-prompt) nil))
      (should-not (plist-get (fleet-eca-probe) :supported))
      (fleet-test-should-fail 'unsupported-eca-contract (fleet-eca-assert-supported)))))

(ert-deftest fleet-eca-start-is-silent-and-registers-chat ()
  (let ((win (selected-window)) (buf (current-buffer)))
    (fleet-eca-test-with-conn conn
      (should (eq (fleet-eca-conn-state conn) 'ready))
      ;; readiness follows the models announcement; nothing else happened yet
      (should (memq 'models-ready (fleet-eca-test-kinds)))
      (should (< (cl-position 'models-ready (fleet-eca-test-kinds)) (cl-position 'connection-ready (fleet-eca-test-kinds))))
      (should-not (cl-intersection '(turn-started prompt-accepted turn-idle-observed) (fleet-eca-test-kinds)))
      (should (buffer-live-p (fleet-eca-conn-buffer conn)))
      (should (equal (buffer-local-value 'eca-chat--id (fleet-eca-conn-buffer conn)) (fleet-eca-conn-chat-id conn)))
      (should (equal (buffer-local-value 'fleet-eca-runtime-id (fleet-eca-conn-buffer conn)) (fleet-eca-conn-runtime-id conn)))
      ;; no window/buffer stealing
      (should (eq (selected-window) win))
      (should (eq (current-buffer) buf))
      (should-not (get-buffer-window (fleet-eca-conn-buffer conn)))
      ;; killing the live chat buffer is refused (buried instead)
      (should-not (kill-buffer (fleet-eca-conn-buffer conn)))
      (should (buffer-live-p (fleet-eca-conn-buffer conn))))))

(defun fleet-eca-test-log-requests (log method)
  "Requests of METHOD the fake received, oldest first."
  (cl-remove-if-not (lambda (m) (equal (plist-get m :method) method))
                    (mapcar (lambda (l) (fleet-store-unjson l))
                            (split-string (or (fleet-paths-read-file log) "") "\n" t))))

(ert-deftest fleet-eca-trust-follows-user-setting-and-roots-are-all-sent ()
  "Rehearsal 1: the user's `eca-chat-trust-enable' never reached Fleet chats,
so ECA's outside-workspace check prompted for every operator tool call.
Fleet chats must seed trust like `eca-chat-open' and send `trust' on prompts;
and every workspace root must reach `initialize'."
  (dolist (trust '(t nil))
    (let ((eca-chat--last-known-trust trust))
      (fleet-eca-test-with-conn conn
        (let ((log (expand-file-name "fake.log" fleet-test--roots)))
          (should (eq (buffer-local-value 'eca-chat--selected-trust (fleet-eca-conn-buffer conn)) trust))
          (should (eq (plist-get (fleet-eca-test-submit conn "hello") :outcome) 'accepted))
          (let ((prompt (car (fleet-eca-test-log-requests log "chat/prompt"))))
            (should prompt)
            (should (eq (plist-get (plist-get prompt :params) :trust) (if trust t nil))))
          (let* ((init (car (fleet-eca-test-log-requests log "initialize")))
                 (folders (append (plist-get (plist-get init :params) :workspaceFolders) nil)))
            (should (= 1 (length folders)))
            (should (string-suffix-p (file-name-nondirectory (directory-file-name fleet-test--roots))
                                     (plist-get (car folders) :name)))))))))

(ert-deftest fleet-eca-ui-error-does-not-drop-later-messages ()
  "The ECA UI half may error on a Fleet session; the observer must still see
every message of the chunk and the connection must stay usable."
  (fleet-eca-test-with-conn conn
    (cl-letf* ((orig (symbol-function 'eca--handle-message))
               ((symbol-function 'eca--handle-message)
                (lambda (session msg)
                  ;; the UI errors on every notification (as with the mode-line refreshes)
                  (if (plist-get msg :method)
                      (error "Wrong type argument: stringp, nil")
                    (funcall orig session msg)))))
      (let ((out (fleet-eca-test-submit conn "hello")))
        (should (eq (plist-get out :outcome) 'accepted))
        (should (fleet-eca-test-wait-kind 'turn-idle-observed))
        (should (null (fleet-eca-conn-turn conn)))
        (should (eq (fleet-eca-conn-state conn) 'ready))))))

(ert-deftest fleet-eca-submit-normal-turn-ordering ()
  (fleet-eca-test-with-conn conn
    (let ((out (fleet-eca-test-submit conn "hello")))
      (should (eq (plist-get out :outcome) 'accepted))
      ;; `title' (metadata) arrives after both terminal events
      (should (fleet-eca-test-wait-kind 'title))
      (let ((kinds (fleet-eca-test-kinds)))
        ;; running is observed before acceptance (as on the native pair)
        (should (< (cl-position 'turn-started kinds) (cl-position 'prompt-accepted kinds)))
        (should (= 1 (cl-count 'turn-idle-observed kinds)))
        (should (memq 'turn-idle-duplicate kinds)))
      (should (null (fleet-eca-conn-turn conn)))
      ;; transcript has submit, user echo and flushed assistant text
      (let ((t-text (fleet-paths-read-file (fleet-eca-conn-transcript-file conn))))
        (should (string-match-p "\"kind\":\"submit\"" t-text))
        (should (string-match-p "\"role\":\"assistant\"" t-text))))))

(ert-deftest fleet-eca-lane-refuses-second-prompt ()
  (fleet-eca-test-with-conn conn
    (let ((first (fleet-eca-test-submit conn "SLOW"))
          (second (fleet-eca-test-submit conn "hello")))
      (should (eq (plist-get first :outcome) 'accepted))
      (should (eq (plist-get second :outcome) 'rejected))
      (should (eq (plist-get second :code) 'lane-busy))
      ;; exactly one chat/prompt reached the wire
      (should (fleet-test-wait-for (lambda () (= 1 (cl-count "chat/prompt" (fleet-eca-test-log-methods (expand-file-name "fake.log" fleet-test--roots)) :test #'equal))) 5))
      (should (eq (fleet-eca-request-cancel conn) 'cancel-requested))
      (should (fleet-eca-test-wait-kind 'turn-idle-observed))
      (let ((ev (cl-find-if (lambda (e) (eq (plist-get e :kind) 'turn-idle-observed)) fleet-eca-test--events)))
        (should (plist-get ev :was-stopping))
        (should (equal (plist-get ev :message-id) (plist-get first :message-id))))
      (should (memq 'turn-stopping (fleet-eca-test-kinds))))))

(ert-deftest fleet-eca-error-model-is-accepted-then-finishes-with-error-text ()
  (fleet-eca-test-with-conn conn
    (let ((out (fleet-eca-test-submit conn "ERRORMODEL")))
      (should (eq (plist-get out :outcome) 'accepted))
      (should (fleet-eca-test-wait-kind 'turn-idle-observed))
      (should (memq 'turn-error-text (fleet-eca-test-kinds)))
      (should (null (fleet-eca-conn-turn conn))))))

(ert-deftest fleet-eca-no-model-is-definite-rejection ()
  (fleet-eca-test-with-conn conn
    (let ((out (fleet-eca-test-submit conn "NOMODEL")))
      (should (eq (plist-get out :outcome) 'rejected))
      (should (equal (plist-get (plist-get out :evidence) :status) "error"))
      (should (null (fleet-eca-conn-turn conn)))
      ;; lane free again
      (should (eq (plist-get (fleet-eca-test-submit conn "hello") :outcome) 'accepted)))))

(ert-deftest fleet-eca-question-captured-and-answered-exactly ()
  (fleet-eca-test-with-conn conn
    (let ((win (selected-window)))
      (fleet-eca-test-submit conn "QUESTION")
      (should (fleet-eca-test-wait-kind 'question-opened))
      (should (eq (selected-window) win))
      (let* ((q (fleet-eca-conn-pending-question conn))
             (rid (plist-get q :request-id)))
        (should (equal (plist-get q :options) '("Red" "Blue")))
        (fleet-test-should-fail 'no-such-question (fleet-eca-answer-question conn 99999 "Red"))
        (should (fleet-eca-answer-question conn rid "Red"))
        (should (null (fleet-eca-conn-pending-question conn)))
        (should (fleet-eca-test-wait-kind 'turn-idle-observed))
        (should (memq 'question-answered (fleet-eca-test-kinds)))
        (should (string-match-p "answered: Red" (fleet-paths-read-file (fleet-eca-conn-transcript-file conn))))))))

(ert-deftest fleet-eca-approval-captured-not-auto-approved ()
  (fleet-eca-test-with-conn conn
    (fleet-eca-test-submit conn "APPROVAL")
    (should (fleet-eca-test-wait-kind 'tool-approval-required))
    (should (equal (fleet-eca-conn-pending-approvals conn) '("call_a1")))
    ;; nothing finished by itself
    (accept-process-output nil 0.3)
    (should-not (memq 'turn-idle-observed (fleet-eca-test-kinds)))
    (fleet-test-should-fail 'no-such-approval (fleet-eca-approve-tool conn "other"))
    (should (fleet-eca-approve-tool conn "call_a1"))
    (should (fleet-eca-test-wait-kind 'turn-idle-observed))
    (should (null (fleet-eca-conn-pending-approvals conn)))
    (should (memq 'tool-finished (fleet-eca-test-kinds)))))

(ert-deftest fleet-eca-subagent-child-cannot-finish-parent ()
  (fleet-eca-test-with-conn conn
    (fleet-eca-test-submit conn "SUBAGENT")
    (should (fleet-eca-test-wait-kind 'turn-idle-observed))
    (let ((kinds (fleet-eca-test-kinds)))
      (should (memq 'subagent-activity kinds))
      (should (= 1 (cl-count 'turn-idle-observed kinds)))
      ;; the parent terminal came after the child's finished
      (should (> (cl-position 'turn-idle-observed kinds) (cl-position 'subagent-activity kinds :from-end t))))))

(ert-deftest fleet-eca-duplicate-terminal-consumed-once ()
  (fleet-eca-test-with-conn conn
    (fleet-eca-test-submit conn "DUPIDLE")
    (should (fleet-eca-test-wait-kind 'title))
    (should (= 1 (cl-count 'turn-idle-observed (fleet-eca-test-kinds))))
    (should (>= (cl-count 'turn-idle-duplicate (fleet-eca-test-kinds)) 3))
    ;; a replayed late idle cannot finish a NEW turn: submit SLOW then inject idle-duplicate check
    (let ((out (fleet-eca-test-submit conn "SLOW")))
      (should (eq (plist-get out :outcome) 'accepted))
      (should (fleet-eca-conn-turn conn))
      (fleet-eca-request-cancel conn)
      (should (fleet-test-wait-for (lambda () (null (fleet-eca-conn-turn conn))) 10)))))

(ert-deftest fleet-eca-noack-watchdog-observed-unacknowledged ()
  (fleet-eca-test-with-conn conn
    (let ((fleet-eca-ack-timeout-sec 1))
      (cl-letf (((symbol-value 'fleet-eca-ack-timeout-sec) 1))
        (let ((out (fleet-eca-test-submit conn "NOACK")))
          (should (eq (plist-get out :outcome) 'observed-unacknowledged))
          ;; lane still held: running was observed
          (should (fleet-eca-conn-turn conn))
          (should (memq 'ack-timeout (fleet-eca-test-kinds)))
          (fleet-eca-request-cancel conn)
          (should (fleet-eca-test-wait-kind 'turn-idle-observed)))))))

(ert-deftest fleet-eca-silent-transport-is-delivery-unknown-and-frozen ()
  (fleet-eca-test-with-conn conn
    (cl-letf (((symbol-value 'fleet-eca-ack-timeout-sec) 1))
      (let ((out (fleet-eca-test-submit conn "SILENT")))
        (should (eq (plist-get out :outcome) 'delivery-unknown))
        (should (memq 'delivery-unknown (fleet-eca-test-kinds)))
        ;; lane frozen: no automatic resend, further submits refused
        (should (eq (plist-get (fleet-eca-test-submit conn "hello") :code) 'lane-busy))
        (should (= 1 (cl-count "chat/prompt" (fleet-eca-test-log-methods (expand-file-name "fake.log" fleet-test--roots)) :test #'equal)))))))

(ert-deftest fleet-eca-process-death-emits-connection-lost-with-inflight ()
  (fleet-eca-test-with-conn conn
    (let ((out (fleet-eca-test-submit conn "CRASH")))
      (should (eq (plist-get out :outcome) 'accepted))
      (should (fleet-eca-test-wait-kind 'connection-lost))
      (let ((ev (cl-find-if (lambda (e) (eq (plist-get e :kind) 'connection-lost)) fleet-eca-test--events)))
        (should (equal (plist-get ev :in-flight-message) (plist-get out :message-id))))
      (should (eq (fleet-eca-conn-state conn) 'lost))
      (should (eq (plist-get (fleet-eca-test-submit conn "again") :code) 'connection-not-ready)))))

(ert-deftest fleet-eca-human-send-goes-through-admission-and-preserves-draft-on-refusal ()
  (fleet-eca-test-with-conn conn
    (let ((admitted nil))
      (with-current-buffer (fleet-eca-conn-buffer conn)
        ;; type a draft
        (eca-chat--set-prompt "human draft text")
        ;; no sink installed => refused, draft preserved, nothing sent
        (setq fleet-eca-human-sink nil)
        (should-error (eca-chat--key-pressed-return) :type 'user-error)
        (should (equal (eca-chat--prompt-content) "human draft text"))
        ;; sink refusing => draft preserved
        (setq fleet-eca-human-sink (lambda (_c _env) (fleet-fail 'read-only "no")))
        (eca-chat--key-pressed-return)
        (should (equal (eca-chat--prompt-content) "human draft text"))
        ;; sink accepting => draft cleared, envelope captured, transport untouched
        (setq fleet-eca-human-sink (lambda (_c env) (setq admitted env) t))
        (eca-chat--key-pressed-return)
        (should (equal (plist-get admitted :text) "human draft text"))
        (should (equal (eca-chat--prompt-content) "")))
      (accept-process-output nil 0.2)
      (should (= 0 (cl-count "chat/prompt" (fleet-eca-test-log-methods (expand-file-name "fake.log" fleet-test--roots)) :test #'equal)))
      ;; busy chat RET also goes to admission (steer path), never chat/promptSteer
      (fleet-eca-test-submit conn "SLOW")
      (with-current-buffer (fleet-eca-conn-buffer conn)
        (eca-chat--set-prompt "steer me")
        (eca-chat--key-pressed-return)
        (should (equal (plist-get admitted :text) "steer me"))
        ;; C-RET queue path too
        (eca-chat--set-prompt "queue me")
        (eca-chat--key-pressed-queue)
        (should (equal (plist-get admitted :text) "queue me"))
        (should (null eca-chat--queued-prompt)))
      (fleet-eca-request-cancel conn)
      (should (fleet-eca-test-wait-kind 'turn-idle-observed))
      (should-not (member "chat/promptSteer" (fleet-eca-test-log-methods (expand-file-name "fake.log" fleet-test--roots)))))))

(ert-deftest fleet-eca-programmatic-send-keeps-human-draft ()
  (fleet-eca-test-with-conn conn
    (with-current-buffer (fleet-eca-conn-buffer conn)
      (eca-chat--set-prompt "unsent human draft"))
    (should (eq (plist-get (fleet-eca-test-submit conn "wake") :outcome) 'accepted))
    (should (fleet-eca-test-wait-kind 'turn-idle-observed))
    (should (equal (fleet-eca-draft conn) "unsent human draft"))))

(ert-deftest fleet-eca-guarded-native-commands-refused-only-on-fleet-chats ()
  (fleet-eca-test-with-conn conn
    (with-current-buffer (fleet-eca-conn-buffer conn)
      (should-error (eca-chat-new) :type 'user-error)
      (should-error (eca-chat-reset) :type 'user-error)
      (should-error (eca-stop) :type 'user-error))
    ;; ordinary buffer: advice passes through to the original, which is a
    ;; no-op without a session (no Fleet refusal).
    (with-temp-buffer
      (should (null (eca-stop))))))

(ert-deftest fleet-eca-advice-idempotent-and-removable ()
  (require 'eca)
  (fleet-eca-install-advice)
  (fleet-eca-install-advice)
  (should (advice-member-p #'fleet-eca--around-send 'eca-chat--send-prompt))
  (fleet-eca-uninstall-advice)
  (should-not (advice-member-p #'fleet-eca--around-send 'eca-chat--send-prompt))
  (fleet-eca-install-advice))

(ert-deftest fleet-eca-peek-and-detach-retain-transcript ()
  (fleet-eca-test-with-conn conn
    (fleet-eca-test-submit conn "hello")
    (should (fleet-eca-test-wait-kind 'turn-idle-observed))
    (should (stringp (fleet-eca-peek conn 5)))
    (let ((buf (fleet-eca-conn-buffer conn)) (name (buffer-name (fleet-eca-conn-buffer conn))))
      (fleet-eca-detach conn)
      (should (eq (fleet-eca-conn-state conn) 'detached))
      (should (null (fleet-eca-conn (fleet-eca-conn-runtime-id conn))))
      (should (string-prefix-p name (buffer-name buf)))
      (should-not (string= name (buffer-name buf)))
      ;; retained buffer may now be killed by the user
      (let ((kill-buffer-query-functions nil)) (kill-buffer buf))
      (should (string-match-p "assistant" (fleet-eca-peek conn 10))))))

;;;; Native (opt-in): the real installed pair, one minimal turn.

(ert-deftest fleet-eca-native-minimal-turn ()
  :tags '(native)
  (skip-unless (fleet-test-native-p))
  (fleet-test-with-roots
    (let* ((fleet-eca-command nil) (events nil) (result nil))
      (let ((probe (fleet-eca-probe)))
        (should (plist-get probe :supported))
        (let ((conn (fleet-eca-start :runtime-id (fleet-paths-uuid) :owner-epoch "e" :role "operator"
                                     :fleet-id "f" :task-id "t" :display-name "*eca:operator:native-test*"
                                     :command (plist-get probe :command) :roots (list fleet-test--roots)
                                     :environment (list (cons "XDG_CACHE_HOME" fleet-cache-root))
                                     :model nil :agent nil
                                     :transcript-file (expand-file-name "transcript.jsonl" fleet-test--roots)
                                     :sink (lambda (ev) (push ev events))
                                     :callback (lambda (r) (setq result r)))))
          (unwind-protect
              (progn
                (should (fleet-test-wait-for (lambda () result) 60))
                (should (plist-get result :ok))
                ;; wait for models before prompting (server needs a few seconds)
                (sleep-for 8)
                (let (out)
                  (fleet-eca-submit conn :message-id (fleet-paths-uuid) :text "Reply with exactly the single word OK."
                                    :callback (lambda (r) (setq out r)))
                  (should (fleet-test-wait-for (lambda () out) 60))
                  (should (eq (plist-get out :outcome) 'accepted)))
                (should (fleet-test-wait-for (lambda () (cl-find-if (lambda (e) (eq (plist-get e :kind) 'turn-idle-observed)) events)) 120))
                (should (file-directory-p (expand-file-name "eca" fleet-cache-root))))
            (when (process-live-p (fleet-eca-conn-process conn)) (delete-process (fleet-eca-conn-process conn)))
            (fleet-eca-detach conn)
            (when (buffer-live-p (fleet-eca-conn-buffer conn))
              (let ((kill-buffer-query-functions nil)) (kill-buffer (fleet-eca-conn-buffer conn))))))))))

(provide 'fleet-eca-tests)
;;; fleet-eca-tests.el ends here
