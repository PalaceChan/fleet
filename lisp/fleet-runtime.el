;;; fleet-runtime.el --- systemd user-service lifetime for ECA runtimes -*- lexical-binding: t; -*-

;;; Commentary:

;; Sole owner of local execution accounting.  Every ECA runtime is a
;; transient systemd *user service* named after its runtime UUID, launched
;; through `systemd-run --pipe --wait' so the Emacs process object is only a
;; wrapper; the service's cgroup is the accountable unit of execution.
;;
;; The only strong stop verdict is: exact unit inactive/collected AND its
;; recorded cgroup recursively empty, from an unambiguous successful
;; query.  Everything else stays `running' or `stop-unknown'.
;;
;; All systemd waits are asynchronous (`make-process' callbacks).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'fleet-paths)

(defvar fleet-runtime-systemctl "systemctl"
  "systemctl executable.  Tests substitute a fake.")

(defvar fleet-runtime-systemd-run "systemd-run"
  "systemd-run executable.  Tests substitute a fake.")

(defvar fleet-runtime-cgroup-root "/sys/fs/cgroup"
  "Mount point of the unified cgroup hierarchy.")

(defconst fleet-runtime-stop-timeout-sec 15
  "Graceful stop bound before systemd's final SIGKILL.  A resource bound,
never a work-duration cap.")

(defconst fleet-runtime-stop-observe-timeout-sec 40
  "How long `fleet-runtime-stop' keeps inspecting before declaring unknown.")

(defconst fleet-runtime-propagated-variables
  '("HOME" "PATH" "LANG" "LC_ALL" "LC_CTYPE" "TERM" "USER" "LOGNAME" "SHELL"
    "XDG_CONFIG_HOME" "XDG_DATA_HOME" "XDG_RUNTIME_DIR"
    "SSH_AUTH_SOCK" "GPG_TTY"
    "HTTP_PROXY" "HTTPS_PROXY" "NO_PROXY" "http_proxy" "https_proxy" "no_proxy"
    "GITHUB_TOKEN" "GH_TOKEN")
  "Environment variable NAMES copied verbatim into a runtime when set.
Values are never recorded; see `fleet-runtime-provider-variable-p' for
provider credentials selected by pattern.")

(defun fleet-runtime-provider-variable-p (name)
  "Non-nil when NAME looks like a provider credential/config variable."
  (string-match-p (rx bos (or (seq (+ (any "A-Z0-9_")) "_API_KEY")
                              (seq (or "ANTHROPIC" "OPENAI" "OPENROUTER" "GEMINI" "GOOGLE" "AZURE"
                                       "AWS" "OLLAMA" "DEEPSEEK" "MISTRAL" "GROQ" "XAI" "ECA")
                                   "_" (+ (any "A-Z0-9_"))))
                      eos)
                  name))

(defun fleet-runtime-unit-name (runtime-id)
  "Exact transient unit name for RUNTIME-ID."
  (format "fleet-eca-%s.service" runtime-id))

(defun fleet-runtime-selected-variables ()
  "Names of environment variables to propagate from this Emacs."
  (cl-remove-duplicates
   (append (cl-remove-if-not #'getenv fleet-runtime-propagated-variables)
           (cl-loop for entry in process-environment
                    for name = (car (split-string entry "="))
                    when (and (fleet-runtime-provider-variable-p name) (getenv name))
                    collect name))
   :test #'string=))

(cl-defun fleet-runtime-wrapper-argv (unit command &key cwd setenv)
  "Build the systemd-run argument vector wrapping COMMAND for UNIT.
CWD is the working directory; SETENV is a list of variable NAMES whose
values systemd-run copies from its own environment.  Protocol stdout is
passed through untouched (`--pipe'); `--quiet' keeps systemd chatter off it."
  (append (list fleet-runtime-systemd-run
                "--user" "--quiet" "--pipe" "--wait" "--collect"
                "--service-type=exec"
                (concat "--unit=" unit)
                "-p" "KillMode=control-group"
                "-p" (format "TimeoutStopSec=%d" fleet-runtime-stop-timeout-sec)
                "-p" "Restart=no")
          (when cwd (list (concat "--working-directory=" cwd)))
          (mapcar (lambda (n) (concat "--setenv=" n)) setenv)
          (list "--")
          command))

;;;; Process helper

(defun fleet-runtime--run (argv callback)
  "Run ARGV asynchronously; CALLBACK gets (:exit N :stdout S :stderr S)."
  (let* ((out (generate-new-buffer " *fleet-runtime-out*" t))
         (err (generate-new-buffer " *fleet-runtime-err*" t)))
    (condition-case e
        (make-process
         :name "fleet-runtime" :command argv :buffer out :stderr err :noquery t
         :connection-type 'pipe
         :sentinel
         (lambda (proc _event)
           (unless (process-live-p proc)
             (let ((code (process-exit-status proc))
                   (stdout (with-current-buffer out (buffer-string)))
                   (stderr (with-current-buffer err (buffer-string))))
               (kill-buffer out) (kill-buffer err)
               (funcall callback (list :exit code :stdout stdout :stderr stderr))))))
      (error
       (kill-buffer out) (kill-buffer err)
       (funcall callback (list :exit -1 :stdout "" :stderr (error-message-string e)))))))

;;;; Inspection

(defconst fleet-runtime--show-properties
  "LoadState,ActiveState,SubState,MainPID,ControlGroup,InvocationID,Job,Result,ExecMainStartTimestampMonotonic")

(defun fleet-runtime--parse-show (text)
  "Parse `systemctl show' TEXT into a plist with keyword keys."
  (let (out)
    (dolist (line (split-string text "\n" t))
      (when (string-match "\\`\\([A-Za-z]+\\)=\\(.*\\)\\'" line)
        (setq out (plist-put out (intern (concat ":" (match-string 1 line))) (match-string 2 line)))))
    out))

