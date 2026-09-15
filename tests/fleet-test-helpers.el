;;; fleet-test-helpers.el --- Shared ERT helpers for Fleet -*- lexical-binding: t; -*-

;;; Commentary:

;; Every test runs against disposable temporary roots.  Nothing here ever
;; touches the real user data root, ECA configuration, or MCP servers.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'fleet-paths)
(require 'fleet-policy)

(defvar fleet-test--roots nil "Current temporary root, for diagnostics.")

(defmacro fleet-test-with-roots (&rest body)
  "Run BODY with all Fleet roots pointed at a fresh temporary directory."
  (declare (indent 0) (debug t))
  `(let* ((fleet-test--roots (make-temp-file "fleet-test-" t))
          (fleet-data-root (expand-file-name "data" fleet-test--roots))
          (fleet-cache-root (expand-file-name "cache" fleet-test--roots))
          (fleet-config-root (expand-file-name "config" fleet-test--roots))
          (fleet-runtime-root (expand-file-name "run" fleet-test--roots))
          (fleet-development-root (expand-file-name "dev" fleet-test--roots))
          (fleet-worktree-root nil)
          (fleet-eca-command '("/nonexistent/fleet-test-must-not-launch" "server")))
     (make-directory fleet-data-root t)
     (make-directory fleet-cache-root t)
     (make-directory fleet-config-root t)
     (make-directory fleet-runtime-root t)
     (make-directory fleet-development-root t)
     (unwind-protect
         (progn ,@body)
       (ignore-errors (delete-directory fleet-test--roots t)))))

(defun fleet-test-wait-for (pred &optional timeout)
  "Run the event loop until PRED returns non-nil or TIMEOUT seconds elapse.
Return PRED's value or nil on timeout.  Uses `accept-process-output' so
process filters and timers run; never sleeps blindly."
  (let ((deadline (+ (float-time) (or timeout 10)))
        (result nil))
    (while (and (not (setq result (funcall pred)))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    result))

(defmacro fleet-test-should-fail (code &rest body)
  "Assert BODY signals `fleet-error' with CODE; return the error."
  (declare (indent 1))
  `(let ((err (should-error (progn ,@body) :type 'fleet-error)))
     (should (eq (fleet-error-code err) ,code))
     err))

(defun fleet-test-write (file content)
  "Write CONTENT to FILE creating parents."
  (make-directory (file-name-directory file) t)
  (with-temp-file file (insert content))
  file)

(defun fleet-test-write-config (&rest sections)
  "Write the owner `config.json' from SECTIONS, JSON text keyed by section name.
\(fleet-test-write-config :models POLICY-JSON :fleets FLEETS-JSON); a nil
section is omitted.  Returns the file path."
  (fleet-test-write (fleet-config-file)
                    (concat "{"
                            (string-join (cl-loop for (k v) on sections by #'cddr
                                                  when v collect (format "%S: %s" (substring (symbol-name k) 1) v))
                                         ", ")
                            "}")))

(defun fleet-test-native-p ()
  "Non-nil when opt-in native ECA/systemd tests are requested."
  (equal (getenv "FLEET_TEST_NATIVE") "1"))

(provide 'fleet-test-helpers)
;;; fleet-test-helpers.el ends here
