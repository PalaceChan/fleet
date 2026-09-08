;;; fleet-eca.el --- Native ECA adapter: the only module that knows ECA internals -*- lexical-binding: t; -*-

;;; Commentary:

;; Verified against eca-emacs 20260529.1500 (rev f700be30f1e5) with server
;; eca 0.158.1.  See docs/eca-compatibility.md for every symbol and wire
;; fact this file depends on, and tests/fixtures/eca for the traces.
;;
;; Contract implemented (design §5.4):
;;  - One designated chat per connection; at most one submitted turn.
;;  - Acceptance is the `chat/prompt' response carrying status "prompting";
;;    status "error" is a definite rejection.  The response arrives after
;;    `chat/statusChanged running', so running is recorded as observed
;;    execution while acceptance stays unconfirmed.
;;  - The terminal activity event is the first top-level
;;    `progress state=finished' or `chat/statusChanged idle'; the other is
;;    a same-instant duplicate and is ignored.  After promptStop the server
;;    emits `statusChanged stopping' then `finished' and never `idle'.
;;  - A second prompt during a running turn is accepted by the server and
;;    silently supersedes the first, so the lane guard here is load-bearing.
;;  - `eca-api--send!' swallows transport errors; an acknowledgment watchdog
;;    marks delivery-unknown when neither response nor running arrives.
;;
;; Human sends from a Fleet chat are intercepted before the composer is
;; cleared and routed through Fleet's admission (`fleet-eca-human-sink').
;; Programmatic sends never read or clear the draft.  Ordinary ECA sessions
;; take every original code path unchanged.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'fleet-paths)
(require 'fleet-store)

;; The session struct's setf expanders must exist when the forms below are
;; macroexpanded; the rest of ECA is loaded lazily by the probe so this file
;; can still be required for read-only inspection without a working ECA.
(cl-eval-when (compile load eval)
  (require 'eca-util nil t))

(declare-function eca-create-session "eca-util")
(declare-function eca-delete-session "eca-util")
(declare-function eca-assoc "eca-util")
(declare-function eca-process-start "eca-process")
(declare-function eca-process-running-p "eca-process")
(declare-function eca-api-request-async "eca-api")
(declare-function eca-api-notify "eca-api")
(declare-function eca-api-send-request-response "eca-api")
(declare-function eca--handle-message "eca")
(declare-function eca--path-to-uri "eca-util")
(declare-function eca-chat-mode "eca-chat")
(declare-function eca-chat--set-prompt "eca-chat")
(declare-function eca-chat--prompt-content "eca-chat")
(declare-function eca-chat--extract-contexts-from-prompt "eca-chat")
(declare-function eca-chat--refine-context "eca-chat")
(declare-function eca-chat--normalize-prompt "eca-chat")
(declare-function eca-chat--answer-question "eca-chat")
(declare-function eca-chat--cancel-question "eca-chat")
(declare-function eca-chat--stop-prompt "eca-chat")
(declare-function eca-chat--model "eca-chat")
(declare-function eca-chat--agent "eca-chat")
(declare-function eca-chat--variant "eca-chat")
(declare-function eca-chat--trust "eca-chat")
(declare-function eca-chat--set-chat-loading "eca-chat")
(declare-function eca--session-process "eca-util")
(declare-function eca--session-chats "eca-util")
(declare-function eca--session-status "eca-util")
(declare-function eca--session-chat-welcome-message "eca-util")
(declare-function eca--session-last-chat-buffer "eca-util")
(declare-function eca--session-workspace-folders "eca-util")
(declare-function eca--session-id "eca-util")
(defvar eca--chat-init-session)
(defvar eca--session-id-cache)
(defvar eca-chat--id)
(defvar eca-chat--context)
(defvar eca-chat--history)
(defvar eca-chat--pending-question)
(defvar eca-chat--chat-loading)
(defvar eca-chat--selected-model)
(defvar eca-chat--selected-agent)
(defvar eca-chat--selected-variant)
(defvar eca-chat--selected-trust)
(defvar eca-chat--last-request-id)
(defvar eca-chat--queued-prompt)
(defvar eca-chat--steered-prompt)
(defvar eca-custom-command)
(defvar eca-process-wrapper-function)
(defvar eca-chat-custom-agent)
(defvar eca-send-process-id)
(defvar eca-chat-auto-add-cursor)
(defvar eca-server-install-path)

;;;; Compatibility profile

(defconst fleet-eca-supported-pairs
  '((:client "20260529.1500" :server "0.158.1"))
  "Frontend/server pairs whose transition table was verified with recorded traces.")

(defconst fleet-eca-required-functions
  '(eca-create-session eca-process-start eca-api-request-async eca-api-notify
    eca-api-send-request-response eca--handle-message eca-chat-mode
    eca-chat--send-prompt eca-chat--steer-prompt eca-chat--queue-prompt
    eca-chat--send-queued-prompt eca-chat--send-steered-prompt
    eca-chat--answer-question eca-chat--cancel-question eca-chat--stop-prompt
    eca-chat--set-prompt eca-chat--prompt-content eca-chat--extract-contexts-from-prompt
    eca-chat--refine-context eca-chat--normalize-prompt eca-chat--model eca-chat--agent
    eca-chat--variant eca-chat--trust eca-chat-new eca-chat-select eca-chat-resume
    eca-chat-reset eca-chat-clear eca-stop eca-restart)
  "Symbols this adapter calls or advises.")

(defconst fleet-eca-required-variables
  '(eca--chat-init-session eca-chat--id eca-chat--pending-question eca-chat--chat-loading
    eca-chat--selected-model eca-chat--selected-agent eca-chat--last-request-id
    eca-custom-command eca-process-wrapper-function)
  "Variables this adapter binds or reads.")

(defconst fleet-eca-ack-timeout-sec 45
  "Bounded wait for the chat/prompt response.  Not a turn-duration cap.")

(defconst fleet-eca-models-timeout-sec 90
  "Bounded wait after initialize for `config/updated' carrying models.
The native server loads providers asynchronously; a prompt sent earlier is
answered with an error turn (recorded trace), so readiness waits for it.")

(defun fleet-eca--client-version ()
  "Installed eca-emacs package version string, or nil."
  (or (when (bound-and-true-p package-alist)
        (when-let* ((desc (cadr (assq 'eca package-alist))))
          (package-version-join (package-desc-version desc))))
      (when-let* ((f (locate-library "eca.el")))
        (with-temp-buffer
          (insert-file-contents f nil 0 4000)
          (when (re-search-forward "^;; Package-Version: \\(.+\\)$" nil t) (match-string 1))))))

(defun fleet-eca-server-command ()
  "Argument vector for the native server, resolved without any download."
  (cond
   (fleet-eca-command fleet-eca-command)
   ((and (boundp 'eca-custom-command) eca-custom-command) eca-custom-command)
   ((executable-find "eca") (list (executable-find "eca") "server"))
   ((and (boundp 'eca-server-install-path) (file-executable-p eca-server-install-path))
    (list eca-server-install-path "server"))
   (t nil)))

(defun fleet-eca--server-version (command)
  "Run COMMAND's executable with --version; return trimmed output or nil."
  (when (and command (file-executable-p (car command)))
    (with-temp-buffer
      (when (eql 0 (call-process (car command) nil t nil "--version"))
        (let ((s (string-trim (buffer-string))))
          (if (string-match "\\([0-9]+\\.[0-9]+\\.[0-9]+\\)" s) (match-string 1 s) s))))))

(defun fleet-eca-probe ()
  "Inspect the installed pair; return a plist with :supported and evidence.
Never launches a server.  Loads the ECA package if present."
  (let* ((loaded (require 'eca nil t))
         (client (and loaded (fleet-eca--client-version)))
         (command (fleet-eca-server-command))
         (server (fleet-eca--server-version command))
         (missing-fns (and loaded (cl-remove-if #'fboundp fleet-eca-required-functions)))
         (missing-vars (and loaded (cl-remove-if #'boundp fleet-eca-required-variables)))
         (pair (cl-find-if (lambda (p) (and (equal (plist-get p :client) client)
                                            (equal (plist-get p :server) server)))
                           fleet-eca-supported-pairs))
         (reasons nil))
    (unless loaded (push "eca-emacs package not installed/loadable" reasons))
    (unless command (push "no native eca executable found (set `fleet-eca-command')" reasons))
    (unless server (push "could not read native server version" reasons))
    (when missing-fns (push (format "missing functions: %s" missing-fns) reasons))
    (when missing-vars (push (format "missing variables: %s" missing-vars) reasons))
    (unless pair
      (push (format "unverified pair client=%s server=%s; verified: %S" client server fleet-eca-supported-pairs) reasons))
    (list :supported (null reasons) :client client :server server :command command
          :missing-functions missing-fns :missing-variables missing-vars
          :profile (and pair (list :acceptance "chat/prompt response status=\"prompting\""
                                   :terminal "first of top-level progress finished / statusChanged idle"
                                   :serialized-lane t))
          :reasons (nreverse reasons))))

(defun fleet-eca-assert-supported ()
  "Signal `unsupported-eca-contract' unless the installed pair is verified."
  (let ((p (fleet-eca-probe)))
    (unless (plist-get p :supported)
      (fleet-fail 'unsupported-eca-contract "Installed ECA pair is not verified for autonomous dispatch"
                  :reasons (plist-get p :reasons) :client (plist-get p :client) :server (plist-get p :server)))
    p))

;;;; Connection registry

(cl-defstruct (fleet-eca-conn (:constructor fleet-eca-conn--make))
  runtime-id owner-epoch role fleet-id task-id display-name
  session chat-id buffer process
  sink                 ; (lambda (event-plist))
  (state 'connecting)  ; connecting / ready / lost / detached
  turn                 ; nil or plist for the single in-flight turn
  pending-question pending-approvals active-tools
  watchdog transcript-file assistant-buffer title
  models-ready         ; non-nil once config/updated announced models
  on-models            ; continuation waiting for models, or nil
  tool-servers         ; alist name -> plist of the last tool/serverUpdated
  (observation-revision 0))

(defvar fleet-eca--conns (make-hash-table :test 'equal)
  "runtime-id -> `fleet-eca-conn' for live and retained connections.")

(defvar-local fleet-eca-runtime-id nil
  "Runtime UUID owning this chat buffer; nil for ordinary ECA chats.")

(defvar fleet-eca--dispatching nil
  "Non-nil while Fleet itself writes to the transport; lets advice pass through.")

(defvar fleet-eca-human-sink nil
  "Function (CONN ENVELOPE) called for human sends from a Fleet chat.
Must durably admit the message and return non-nil; nil or an error leaves
the draft untouched.  Installed by fleet-supervisor.")

(defun fleet-eca-conn (runtime-id) "Connection for RUNTIME-ID or nil." (gethash runtime-id fleet-eca--conns))

(defun fleet-eca--conn-for-session (session)
  "Connection owning SESSION, or nil."
  (cl-loop for c being the hash-values of fleet-eca--conns
           when (eq (fleet-eca-conn-session c) session) return c))

(defun fleet-eca--conn-for-buffer (&optional buffer)
  "Connection owning BUFFER (default current), or nil."
  (with-current-buffer (or buffer (current-buffer))
    (and fleet-eca-runtime-id (fleet-eca-conn fleet-eca-runtime-id))))

(defun fleet-eca--emit (conn kind &rest plist)
  "Emit normalized event KIND with PLIST to CONN's sink, tagged with identities."
  (cl-incf (fleet-eca-conn-observation-revision conn))
  (let ((event (append (list :kind kind
                             :runtime-id (fleet-eca-conn-runtime-id conn)
                             :owner-epoch (fleet-eca-conn-owner-epoch conn)
                             :fleet-id (fleet-eca-conn-fleet-id conn)
                             :task-id (fleet-eca-conn-task-id conn)
                             :chat-id (fleet-eca-conn-chat-id conn)
                             :at (fleet-paths-now))
                       plist)))
    (when (fleet-eca-conn-sink conn)
      (condition-case err
          (funcall (fleet-eca-conn-sink conn) event)
        (error (message "fleet-eca: sink error on %s: %s" kind (error-message-string err)))))
    event))

;;;; Transcript (diagnostic, bounded, never authoritative)

(defun fleet-eca--transcript (conn plist)
  "Append PLIST as one JSON line to CONN's transcript file."
  (when-let* ((f (fleet-eca-conn-transcript-file conn)))
    (condition-case err
        (let ((coding-system-for-write 'utf-8-unix))
          (fleet-paths-ensure-dir (file-name-directory f))
          (write-region (concat (fleet-store-json (append (list :at (fleet-paths-now)) plist)) "\n") nil f t 'silent))
      (error (message "fleet-eca: transcript write failed: %s" (error-message-string err))))))

(defun fleet-eca--flush-assistant (conn)
  "Write accumulated assistant text of CONN as one transcript entry."
  (when-let* ((text (fleet-eca-conn-assistant-buffer conn)))
    (unless (string-empty-p text)
      (fleet-eca--transcript conn (list :role "assistant" :kind "text" :text (fleet-eca--clip text 4000))))
    (setf (fleet-eca-conn-assistant-buffer conn) nil)))

(defun fleet-eca--clip (s n) "Clip string S to N chars." (if (> (length s) n) (concat (substring s 0 n) "…") s))

;;;; Start

(cl-defun fleet-eca-start (&key runtime-id owner-epoch role fleet-id task-id display-name
                                command roots cwd environment model agent variant
                                transcript-file sink callback)
  "Start a native ECA server for a Fleet runtime and register its designated chat.
COMMAND is the complete argument vector (already wrapped by fleet-runtime).
ENVIRONMENT is an alist of (NAME . VALUE) set for the launcher only.
CALLBACK gets (:ok t :conn CONN) after verified initialization, or
\(:ok nil :error STRING).  Never touches windows or ordinary sessions."
  (fleet-eca-assert-supported)
  (require 'eca)
  (fleet-eca-install-advice)
  (let* ((session (eca-create-session (mapcar #'expand-file-name roots)))
         (conn (fleet-eca-conn--make :runtime-id runtime-id :owner-epoch owner-epoch :role role
                                     :fleet-id fleet-id :task-id task-id :display-name display-name
                                     :session session :chat-id (fleet-paths-uuid)
                                     :sink sink :transcript-file transcript-file))
         (done nil))
    (puthash runtime-id conn fleet-eca--conns)
    (let ((process-environment (append (mapcar (lambda (kv) (concat (car kv) "=" (cdr kv))) environment)
                                       process-environment))
          (default-directory (file-name-as-directory (or cwd (car roots))))
          (eca-custom-command command)
          (eca-process-wrapper-function nil)
          (eca-chat-auto-add-cursor nil))
      (condition-case err
          (eca-process-start
           session
           (lambda ()
             (setf (fleet-eca-conn-process conn) (eca--session-process session))
             (fleet-eca--wrap-sentinel conn)
             (fleet-eca--initialize conn model agent variant
                                    (lambda (ok error)
                                      (unless done
                                        (setq done t)
                                        (if ok
                                            (funcall callback (list :ok t :conn conn))
                                          (funcall callback (list :ok nil :error error :conn conn)))))))
           (lambda (msg)
             (condition-case err
                 (fleet-eca--observe conn msg)
               (error (message "fleet-eca: observe error: %s" (error-message-string err))))
             (eca--handle-message session msg)))
        (error
         (setf (fleet-eca-conn-state conn) 'lost)
         (unless done
           (setq done t)
           (funcall callback (list :ok nil :error (error-message-string err) :conn conn))))))
    conn))

(defun fleet-eca--wrap-sentinel (conn)
  "Observe process exit of CONN before ECA's own sentinel runs."
  (when-let* ((proc (fleet-eca-conn-process conn)))
    (let ((orig (process-sentinel proc)))
      (set-process-sentinel
       proc
       (lambda (p event)
         (unless (process-live-p p)
           (unless (eq (fleet-eca-conn-state conn) 'lost)
             (setf (fleet-eca-conn-state conn) 'lost)
             (fleet-eca--cancel-watchdog conn)
             (fleet-eca--flush-assistant conn)
             (let ((turn (fleet-eca-conn-turn conn)))
               (fleet-eca--emit conn 'connection-lost :exit-status (process-exit-status p)
                                :event (string-trim event)
                                :in-flight-message (and turn (plist-get turn :message-id))
                                :in-flight-state (and turn (plist-get turn :state))))))
         (when orig (funcall orig p event)))))))

(defun fleet-eca--initialize (conn model agent variant callback)
  "Send initialize for CONN mirroring the frontend's own request; then register the chat."
  (let ((session (fleet-eca-conn-session conn)))
    (setf (eca--session-status session) 'starting)
    (eca-api-request-async
     session
     :method "initialize"
     :params (append (when eca-send-process-id (list :processId (emacs-pid)))
                     (list :clientInfo (list :name "emacs" :version (emacs-version))
                           :capabilities (list :codeAssistant (list :chat t
                                                                    :chatCapabilities (list :askQuestion t)
                                                                    :editor (list :diagnostics t)))
                           :initializationOptions (list :chatAgent (or agent eca-chat-custom-agent))
                           :workspaceFolders (vconcat (mapcar (lambda (folder)
                                                                (list :uri (eca--path-to-uri folder)
                                                                      :name (file-name-nondirectory (directory-file-name folder))))
                                                              (eca--session-workspace-folders session)))))
     :success-callback
     (lambda (res)
       (setf (eca--session-status session) 'started)
       (setf (eca--session-chat-welcome-message session) (or (plist-get res :chatWelcomeMessage) ""))
       (eca-api-notify session :method "initialized")
       ;; Readiness requires models: the server answers earlier prompts with an error turn.
       (fleet-eca--when-models
        conn
        (lambda (ok)
          (if (not ok)
              (progn (setf (fleet-eca-conn-state conn) 'lost)
                     (fleet-eca--emit conn 'protocol-error :phase "models" :error "no models announced before deadline")
                     (funcall callback nil "server announced no models before the deadline"))
            (condition-case err
                (progn
                  (fleet-eca--create-chat conn model agent variant)
                  (setf (fleet-eca-conn-state conn) 'ready)
                  (fleet-eca--emit conn 'connection-ready :tool-servers (mapcar #'car (fleet-eca-conn-tool-servers conn)))
                  (funcall callback t nil))
              (error (funcall callback nil (error-message-string err))))))))
     :error-callback
     (lambda (e)
       (setf (fleet-eca-conn-state conn) 'lost)
       (fleet-eca--emit conn 'protocol-error :phase "initialize" :error (format "%S" e))
       (funcall callback nil (format "initialize failed: %S" e))))))

(defun fleet-eca--when-models (conn k)
  "Call K with t once CONN's server announced models, or nil after the deadline."
  (if (fleet-eca-conn-models-ready conn)
      (funcall k t)
    (let ((timer nil) (done nil))
      (setf (fleet-eca-conn-on-models conn)
            (lambda ()
              (unless done (setq done t) (when timer (cancel-timer timer)) (funcall k t))))
      (setq timer (run-with-timer fleet-eca-models-timeout-sec nil
                                  (lambda ()
                                    (unless done (setq done t)
                                            (setf (fleet-eca-conn-on-models conn) nil)
                                            (funcall k nil))))))))

(defun fleet-eca--observe-config (conn params)
  "Record model availability from a config/updated notification PARAMS."
  (let ((chat (plist-get params :chat)))
    (when (and chat (plist-get chat :models) (> (length (plist-get chat :models)) 0))
      (unless (fleet-eca-conn-models-ready conn)
        (setf (fleet-eca-conn-models-ready conn) t)
        (fleet-eca--emit conn 'models-ready :default-model (plist-get chat :selectModel))
        (when-let* ((k (fleet-eca-conn-on-models conn)))
          (setf (fleet-eca-conn-on-models conn) nil)
          (funcall k))))))

(defun fleet-eca--create-chat (conn model agent variant)
  "Create and register CONN's designated chat buffer silently (no window changes).
Mirrors the buffer-setup half of `eca-chat-open' without its display half."
  (let* ((session (fleet-eca-conn-session conn))
         (buf (generate-new-buffer (fleet-eca-conn-display-name conn))))
    (with-current-buffer buf
      (let ((eca--chat-init-session session))
        (eca-chat-mode))
      (setq-local eca--session-id-cache (eca--session-id session))
      (setq-local eca-chat--id (fleet-eca-conn-chat-id conn))
      (setq-local eca-chat--selected-model model)
      (setq-local eca-chat--selected-agent agent)
      (setq-local eca-chat--selected-variant variant)
      (setq-local eca-chat--selected-trust nil)
      (setq-local fleet-eca-runtime-id (fleet-eca-conn-runtime-id conn))
      (add-hook 'kill-buffer-query-functions #'fleet-eca--refuse-kill nil t))
    (setf (eca--session-chats session) (eca-assoc (eca--session-chats session) (fleet-eca-conn-chat-id conn) buf))
    (setf (eca--session-last-chat-buffer session) buf)
    (setf (fleet-eca-conn-buffer conn) buf)
    buf))

(defun fleet-eca--refuse-kill ()
  "Refuse to kill a live Fleet chat buffer; bury it instead."
  (let ((conn (fleet-eca--conn-for-buffer)))
    (if (and conn (memq (fleet-eca-conn-state conn) '(connecting ready)))
        (progn (bury-buffer) (message "Fleet chat hidden; use M-x fleet-commander-stop / dashboard t to stop it") nil)
      t)))

;;;; Submission

(cl-defun fleet-eca-submit (conn &key message-id text contexts callback)
  "Submit TEXT as the single in-flight turn of CONN.
CALLBACK is invoked once with (:outcome accepted|rejected|delivery-unknown|observed-unacknowledged
:message-id ID :evidence PLIST).  Terminal turn events reach the sink separately."
  (cond
   ((not (eq (fleet-eca-conn-state conn) 'ready))
    (funcall callback (list :outcome 'rejected :message-id message-id :code 'connection-not-ready
                            :evidence (list :state (fleet-eca-conn-state conn)))))
   ((fleet-eca-conn-turn conn)
    (funcall callback (list :outcome 'rejected :message-id message-id :code 'lane-busy
                            :evidence (list :in-flight (plist-get (fleet-eca-conn-turn conn) :message-id)))))
   ((not (process-live-p (fleet-eca-conn-process conn)))
    (setf (fleet-eca-conn-state conn) 'lost)
    (funcall callback (list :outcome 'rejected :message-id message-id :code 'process-dead :evidence nil)))
   (t
    (let* ((session (fleet-eca-conn-session conn))
           (buf (fleet-eca-conn-buffer conn))
           (params (with-current-buffer buf
                     (append (list :message text
                                   :request-id (cl-incf eca-chat--last-request-id)
                                   :chatId eca-chat--id
                                   :model (eca-chat--model)
                                   :agent (eca-chat--agent)
                                   :contexts (vconcat (mapcar #'eca-chat--refine-context (append eca-chat--context contexts))))
                             (when-let* ((v (eca-chat--variant)))
                               (unless (string= v "-") (list :variant v)))
                             (when (eca-chat--trust) (list :trust t)))))
           (turn (list :message-id message-id :request-id (plist-get params :request-id)
                       :state 'submitted :submitted-at (fleet-paths-now) :callback callback)))
      (setf (fleet-eca-conn-turn conn) turn)
      (fleet-eca--transcript conn (list :role "fleet" :kind "submit" :message-id message-id :text (fleet-eca--clip text 4000)))
      (let ((fleet-eca--dispatching t))
        ;; Mirror the UI loading state so the chat shows the turn, without touching the draft.
        (with-current-buffer buf (eca-chat--set-chat-loading session t))
        (eca-api-request-async
         session :method "chat/prompt" :params params
         :success-callback
         (lambda (res)
           (fleet-eca--on-prompt-response conn message-id res nil))
         :error-callback
         (lambda (err)
           (fleet-eca--on-prompt-response conn message-id nil err))))
      (setf (fleet-eca-conn-watchdog conn)
            (run-with-timer fleet-eca-ack-timeout-sec nil #'fleet-eca--watchdog conn message-id))))))

(defun fleet-eca--turn-for (conn message-id)
  "CONN's in-flight turn if it is MESSAGE-ID."
  (let ((turn (fleet-eca-conn-turn conn)))
    (and turn (equal (plist-get turn :message-id) message-id) turn)))

(defun fleet-eca--resolve-submission (conn turn outcome &rest evidence)
  "Invoke TURN's submission callback once with OUTCOME and EVIDENCE."
  (when-let* ((cb (plist-get turn :callback)))
    (plist-put turn :callback nil)
    (fleet-eca--cancel-watchdog conn)
    (funcall cb (list :outcome outcome :message-id (plist-get turn :message-id) :evidence evidence))))

(defun fleet-eca--on-prompt-response (conn message-id res err)
  "Handle the chat/prompt response RES or transport error ERR for MESSAGE-ID."
  (when-let* ((turn (fleet-eca--turn-for conn message-id)))
    (let ((status (plist-get res :status)))
      (cond
       (err
        (plist-put turn :state 'rejected)
        (setf (fleet-eca-conn-turn conn) nil)
        (fleet-eca--ui-idle conn)
        (fleet-eca--emit conn 'prompt-rejected :message-id message-id :error (format "%S" err))
        (fleet-eca--resolve-submission conn turn 'rejected :error (format "%S" err)))
       ((equal status "prompting")
        (plist-put turn :accepted t)
        (fleet-eca--emit conn 'prompt-accepted :message-id message-id :model (plist-get res :model)
                         :running-seen (plist-get turn :running-seen))
        (fleet-eca--resolve-submission conn turn 'accepted :status status :model (plist-get res :model)))
       (t
        ;; status "error" (or unknown) is a definite rejection; the server
        ;; already emitted idle/finished for this chat before responding.
        (plist-put turn :state 'rejected)
        (setf (fleet-eca-conn-turn conn) nil)
        (fleet-eca--ui-idle conn)
        (fleet-eca--emit conn 'prompt-rejected :message-id message-id :status status
                         :error (plist-get turn :error-text))
        (fleet-eca--resolve-submission conn turn 'rejected :status status :error (plist-get turn :error-text)))))))

(defun fleet-eca--watchdog (conn message-id)
  "Acknowledgment deadline for MESSAGE-ID on CONN."
  (setf (fleet-eca-conn-watchdog conn) nil)
  (when-let* ((turn (fleet-eca--turn-for conn message-id)))
    (unless (plist-get turn :accepted)
      (if (plist-get turn :running-seen)
          (progn
            (fleet-eca--emit conn 'ack-timeout :message-id message-id :running-seen t)
            (fleet-eca--resolve-submission conn turn 'observed-unacknowledged :running-seen t))
        ;; Neither response nor execution evidence: freeze the lane.
        (plist-put turn :state 'delivery-unknown)
        (fleet-eca--emit conn 'delivery-unknown :message-id message-id)
        (fleet-eca--resolve-submission conn turn 'delivery-unknown)))))

(defun fleet-eca--cancel-watchdog (conn)
  "Cancel CONN's acknowledgment timer."
  (when-let* ((tm (fleet-eca-conn-watchdog conn)))
    (cancel-timer tm)
    (setf (fleet-eca-conn-watchdog conn) nil)))

(defun fleet-eca--ui-idle (conn)
  "Return the chat UI to idle after a definite rejection."
  (when (buffer-live-p (fleet-eca-conn-buffer conn))
    (with-current-buffer (fleet-eca-conn-buffer conn)
      (let ((fleet-eca--dispatching t))
        (eca-chat--set-chat-loading (fleet-eca-conn-session conn) nil)))))

;;;; Observation of the wire

(defun fleet-eca--observe (conn msg)
  "Normalize raw JSON-RPC MSG for CONN into Fleet events.  Runs before the UI handler."
  (let ((method (plist-get msg :method))
        (params (plist-get msg :params)))
    (when method
      (pcase method
        ("chat/statusChanged" (fleet-eca--observe-status conn params))
        ("chat/contentReceived" (fleet-eca--observe-content conn params))
        ("chat/askQuestion" (when (plist-get msg :id) (fleet-eca--observe-question conn msg params)))
        ("config/updated" (fleet-eca--observe-config conn params))
        ("tool/serverUpdated"
         (let ((name (plist-get params :name)))
           (setf (alist-get name (fleet-eca-conn-tool-servers conn) nil nil #'equal)
                 (list :status (plist-get params :status)
                       :tools (mapcar (lambda (tl) (plist-get tl :name)) (append (plist-get params :tools) nil))))
           (fleet-eca--emit conn 'tool-server-updated :name name :status (plist-get params :status)
                            :tools (mapcar (lambda (tl) (plist-get tl :name)) (append (plist-get params :tools) nil)))))
        ("$/showMessage" (when (equal (plist-get params :type) "error")
                           (fleet-eca--emit conn 'server-message :level "error" :text (plist-get params :message))))
        (_ nil)))))

(defun fleet-eca--own-chat-p (conn params)
  "Non-nil when PARAMS address CONN's designated top-level chat."
  (and (equal (plist-get params :chatId) (fleet-eca-conn-chat-id conn))
       (null (plist-get params :parentChatId))))

(defun fleet-eca--observe-status (conn params)
  "Handle chat/statusChanged PARAMS."
  (when (fleet-eca--own-chat-p conn params)
    (pcase (plist-get params :status)
      ("running" (fleet-eca--turn-running conn))
      ("stopping" (when-let* ((turn (fleet-eca-conn-turn conn)))
                    (plist-put turn :state 'stopping)
                    (fleet-eca--emit conn 'turn-stopping :message-id (plist-get turn :message-id))))
      ("idle" (fleet-eca--turn-terminal conn "statusChanged idle"))
      (_ nil))))

(defun fleet-eca--turn-running (conn)
  "Record observed execution start."
  (let ((turn (fleet-eca-conn-turn conn)))
    (cond
     ((and turn (not (plist-get turn :running-seen)))
      (plist-put turn :running-seen t)
      (plist-put turn :state 'running)
      (fleet-eca--emit conn 'turn-started :message-id (plist-get turn :message-id)
                       :accepted (plist-get turn :accepted)))
     ((null turn)
      ;; Execution without a Fleet-submitted turn: someone bypassed the lane
      ;; (or a native control reply restarted generation).  Record it so the
      ;; runtime is not considered quiescent, but attribute nothing.
      (setf (fleet-eca-conn-turn conn) (list :message-id nil :state 'running :running-seen t :unattributed t
                                             :submitted-at (fleet-paths-now)))
      (fleet-eca--emit conn 'turn-started :message-id nil :unattributed t)))))

(defun fleet-eca--turn-terminal (conn source)
  "Consume the terminal activity event from SOURCE exactly once."
  (let ((turn (fleet-eca-conn-turn conn)))
    (if (null turn)
        (fleet-eca--emit conn 'turn-idle-duplicate :source source)
      (setf (fleet-eca-conn-turn conn) nil)
      (fleet-eca--cancel-watchdog conn)
      (fleet-eca--flush-assistant conn)
      (setf (fleet-eca-conn-active-tools conn) nil)
      (fleet-eca--emit conn 'turn-idle-observed :message-id (plist-get turn :message-id)
                       :source source :was-stopping (eq (plist-get turn :state) 'stopping)
                       :unattributed (plist-get turn :unattributed)
                       :accepted (plist-get turn :accepted)
                       :error-text (plist-get turn :error-text))
      ;; A terminal event before the response resolves nothing yet; the
      ;; response (accepted/error) still arrives and is handled normally.
      (when (and (not (plist-get turn :accepted)) (plist-get turn :callback))
        (setf (fleet-eca-conn-turn conn) turn)
        (plist-put turn :state 'finished-before-ack)
        (run-with-timer 5 nil (lambda ()
                                (when (eq (fleet-eca-conn-turn conn) turn)
                                  (setf (fleet-eca-conn-turn conn) nil)
                                  (fleet-eca--resolve-submission conn turn 'observed-unacknowledged :finished t))))))))

(defun fleet-eca--observe-content (conn params)
  "Handle chat/contentReceived PARAMS."
  (let* ((content (plist-get params :content))
         (type (plist-get content :type))
         (role (plist-get params :role)))
    (cond
     ((and (plist-get params :parentChatId)
           (equal (plist-get params :parentChatId) (fleet-eca-conn-chat-id conn)))
      ;; Child activity keeps the runtime busy but can never finish the parent turn.
      (fleet-eca--emit conn 'subagent-activity :child-chat-id (plist-get params :chatId) :type type))
     ((not (equal (plist-get params :chatId) (fleet-eca-conn-chat-id conn))) nil)
     (t
      (pcase type
        ("progress"
         (pcase (plist-get content :state)
           ("running" (fleet-eca--emit conn 'progress :text (plist-get content :text)))
           ("finished" (fleet-eca--turn-terminal conn "progress finished"))))
        ("text"
         (let ((text (or (plist-get content :text) "")))
           (pcase role
             ("user" (fleet-eca--transcript conn (list :role "user" :kind "text" :text (fleet-eca--clip text 4000))))
             ("system"
              (when (string-match-p "\\`\\s-*Error:" text)
                (when-let* ((turn (fleet-eca-conn-turn conn))) (plist-put turn :error-text (fleet-eca--clip text 500)))
                (fleet-eca--emit conn 'turn-error-text :text (fleet-eca--clip text 500))))
             (_ (setf (fleet-eca-conn-assistant-buffer conn) (concat (fleet-eca-conn-assistant-buffer conn) text))
                (fleet-eca--emit conn 'assistant-text :chars (length text))))))
        ("metadata"
         (setf (fleet-eca-conn-title conn) (plist-get content :title))
         (fleet-eca--emit conn 'title :title (plist-get content :title)))
        ("toolCallPrepare"
         (let ((id (plist-get content :id)))
           (unless (assoc id (fleet-eca-conn-active-tools conn))
             (push (cons id (list :name (plist-get content :name) :server (plist-get content :server) :phase 'preparing :since (fleet-paths-now)))
                   (fleet-eca-conn-active-tools conn))
             (fleet-eca--emit conn 'tool-preparing :tool-id id :name (plist-get content :name) :server (plist-get content :server)))))
        ("toolCallRun"
         (let ((id (plist-get content :id)) (manual (eq t (plist-get content :manualApproval))))
           (fleet-eca--tool-phase conn id content (if manual 'approval 'starting))
           (if manual
               (progn (cl-pushnew id (fleet-eca-conn-pending-approvals conn) :test #'equal)
                      (fleet-eca--emit conn 'tool-approval-required :tool-id id :name (plist-get content :name)
                                       :server (plist-get content :server) :summary (plist-get content :summary)))
             (fleet-eca--emit conn 'tool-running :tool-id id :name (plist-get content :name) :server (plist-get content :server)))))
        ("toolCallRunning"
         (let ((id (plist-get content :id)))
           (setf (fleet-eca-conn-pending-approvals conn) (delete id (fleet-eca-conn-pending-approvals conn)))
           (fleet-eca--tool-phase conn id content 'running)
           (fleet-eca--emit conn 'tool-running :tool-id id :name (plist-get content :name) :server (plist-get content :server))))
        ("toolCalled"
         (let ((id (plist-get content :id)))
           (setf (fleet-eca-conn-pending-approvals conn) (delete id (fleet-eca-conn-pending-approvals conn)))
           (setf (fleet-eca-conn-active-tools conn) (assoc-delete-all id (fleet-eca-conn-active-tools conn)))
           (fleet-eca--transcript conn (list :role "tool" :kind "called" :tool-id id :name (plist-get content :name)
                                             :error (eq t (plist-get content :error)) :ms (plist-get content :totalTimeMs)))
           (fleet-eca--emit conn 'tool-finished :tool-id id :name (plist-get content :name)
                            :error (eq t (plist-get content :error)) :ms (plist-get content :totalTimeMs))))
        ("toolCallRejected"
         (let ((id (plist-get content :id)))
           (setf (fleet-eca-conn-pending-approvals conn) (delete id (fleet-eca-conn-pending-approvals conn)))
           (setf (fleet-eca-conn-active-tools conn) (assoc-delete-all id (fleet-eca-conn-active-tools conn)))
           (fleet-eca--emit conn 'tool-rejected :tool-id id :name (plist-get content :name))))
        (_ nil))))))

(defun fleet-eca--tool-phase (conn id content phase)
  "Record PHASE for tool call ID described by CONTENT."
  (let ((entry (assoc id (fleet-eca-conn-active-tools conn))))
    (if entry
        (setcdr entry (plist-put (cdr entry) :phase phase))
      (push (cons id (list :name (plist-get content :name) :server (plist-get content :server) :phase phase :since (fleet-paths-now)))
            (fleet-eca-conn-active-tools conn)))))

(defun fleet-eca--observe-question (conn msg params)
  "Capture a chat/askQuestion server request MSG before the UI renders it."
  (when (equal (plist-get params :chatId) (fleet-eca-conn-chat-id conn))
    (setf (fleet-eca-conn-pending-question conn)
          (list :request-id (plist-get msg :id) :question (plist-get params :question)
                :options (mapcar (lambda (o) (if (stringp o) o (plist-get o :label))) (append (plist-get params :options) nil))
                :tool-call-id (plist-get params :toolCallId)
                :allow-freeform (eq t (plist-get params :allowFreeform)) :opened-at (fleet-paths-now)))
    (fleet-eca--emit conn 'question-opened :question (plist-get params :question)
                     :options (plist-get (fleet-eca-conn-pending-question conn) :options)
                     :tool-call-id (plist-get params :toolCallId)
                     :request-id (plist-get msg :id))))

;;;; Control operations

(defun fleet-eca-request-cancel (conn)
  "Request cancellation of CONN's active turn.  Returns `cancel-requested' or nil."
  (when (and (eq (fleet-eca-conn-state conn) 'ready) (buffer-live-p (fleet-eca-conn-buffer conn)))
    (let ((session (fleet-eca-conn-session conn)) (turn (fleet-eca-conn-turn conn)))
      (with-current-buffer (fleet-eca-conn-buffer conn)
        (let ((fleet-eca--dispatching t))
          (if (or (eq eca-chat--chat-loading t) eca-chat--pending-question)
              (eca-chat--stop-prompt session)
            (eca-api-notify session :method "chat/promptStop" :params (list :chatId eca-chat--id)))))
      (when turn (plist-put turn :state 'cancel-requested))
      (fleet-eca--emit conn 'cancel-requested :message-id (and turn (plist-get turn :message-id)))
      'cancel-requested)))

(defun fleet-eca-answer-question (conn request-id answer)
  "Answer CONN's pending question REQUEST-ID with ANSWER (string or nil to cancel).
Refuses when REQUEST-ID does not match the exact pending item."
  (let ((pending (fleet-eca-conn-pending-question conn)))
    (unless (and pending (equal (plist-get pending :request-id) request-id))
      (fleet-fail 'no-such-question "No pending question with that id" :request-id request-id
                  :pending (and pending (plist-get pending :request-id))))
    (setf (fleet-eca-conn-pending-question conn) nil)
    (with-current-buffer (fleet-eca-conn-buffer conn)
      (let ((fleet-eca--dispatching t))
        (cond
         ((and eca-chat--pending-question answer) (eca-chat--answer-question answer))
         (eca-chat--pending-question (eca-chat--cancel-question))
         (t (eca-api-send-request-response (fleet-eca-conn-session conn) (list :id request-id)
                                           (if answer (list :answer answer :cancelled :json-false)
                                             (list :answer nil :cancelled t)))))))
    (fleet-eca--emit conn 'question-answered :request-id request-id :answer answer :by "fleet")
    t))

(defun fleet-eca-approve-tool (conn tool-id &optional reject)
  "Approve (or REJECT) exactly pending TOOL-ID on CONN."
  (unless (member tool-id (fleet-eca-conn-pending-approvals conn))
    (fleet-fail 'no-such-approval "Tool call is not pending approval" :tool-id tool-id))
  (eca-api-notify (fleet-eca-conn-session conn)
                  :method (if reject "chat/toolCallReject" "chat/toolCallApprove")
                  :params (list :chatId (fleet-eca-conn-chat-id conn) :toolCallId tool-id))
  (fleet-eca--emit conn (if reject 'tool-rejected-by-fleet 'tool-approved-by-fleet) :tool-id tool-id)
  t)

(defun fleet-eca-snapshot (conn)
  "Observed connection/chat/tool state of CONN (no task-state derivation)."
  (let ((turn (fleet-eca-conn-turn conn)))
    (list :runtime-id (fleet-eca-conn-runtime-id conn)
          :state (fleet-eca-conn-state conn)
          :process-live (and (fleet-eca-conn-process conn) (process-live-p (fleet-eca-conn-process conn)) t)
          :chat-id (fleet-eca-conn-chat-id conn)
          :buffer (and (buffer-live-p (fleet-eca-conn-buffer conn)) (buffer-name (fleet-eca-conn-buffer conn)))
          :turn (and turn (list :message-id (plist-get turn :message-id) :state (plist-get turn :state)
                                :accepted (plist-get turn :accepted) :running-seen (plist-get turn :running-seen)
                                :submitted-at (plist-get turn :submitted-at)))
          :pending-question (fleet-eca-conn-pending-question conn)
          :pending-approvals (fleet-eca-conn-pending-approvals conn)
          :active-tools (mapcar (lambda (e) (append (list :tool-id (car e)) (cdr e))) (fleet-eca-conn-active-tools conn))
          :draft (fleet-eca-draft conn)
          :title (fleet-eca-conn-title conn)
          :observation-revision (fleet-eca-conn-observation-revision conn))))

(defun fleet-eca-draft (conn)
  "Human draft text currently in CONN's composer, or nil when empty."
  (when (buffer-live-p (fleet-eca-conn-buffer conn))
    (with-current-buffer (fleet-eca-conn-buffer conn)
      (let ((d (ignore-errors (eca-chat--prompt-content))))
        (and d (not (string-empty-p d)) d)))))

(defun fleet-eca-visit (conn)
  "Display CONN's real chat buffer; return it, or nil when unavailable."
  (when (buffer-live-p (fleet-eca-conn-buffer conn))
    (pop-to-buffer (fleet-eca-conn-buffer conn))
    (fleet-eca-conn-buffer conn)))

(defun fleet-eca-peek (conn lines)
  "Last LINES logical lines of CONN's chat, from the live buffer or the transcript."
  (cond
   ((buffer-live-p (fleet-eca-conn-buffer conn))
    (with-current-buffer (fleet-eca-conn-buffer conn)
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (string-join (last (split-string text "\n") lines) "\n"))))
   ((and (fleet-eca-conn-transcript-file conn) (file-readable-p (fleet-eca-conn-transcript-file conn)))
    (fleet-eca-transcript-tail (fleet-eca-conn-transcript-file conn) lines))
   (t nil)))

(defun fleet-eca-transcript-tail (file lines)
  "Render the last LINES entries of transcript FILE as text."
  (let ((entries (last (split-string (or (fleet-paths-read-file file) "") "\n" t) lines)))
    (mapconcat (lambda (line)
                 (let ((e (ignore-errors (fleet-store-unjson line))))
                   (if e (format "[%s] %s: %s" (plist-get e :at) (plist-get e :role)
                                 (or (plist-get e :text) (plist-get e :name) (plist-get e :kind)))
                     line)))
               entries "\n")))

(defun fleet-eca-detach (conn)
  "Unregister CONN after its runtime was stopped by the runtime owner.
Retains the chat buffer under a runtime-suffixed name; never kills processes."
  (fleet-eca--cancel-watchdog conn)
  (fleet-eca--flush-assistant conn)
  (setf (fleet-eca-conn-state conn) 'detached)
  (when (buffer-live-p (fleet-eca-conn-buffer conn))
    (with-current-buffer (fleet-eca-conn-buffer conn)
      (rename-buffer (format "%s:%s" (fleet-eca-conn-display-name conn)
                             (fleet-paths-short-id (fleet-eca-conn-runtime-id conn)))
                     t)))
  (remhash (fleet-eca-conn-runtime-id conn) fleet-eca--conns)
  t)

;;;; Human-submission ownership (advice on Fleet chats only)

(defun fleet-eca--admit-human (conn prompt)
  "Route human PROMPT from CONN's chat through Fleet's admission; clear the draft only on success."
  (let* ((contexts (append eca-chat--context (eca-chat--extract-contexts-from-prompt)))
         (envelope (list :text (eca-chat--normalize-prompt prompt)
                         :contexts (mapcar #'eca-chat--refine-context contexts)
                         :model (eca-chat--model) :agent (eca-chat--agent) :variant (eca-chat--variant))))
    (unless fleet-eca-human-sink
      (user-error "Fleet is not supervising this chat; message not sent"))
    (let ((admitted (condition-case err
                        (funcall fleet-eca-human-sink conn envelope)
                      (fleet-error (message "Fleet refused the message: %s" (fleet-error-string err)) nil)
                      (error (message "Fleet could not admit the message: %s" (error-message-string err)) nil))))
      (when admitted
        (add-to-list 'eca-chat--history prompt)
        (eca-chat--set-prompt "")
        (message "Fleet: message queued (%s)" (if (fleet-eca-conn-turn conn) "operator busy; will send when idle" "sending")))
      admitted)))

(defun fleet-eca--around-send (orig session prompt)
  "Advice for the native send/steer/queue entry points."
  (let ((conn (fleet-eca--conn-for-buffer)))
    (if (or (null conn) fleet-eca--dispatching)
        (funcall orig session prompt)
      (fleet-eca--admit-human conn prompt))))

(defun fleet-eca--around-queue (orig prompt)
  "Advice for `eca-chat--queue-prompt' (single argument)."
  (let ((conn (fleet-eca--conn-for-buffer)))
    (if (or (null conn) fleet-eca--dispatching)
        (funcall orig prompt)
      (fleet-eca--admit-human conn prompt))))

(defun fleet-eca--around-native-dispatch (orig &rest args)
  "Transport guard: native queue/steer auto-dispatch is disabled on Fleet chats."
  (if (fleet-eca--conn-for-buffer)
      (progn (setq-local eca-chat--queued-prompt nil) (setq-local eca-chat--steered-prompt nil) nil)
    (apply orig args)))

(defun fleet-eca--around-guarded-command (orig &rest args)
  "Refuse destructive native chat/session commands on Fleet-owned sessions."
  (let ((conn (or (fleet-eca--conn-for-buffer)
                  (and (fboundp 'eca-session) (ignore-errors (fleet-eca--conn-for-session (eca-session)))))))
    (if (and conn (memq (fleet-eca-conn-state conn) '(connecting ready)))
        (user-error "This chat is a Fleet %s runtime; use the Fleet dashboard (t/X) or M-x fleet-commander-stop / fleet-commander-replace"
                    (fleet-eca-conn-role conn))
      (apply orig args))))

(defun fleet-eca--after-question-answered (&rest _)
  "Advice: clear the captured question when the human answers in the chat."
  (when-let* ((conn (fleet-eca--conn-for-buffer)))
    (when (and (fleet-eca-conn-pending-question conn) (not fleet-eca--dispatching))
      (let ((rid (plist-get (fleet-eca-conn-pending-question conn) :request-id)))
        (setf (fleet-eca-conn-pending-question conn) nil)
        (fleet-eca--emit conn 'question-answered :request-id rid :by "human")))))

(defconst fleet-eca--advice
  '((eca-chat--send-prompt :around fleet-eca--around-send)
    (eca-chat--steer-prompt :around fleet-eca--around-send)
    (eca-chat--queue-prompt :around fleet-eca--around-queue)
    (eca-chat--send-queued-prompt :around fleet-eca--around-native-dispatch)
    (eca-chat--send-steered-prompt :around fleet-eca--around-native-dispatch)
    (eca-chat-new :around fleet-eca--around-guarded-command)
    (eca-chat-select :around fleet-eca--around-guarded-command)
    (eca-chat-resume :around fleet-eca--around-guarded-command)
    (eca-chat-reset :around fleet-eca--around-guarded-command)
    (eca-chat-clear :around fleet-eca--around-guarded-command)
    (eca-stop :around fleet-eca--around-guarded-command)
    (eca-restart :around fleet-eca--around-guarded-command)
    (eca-chat--answer-question :after fleet-eca--after-question-answered)
    (eca-chat--cancel-question :after fleet-eca--after-question-answered))
  "Advice installed only while Fleet runtimes exist.  Idempotent.")

(defun fleet-eca-install-advice ()
  "Install Fleet's narrow advice on ECA (idempotent)."
  (pcase-dolist (`(,sym ,where ,fn) fleet-eca--advice)
    (when (fboundp sym) (advice-add sym where fn))))

(defun fleet-eca-uninstall-advice ()
  "Remove all Fleet advice from ECA."
  (pcase-dolist (`(,sym ,_where ,fn) fleet-eca--advice)
    (when (fboundp sym) (advice-remove sym fn))))

(defun fleet-eca-unload-function ()
  "Clean up advice on `unload-feature'."
  (fleet-eca-uninstall-advice)
  nil)

(provide 'fleet-eca)
;;; fleet-eca.el ends here