(defun fleet-runtime-cgroup-populated (control-group)
  "Return t, nil, or `absent' for recursive population of CONTROL-GROUP."
  (if (or (null control-group) (string-empty-p control-group))
      'absent
    (let ((events (expand-file-name (concat "." control-group "/cgroup.events") fleet-runtime-cgroup-root)))
      (if (not (file-readable-p events))
          'absent
        (let ((content (fleet-paths-read-file events)))
          (cond ((string-match "populated \\([01]\\)" content)
                 (string= (match-string 1 content) "1"))
                (t 'unknown)))))))

(defun fleet-runtime-inspect (unit recorded-cgroup callback)
  "Query UNIT via systemctl and RECORDED-CGROUP population; CALLBACK gets an inspection plist.
Keys: :query-ok :load-state :active-state :sub-state :main-pid :control-group
:invocation-id :job :result :cgroup-populated :boot-id :raw :error."
  (fleet-runtime--run
   (list fleet-runtime-systemctl "--user" "show" unit "-p" fleet-runtime--show-properties)
   (lambda (r)
     (if (/= 0 (plist-get r :exit))
         (funcall callback (list :query-ok nil :unit unit :error (plist-get r :stderr) :exit (plist-get r :exit)
                                 :boot-id (fleet-paths-boot-id)))
       (let* ((p (fleet-runtime--parse-show (plist-get r :stdout)))
              (cg (let ((live (plist-get p :ControlGroup)))
                    (if (and live (not (string-empty-p live))) live recorded-cgroup))))
         (funcall callback
                  (list :query-ok t :unit unit
                        :load-state (plist-get p :LoadState)
                        :active-state (plist-get p :ActiveState)
                        :sub-state (plist-get p :SubState)
                        :main-pid (string-to-number (or (plist-get p :MainPID) "0"))
                        :control-group cg
                        :invocation-id (plist-get p :InvocationID)
                        :job (plist-get p :Job)
                        :result (plist-get p :Result)
                        :cgroup-populated (fleet-runtime-cgroup-populated cg)
                        :boot-id (fleet-paths-boot-id)
                        :raw (plist-get r :stdout))))))))

;;;; Verdict (pure; design §6.3)

(defun fleet-runtime-verdict (launch-state recorded-boot-id inspection)
  "Classify runtime execution from LAUNCH-STATE, RECORDED-BOOT-ID and INSPECTION.
LAUNCH-STATE is `unresolved', `created', or `never-created'.
Returns one of `launch-unresolved', `stop-unknown', `previous-boot',
`never-launched', `running', `stopped'."
  (let ((job (plist-get inspection :job))
        (load (plist-get inspection :load-state))
        (active (plist-get inspection :active-state))
        (populated (plist-get inspection :cgroup-populated))
        (current-boot (plist-get inspection :boot-id)))
    (cond
     ((eq launch-state 'unresolved) 'launch-unresolved)
     ((not (plist-get inspection :query-ok)) 'stop-unknown)
     ((and recorded-boot-id current-boot (not (string= recorded-boot-id current-boot))) 'previous-boot)
     ((and job (not (string-empty-p job))) 'running)
     ((member active '("active" "activating" "deactivating" "reloading")) 'running)
     ((eq populated t) 'running)
     ((and (eq launch-state 'never-created) (equal load "not-found")) 'never-launched)
     ((and (member load '("not-found" "loaded"))
           (or (member active '("inactive" "failed")) (equal load "not-found"))
           (memq populated '(nil absent)))
      'stopped)
     (t 'stop-unknown))))

;;;; Stop

(defun fleet-runtime-stop (unit recorded-cgroup recorded-boot-id callback)
  "Stop UNIT and inspect until a terminal verdict or timeout.
CALLBACK receives (:verdict SYMBOL :inspection PLIST :stop-exit N :stop-stderr S)."
  (fleet-runtime--run
   (list fleet-runtime-systemctl "--user" "stop" "--no-block" unit)
   (lambda (stop)
     (let ((deadline (+ (float-time) fleet-runtime-stop-observe-timeout-sec)))
       (fleet-runtime--observe-until-stopped
        unit recorded-cgroup recorded-boot-id deadline
        (lambda (verdict inspection)
          (funcall callback (list :verdict verdict :inspection inspection
                                  :stop-exit (plist-get stop :exit)
                                  :stop-stderr (plist-get stop :stderr)))))))))

(defun fleet-runtime--observe-until-stopped (unit cgroup boot-id deadline callback)
  "Poll UNIT/CGROUP with backoff until stopped/never-launched/previous-boot or DEADLINE."
  (fleet-runtime-inspect
   unit cgroup
   (lambda (insp)
     (let ((verdict (fleet-runtime-verdict 'created boot-id insp)))
       (cond
        ((memq verdict '(stopped never-launched previous-boot))
         (funcall callback verdict insp))
        ((> (float-time) deadline)
         (funcall callback (if (eq verdict 'running) 'stop-unknown verdict) insp))
        (t (run-with-timer 0.5 nil #'fleet-runtime--observe-until-stopped
                           unit cgroup boot-id deadline callback)))))))

;;;; Launch record

(defun fleet-runtime-launch-record (runtime-id unit command cwd setenv)
  "Non-secret launch fingerprint for launch.json."
  (list :runtime-id runtime-id :unit unit :command (apply #'vector command)
        :cwd cwd :setenv (apply #'vector setenv)
        :boot-id (fleet-paths-boot-id) :emacs-pid (emacs-pid)
        :created-at (fleet-paths-now)))

(provide 'fleet-runtime)
;;; fleet-runtime.el ends here
