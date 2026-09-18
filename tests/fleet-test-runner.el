;;; fleet-test-runner.el --- Run all Fleet ERT tests without exiting -*- lexical-binding: t; -*-

;;; Commentary:

;; Loaded into a DEDICATED test Emacs server via emacsclient (see Makefile).
;; Returns a printable summary instead of calling `kill-emacs'.

;;; Code:

(require 'ert)

(defun fleet-test-run-all (root &optional selector)
  "Load every tests/*-tests.el under ROOT, run SELECTOR (default t), return summary."
  (let* ((lisp (expand-file-name "lisp" root))
         (tests (expand-file-name "tests" root))
         (load-prefer-newer t))
    (add-to-list 'load-path lisp)
    (add-to-list 'load-path tests)
    ;; Force fresh definitions so reload semantics are exercised.
    (dolist (f (directory-files lisp t "\\.el\\'"))
      (load f nil t))
    ;; The tool schema is parsed once and cached in a defvar, which `load'
    ;; leaves alone.  On a reused daemon a schema edit was invisible until
    ;; the cache was cleared by hand; forget it with every reload.
    (when (boundp 'fleet-rpc--tools) (setq fleet-rpc--tools nil))
    (dolist (f (directory-files tests t "-tests\\.el\\'"))
      (load f nil t))
    (let* ((stats (ert-run-tests-batch (or selector t)))
           (out (with-current-buffer (get-buffer-create "*fleet-test-output*")
                  (buffer-string))))
      (format "%s\nPASSED %d  FAILED %d  SKIPPED %d  TOTAL %d"
              (fleet-test--failures stats)
              (ert-stats-completed-expected stats)
              (ert-stats-completed-unexpected stats)
              (ert-stats-skipped stats)
              (ert-stats-total stats)))))

(defun fleet-test--failures (stats)
  "Render unexpected results of STATS."
  (let ((lines nil))
    (cl-loop for i from 0 below (length (ert--stats-tests stats))
             for test = (aref (ert--stats-tests stats) i)
             for result = (aref (ert--stats-test-results stats) i)
             when (and result (not (ert-test-result-expected-p test result)))
             do (push (format "FAILED %s: %s"
                              (ert-test-name test)
                              (if (ert-test-result-with-condition-p result)
                                  (let ((print-length 60) (print-level 6))
                                    (prin1-to-string (ert-test-result-with-condition-condition result)))
                                (type-of result)))
                      lines))
    (string-join (nreverse lines) "\n")))

(provide 'fleet-test-runner)
;;; fleet-test-runner.el ends here
