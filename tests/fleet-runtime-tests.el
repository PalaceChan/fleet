;;; fleet-runtime-tests.el --- Tests for fleet-runtime -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)
(require 'fleet-runtime)
(require 'fleet-test-helpers)

(defun fleet-runtime-test-fake-systemctl (dir script-body)
  "Create an executable fake systemctl in DIR from SCRIPT-BODY; return its path."
  (let ((f (expand-file-name "systemctl" dir)))
    (fleet-test-write f (concat "#!/bin/sh\n" script-body))
    (set-file-modes f #o700)
    f))

(defun fleet-runtime-test-inspect (unit cgroup)
  "Synchronously inspect UNIT with the current fake."
  (let (result)
    (fleet-runtime-inspect unit cgroup (lambda (r) (setq result r)))
    (fleet-test-wait-for (lambda () result) 5)
    result))

(ert-deftest fleet-runtime-wrapper-argv-shape ()
  (let ((argv (fleet-runtime-wrapper-argv "fleet-eca-abc.service" '("/bin/eca" "server")
                                          :cwd "/w" :setenv '("HOME" "PATH"))))
    (should (equal (car argv) fleet-runtime-systemd-run))
    (should (member "--pipe" argv))
    (should (member "--wait" argv))
    (should (member "--collect" argv))
    (should (member "--quiet" argv))
    (should (member "--unit=fleet-eca-abc.service" argv))
    (should (member "KillMode=control-group" argv))
    (should (member "Restart=no" argv))
    (should (member "--working-directory=/w" argv))
    (should (member "--setenv=HOME" argv))
    (should (member "--setenv=PATH" argv))
    ;; never a value in the argv
    (should-not (cl-some (lambda (a) (string-match-p "=.*=" a)) (cl-remove-if-not (lambda (a) (string-prefix-p "--setenv" a)) argv)))
    (should (equal (last argv 2) '("/bin/eca" "server")))
    (should-not (member "--verbose" argv))))

(ert-deftest fleet-runtime-provider-variable-selection ()
  (should (fleet-runtime-provider-variable-p "OPENAI_API_KEY"))
  (should (fleet-runtime-provider-variable-p "ANTHROPIC_BASE_URL"))
  ;; ECA_* markers of the spawning chat must not leak; Fleet sets ECA_CONFIG itself
  (should-not (fleet-runtime-provider-variable-p "ECA_CONFIG"))
  (should-not (fleet-runtime-provider-variable-p "ECA_CHAT_ID"))
  (should-not (fleet-runtime-provider-variable-p "PATH"))
  (should-not (fleet-runtime-provider-variable-p "MY_SECRET")))

(ert-deftest fleet-runtime-verdict-table ()
  (let ((boot "b1"))
    (cl-flet ((v (launch insp) (fleet-runtime-verdict launch boot insp)))
      ;; launch barrier first
      (should (eq 'launch-unresolved (v 'unresolved '(:query-ok t :load-state "not-found" :boot-id "b1"))))
      ;; failed query is unknown
      (should (eq 'stop-unknown (v 'created '(:query-ok nil :boot-id "b1"))))
      ;; previous boot
      (should (eq 'previous-boot (v 'created '(:query-ok t :load-state "not-found" :boot-id "b2"))))
      ;; pending job or active states are running
      (should (eq 'running (v 'created '(:query-ok t :load-state "loaded" :active-state "inactive" :job "12 start" :boot-id "b1" :cgroup-populated absent))))
      (should (eq 'running (v 'created '(:query-ok t :load-state "loaded" :active-state "active" :job "" :boot-id "b1" :cgroup-populated t))))
      (should (eq 'running (v 'created '(:query-ok t :load-state "loaded" :active-state "deactivating" :job "" :boot-id "b1" :cgroup-populated t))))
      ;; unit gone but cgroup still populated => running, never stopped
      (should (eq 'running (v 'created '(:query-ok t :load-state "not-found" :active-state "inactive" :job "" :boot-id "b1" :cgroup-populated t))))
      ;; inactive + empty cgroup => stopped
      (should (eq 'stopped (v 'created '(:query-ok t :load-state "loaded" :active-state "inactive" :job "" :boot-id "b1" :cgroup-populated nil))))
      (should (eq 'stopped (v 'created '(:query-ok t :load-state "loaded" :active-state "failed" :job "" :boot-id "b1" :cgroup-populated absent))))
      ;; collected unit after settled launch => stopped
      (should (eq 'stopped (v 'created '(:query-ok t :load-state "not-found" :active-state "inactive" :job "" :boot-id "b1" :cgroup-populated absent))))
      ;; never created + not found => never-launched
      (should (eq 'never-launched (v 'never-created '(:query-ok t :load-state "not-found" :active-state "inactive" :job "" :boot-id "b1" :cgroup-populated absent))))
      ;; unknown cgroup population => unknown
      (should (eq 'stop-unknown (v 'created '(:query-ok t :load-state "loaded" :active-state "inactive" :job "" :boot-id "b1" :cgroup-populated unknown)))))))

(ert-deftest fleet-runtime-inspect-parses-show-and-cgroup ()
  (fleet-test-with-roots
    (let* ((cgroot (expand-file-name "cg" fleet-test--roots))
           (cg "/user.slice/x/fleet-eca-1.service")
           (fleet-runtime-cgroup-root cgroot)
           (fleet-runtime-systemctl
            (fleet-runtime-test-fake-systemctl
             fleet-test--roots
             (format "printf 'LoadState=loaded\\nActiveState=active\\nSubState=running\\nMainPID=4242\\nControlGroup=%s\\nInvocationID=abc\\nJob=\\nResult=success\\n'\n" cg))))
      (fleet-test-write (expand-file-name (concat "." cg "/cgroup.events") cgroot) "populated 1\nfrozen 0\n")
      (let ((r (fleet-runtime-test-inspect "fleet-eca-1.service" nil)))
        (should (plist-get r :query-ok))
        (should (equal "active" (plist-get r :active-state)))
        (should (= 4242 (plist-get r :main-pid)))
        (should (equal cg (plist-get r :control-group)))
        (should (eq t (plist-get r :cgroup-populated)))
        (should (eq 'running (fleet-runtime-verdict 'created (plist-get r :boot-id) r))))
      ;; Now the unit is collected but the recorded cgroup is still populated (detached child).
      (setq fleet-runtime-systemctl
            (fleet-runtime-test-fake-systemctl
             fleet-test--roots "printf 'LoadState=not-found\\nActiveState=inactive\\nSubState=dead\\nMainPID=0\\nControlGroup=\\nJob=\\n'\n"))
      (let ((r (fleet-runtime-test-inspect "fleet-eca-1.service" cg)))
        (should (eq t (plist-get r :cgroup-populated)))
        (should (eq 'running (fleet-runtime-verdict 'created (plist-get r :boot-id) r))))
      ;; cgroup emptied
      (fleet-test-write (expand-file-name (concat "." cg "/cgroup.events") cgroot) "populated 0\nfrozen 0\n")
      (let ((r (fleet-runtime-test-inspect "fleet-eca-1.service" cg)))
        (should (eq 'stopped (fleet-runtime-verdict 'created (plist-get r :boot-id) r)))))))

(ert-deftest fleet-runtime-inspect-query-failure-is-unknown ()
  (fleet-test-with-roots
    (let ((fleet-runtime-systemctl
           (fleet-runtime-test-fake-systemctl fleet-test--roots "echo 'Failed to connect to bus' >&2; exit 1\n")))
      (let ((r (fleet-runtime-test-inspect "fleet-eca-1.service" nil)))
        (should-not (plist-get r :query-ok))
        (should (eq 'stop-unknown (fleet-runtime-verdict 'created "x" r)))))))

(ert-deftest fleet-runtime-stop-observes-until-terminal ()
  (fleet-test-with-roots
    (let* ((state-file (expand-file-name "state" fleet-test--roots))
           (fleet-runtime-systemctl
            (fleet-runtime-test-fake-systemctl
             fleet-test--roots
             (format "if [ \"$2\" = stop ]; then echo stopping > %s; exit 0; fi
n=$(cat %s.count 2>/dev/null || echo 0); n=$((n+1)); echo $n > %s.count
if [ $n -lt 3 ]; then printf 'LoadState=loaded\\nActiveState=deactivating\\nSubState=stop-sigterm\\nMainPID=1\\nControlGroup=\\nJob=\\n'
else printf 'LoadState=not-found\\nActiveState=inactive\\nSubState=dead\\nMainPID=0\\nControlGroup=\\nJob=\\n'; fi\n"
                     state-file state-file state-file))))
      (let (result)
        (fleet-runtime-stop "fleet-eca-1.service" nil (fleet-paths-boot-id) (lambda (r) (setq result r)))
        (should (fleet-test-wait-for (lambda () result) 10))
        (should (eq 'stopped (plist-get result :verdict)))
        (should (= 0 (plist-get result :stop-exit)))
        (should (equal "stopping\n" (fleet-paths-read-file state-file)))
        (should (>= (string-to-number (fleet-paths-read-file (concat state-file ".count"))) 3))))))

;;;; Native (opt-in): real user systemd, detached child, exact-unit stop.

(ert-deftest fleet-runtime-native-detached-child-stopped-with-unit ()
  :tags '(native)
  (skip-unless (fleet-test-native-p))
  (skip-unless (executable-find "systemd-run"))
  (let* ((id (fleet-paths-uuid))
         (unit (fleet-runtime-unit-name id))
         (marker (make-temp-file "fleet-native-marker-"))
         (argv (fleet-runtime-wrapper-argv
                ;; Main process ignores stdin so wrapper death alone cannot end it;
                ;; the detached child escapes the session but not the cgroup.
                unit (list "/bin/sh" "-c"
                           (format "setsid nohup sh -c 'while :; do echo alive > %s; sleep 1; done' >/dev/null 2>&1 & exec sleep 600" marker))
                :cwd "/tmp" :setenv '("HOME")))
         (proc (make-process :name "fleet-native" :command argv :buffer nil :noquery t :connection-type 'pipe)))
    (unwind-protect
        (progn
          (should (fleet-test-wait-for (lambda () (string= "alive\n" (or (fleet-paths-read-file marker) ""))) 10))
          (let ((insp (fleet-runtime-test-inspect unit nil)))
            (should (eq 'running (fleet-runtime-verdict 'created (plist-get insp :boot-id) insp)))
            ;; Killing only the Emacs-side wrapper must not stop the service.
            (delete-process proc)
            (accept-process-output nil 0.5)
            (let ((insp2 (fleet-runtime-test-inspect unit (plist-get insp :control-group))))
              (should (eq 'running (fleet-runtime-verdict 'created (plist-get insp2 :boot-id) insp2))))
            (let (result)
              (fleet-runtime-stop unit (plist-get insp :control-group) (plist-get insp :boot-id)
                                  (lambda (r) (setq result r)))
              (should (fleet-test-wait-for (lambda () result) 45))
              (should (eq 'stopped (plist-get result :verdict))))
            ;; detached child is gone: marker stops updating
            (delete-file marker)
            (sleep-for 1.5)
            (should-not (file-exists-p marker))))
      (ignore-errors (call-process fleet-runtime-systemctl nil nil nil "--user" "stop" unit))
      (ignore-errors (delete-file marker)))))

(provide 'fleet-runtime-tests)
;;; fleet-runtime-tests.el ends here
