;;; fleet-native-tests.el --- Opt-in end-to-end test on the installed ECA pair -*- lexical-binding: t; -*-

;;; Commentary:

;; Runs only with FLEET_TEST_NATIVE=1.  Uses temporary roots but the REAL
;; native ECA server, the real user systemd, the real lease helper and the
;; real RPC socket.  One commander is started, booted (one model turn),
;; observed calling Fleet tools through the MCP bridge, then stopped with
;; verified service evidence.  Costs one or two model turns.

;;; Code:

(require 'ert)
(require 'fleet)
(require 'fleet-test-helpers)

(ert-deftest fleet-native-commander-boot-tools-and-verified-stop ()
  :tags '(native)
  (skip-unless (fleet-test-native-p))
  (fleet-test-with-roots
    (let ((fleet-eca-command nil)
          (fleet-supervisor--store nil) (fleet-supervisor--lease nil) (fleet-supervisor--descriptor nil)
          (fleet-supervisor--fenced nil) (fleet-supervisor--read-only nil)
          (fleet-rpc--server nil) (fleet-rpc-request-log nil)
          (fleet-eca--conns (make-hash-table :test 'equal))
          (mode nil))
      (unwind-protect
          (progn
            (fleet-dashboard-ensure-started (lambda (r) (setq mode r)))
            (should (fleet-test-wait-for (lambda () mode) 30))
            (should (eq (plist-get mode :mode) 'owner))
            (should (file-exists-p (fleet-paths-socket)))
            (let* ((store (fleet-supervisor-store))
                   (fleet (fleet-core-create-fleet store "native-smoke"))
                   (fid (plist-get fleet :id))
                   (op (fleet-core-start-commander store fid)))
              (should (fleet-test-wait-for (lambda () (not (equal (plist-get (fleet-store-get store "operations" op) :state) "running"))) 180))
              (let* ((oprow (fleet-store-get store "operations" op))
                     (rt (fleet-store-get store "runtimes" (plist-get (fleet-store-get store "fleets" fid) :commander-runtime-id))))
                (should (equal (plist-get oprow :state) "done"))
                (should (equal (plist-get rt :lifecycle) "ready"))
                ;; the boot turn runs to completion on the real model
                (should (fleet-test-wait-for (lambda () (equal (plist-get (fleet-store-get store "runtimes" (plist-get rt :id)) :turn-state) "idle")) 240))
                ;; the commander reached Fleet through the MCP bridge with its scoped credential
                (should (cl-some (lambda (e) (equal (cdr e) "commander")) fleet-rpc-request-log))
                (message "native smoke: rpc requests %S" (mapcar #'car fleet-rpc-request-log))
                ;; the unit exists and is accounted for
                (let (insp)
                  (fleet-runtime-inspect (plist-get rt :unit) (plist-get rt :control-group) (lambda (i) (setq insp i)))
                  (should (fleet-test-wait-for (lambda () insp) 10))
                  (should (eq 'running (fleet-runtime-verdict 'created (plist-get rt :boot-id) insp))))
                ;; verified stop
                (let (res)
                  (fleet-core-stop-commander store fid :callback (lambda (r) (setq res r)))
                  (should (fleet-test-wait-for (lambda () res) 60))
                  (should (eq 'stopped (plist-get res :verdict))))
                (should (equal "stopped" (plist-get (fleet-store-get store "runtimes" (plist-get rt :id)) :lifecycle)))
                (should-not (file-exists-p (fleet-paths-credential-file (plist-get rt :id))))
                ;; per-runtime ECA cache isolation
                (should (file-directory-p (expand-file-name "eca" (fleet-paths-eca-cache-dir (plist-get rt :id))))))))
        ;; Belt and braces: never leave a real unit behind when an assertion fails.
        (when fleet-supervisor--store
          (dolist (rt (ignore-errors (fleet-store-query fleet-supervisor--store "SELECT unit FROM runtimes WHERE lifecycle NOT IN ('stopped','never-launched')")))
            (ignore-errors (call-process fleet-runtime-systemctl nil nil nil "--user" "stop" (plist-get rt :unit)))))
        (ignore-errors (fleet-rpc-stop))
        (ignore-errors (fleet-supervisor-release))
        (ignore-errors (fleet-supervisor-stop))))))

(provide 'fleet-native-tests)
;;; fleet-native-tests.el ends here
