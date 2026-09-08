;;; fleet-dashboard-tests.el --- Tests for the dashboard -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)
(require 'fleet)
(require 'fleet-supervisor-tests)

(defmacro fleet-dash-test-with (&rest body)
  "Supervisor fakes plus a fresh dashboard buffer bound to `dash'."
  (declare (indent 0))
  `(fleet-sup-test-with
     (when (get-buffer fleet-dashboard-buffer-name) (kill-buffer fleet-dashboard-buffer-name))
     (let ((dash (fleet-dashboard-buffer)))
       (unwind-protect
           (with-current-buffer dash
             (fleet-dashboard-mode)
             (fleet-dashboard-render)
             ,@body)
         (when (buffer-live-p dash) (kill-buffer dash))))))

(defun fleet-dash-test-lines ()
  "Buffer lines without properties."
  (split-string (buffer-substring-no-properties (point-min) (point-max)) "\n"))

(defun fleet-dash-test-row-line (id)
  "Text of the row with identity ID."
  (save-excursion (when (fleet-dashboard--goto-row id) (buffer-substring-no-properties (line-beginning-position) (line-end-position)))))

(ert-deftest fleet-dashboard-exact-key-contract-survives-reload ()
  (fleet-dash-test-with
    ;; simulate a package reload: the map object is reused and keys redefined
    (define-key fleet-dashboard-mode-map (kbd "n") nil)
    (load (locate-library "fleet-dashboard") nil t)
    (should (eq (key-binding (kbd "n")) #'fleet-dash-next))
    (should (eq (key-binding (kbd "p")) #'fleet-dash-prev))
    (should (eq (key-binding (kbd "N")) #'fleet-dash-next-fleet))
    (should (eq (key-binding (kbd "P")) #'fleet-dash-prev-fleet))
    (should (eq (key-binding (kbd "j")) #'fleet-dash-jump))
    (should (eq (key-binding (kbd "a")) #'fleet-dash-attention))
    (should (eq (key-binding (kbd "RET")) #'fleet-dash-visit))
    (should (eq (key-binding (kbd "v")) #'fleet-dash-peek))
    (should (eq (key-binding (kbd "s")) #'fleet-dash-send))
    (should (eq (key-binding (kbd "i")) #'fleet-dash-interrupt))
    (should (eq (key-binding (kbd "t")) #'fleet-dash-teardown))
    (should (eq (key-binding (kbd "b")) #'fleet-dash-brief))
    (should (eq (key-binding (kbd "r")) #'fleet-dash-report))
    (should (eq (key-binding (kbd "w")) #'fleet-dash-worktree))
    (should (eq (key-binding (kbd "X")) #'fleet-dash-park))
    (should (eq (key-binding (kbd "g")) #'fleet-dash-refresh))
    (should (eq (key-binding (kbd "q")) #'quit-window))
    ;; special-mode suppresses self-insert: absent keys resolve to nil/undefined, never a Fleet command
    (should (memq (key-binding (kbd "d")) '(nil undefined)))
    (should (memq (key-binding (kbd "k")) '(nil undefined)))
    (should (derived-mode-p 'special-mode))
    (should buffer-read-only)
    (should truncate-lines)))

(ert-deftest fleet-dashboard-empty-and-header-states ()
  (fleet-dash-test-with
    (should (cl-some (lambda (l) (string-match-p "no active fleets — M-x fleet-new" l)) (fleet-dash-test-lines)))
    (should (cl-some (lambda (l) (string-match-p "X park fleet" l)) (fleet-dash-test-lines)))
    (let* ((fid (fleet-core-test-fleet store "compiler")))
      (fleet-dashboard-render)
      (should (string-match-p "Fleet compiler - commander none · supervision on · wakes 0 · no tasks" (fleet-dash-test-row-line (cons fid 'commander))))
      (fleet-sup-test-commander store fid) (fleet-sup-test-settle)
      (fleet-dashboard-render)
      (should (string-match-p "commander live/idle" (fleet-dash-test-row-line (cons fid 'commander))))
      (fleet-core-set-supervision store fid nil) (fleet-dashboard-render)
      (should (string-match-p "supervision paused" (fleet-dash-test-row-line (cons fid 'commander)))))))

(ert-deftest fleet-dashboard-projection-precedence ()
  (let ((fleet '(:lifecycle "active")))
    (cl-flet ((p (task) (car (fleet-dashboard-task-projection task fleet))))
      (should (eq 'unknown (p '(:lifecycle "active" :phase "done" :runtime (:lifecycle "stop-unknown")))))
      (should (eq 'suspended (p '(:lifecycle "suspended" :phase "working"))))
      (should (eq 'stopping (car (fleet-dashboard-task-projection '(:lifecycle "active" :phase "working") '(:lifecycle "parking")))))
      (should (eq 'dead (p '(:lifecycle "active" :phase "working" :runtime (:lifecycle "lost")))))
      (should (eq 'done (p '(:lifecycle "active" :phase "done" :runtime (:lifecycle "lost")))))
      (should (eq 'decision (p '(:lifecycle "active" :phase "working" :runtime (:lifecycle "ready" :pending-approvals "[\"t\"]")))))
      (should (eq 'decision (p '(:lifecycle "active" :phase "needs-decision" :decisions ((:id "d" :question "q?"))))))
      (should (eq 'blocked (p '(:lifecycle "active" :phase "blocked"))))
      (should (eq 'failed (p '(:lifecycle "active" :phase "failed"))))
      (should (eq 'done (p '(:lifecycle "active" :phase "done" :runtime (:lifecycle "ready" :turn-state "running")))))
      (should (string-match-p "still responding" (nth 2 (fleet-dashboard-task-projection '(:lifecycle "active" :phase "done" :detail "d" :runtime (:lifecycle "ready" :turn-state "running")) fleet))))
      (should (eq 'paused (p '(:lifecycle "active" :phase "paused" :wait-reason "CI"))))
      (let ((w (fleet-dashboard-task-projection '(:lifecycle "active" :phase "working" :detail "x" :runtime (:lifecycle "ready" :turn-state "running" :active-tool "{\"name\":\"shell\",\"since\":\"2000-01-01T00:00:00Z\"}")) fleet)))
        (should (eq 'working (car w))) (should (equal "eca" (nth 1 w))) (should (string-match-p "tool shell" (nth 2 w))))
      (let ((w (fleet-dashboard-task-projection '(:lifecycle "active" :phase "working" :detail "x" :runtime (:lifecycle "ready" :turn-state "idle")) fleet)))
        (should (equal "status" (nth 1 w))) (should (string-match-p "idle, awaiting" (nth 2 w))))
      (should (eq 'unknown (p '(:lifecycle "active" :phase "working"))))
      ;; a failed operation adds an attention badge even on done
      (let ((w (fleet-dashboard-task-projection '(:lifecycle "active" :phase "done" :operations ((:kind "task-teardown" :state "failed"))) fleet)))
        (should (eq 'done (car w))) (should (fleet-dashboard-attention-p w)) (should (string-match-p "op task-teardown failed" (nth 2 w)))))))

(ert-deftest fleet-dashboard-rows-columns-unicode-and-refresh-identity ()
  (fleet-dash-test-with
    (let* ((fid (fleet-core-test-fleet store "compiler"))
           (long (fleet-core-test-study store fid (concat "an-extremely-long-task-name-that-exceeds-the-column" "-max")))
           (uni (fleet-core-test-study store fid "unicode-task"))
           (tid (plist-get uni :id)))
      ;; names are ASCII by grammar; Unicode arrives through details
      (fleet-test-should-fail 'invalid-name (fleet-core-test-study store fid "ünïcödé"))
      (fleet-core-test-start store tid)
      (fleet-core-task-status store :runtime-id (fleet-core-test-runtime store tid) :phase "working"
                              :detail "validating\nmalformed\tinput — ünicode 日本語")
      (fleet-dashboard-render)
      (let ((line (fleet-dash-test-row-line (cons fid tid))))
        (should (string-match-p "unicode-task" line))
        (should (string-match-p "ünicode 日本語" line))
        (should (string-match-p "working·" line))
        (should (string-match-p "study" line))
        ;; control characters stripped from detail
        (should-not (string-match-p "\t" line)))
      ;; name column capped at 28 display columns; rows aligned
      (let* ((l1 (fleet-dash-test-row-line (cons fid tid))) (l2 (fleet-dash-test-row-line (cons fid (plist-get long :id)))))
        (should (= (string-width (substring l1 0 (string-match "study" l1))) (string-width (substring l2 0 (string-match "study" l2))))))
      ;; selection preserved by identity across a refresh that inserts rows
      (fleet-dashboard--goto-row (cons fid tid))
      (fleet-core-test-study store fid "aaa-first")
      (fleet-dashboard-render)
      (should (equal (fleet-dashboard--row-at) (cons fid tid)))
      ;; vanished row falls back to a sibling, then header
      (fleet-store-transaction store (fleet-store-update store "tasks" tid (list :lifecycle "archived")))
      (fleet-dashboard-render)
      (should (equal (car (fleet-dashboard--row-at)) fid))
      (should-not (equal (cdr (fleet-dashboard--row-at)) tid))
      ;; refresh and peek never mutate
      (let ((rev (fleet-store-snapshot-revision store)))
        (fleet-dash-refresh)
        (fleet-dashboard--goto-row (cons fid 'commander))
        (fleet-dash-peek)
        (should (= rev (fleet-store-snapshot-revision store)))
        (should (= 0 (fleet-store-scalar store "SELECT COUNT(*) FROM event_receipts WHERE state = 'acknowledged'")))))))

(ert-deftest fleet-dashboard-navigation-and-attention-wrap ()
  (fleet-dash-test-with
    (let* ((f1 (fleet-core-test-fleet store "alpha")) (f2 (fleet-core-test-fleet store "beta"))
           (a1 (plist-get (fleet-core-test-study store f1 "a1") :id))
           (a2 (plist-get (fleet-core-test-study store f1 "a2") :id))
           (b1 (plist-get (fleet-core-test-study store f2 "b1") :id)))
      ;; healthy commanders, so only operators carry attention
      (fleet-sup-test-commander store f1) (fleet-sup-test-commander store f2) (fleet-sup-test-settle)
      (fleet-core-test-start store a2)
      (fleet-core-task-status store :runtime-id (fleet-core-test-runtime store a2) :phase "blocked" :detail "need input")
      (fleet-core-test-start store b1)
      (fleet-core-task-status store :runtime-id (fleet-core-test-runtime store b1) :phase "needs-decision" :decision '(:question "A or B?"))
      (fleet-dashboard-render)
      ;; sorted: alpha before beta, a1 before a2
      (should (equal fleet-dashboard--rows (list (cons f1 'commander) (cons f1 a1) (cons f1 a2) (cons f2 'commander) (cons f2 b1))))
      (goto-char (point-min))
      (fleet-dash-next) (should (equal (fleet-dashboard--row-at) (cons f1 a1)))
      (fleet-dash-next) (should (equal (fleet-dashboard--row-at) (cons f1 a2)))
      (fleet-dash-next-fleet) (should (equal (fleet-dashboard--row-at) (cons f2 'commander)))
      (fleet-dash-prev) (should (equal (fleet-dashboard--row-at) (cons f1 a2)))
      (fleet-dash-prev-fleet) (should (equal (fleet-dashboard--row-at) (cons f1 'commander)))
      (fleet-dash-prev) (should (equal (fleet-dashboard--row-at) (cons f1 'commander))) ; no wrap
      ;; attention: a2 (blocked) then b1 (decision), wrapping back to a2
      (fleet-dash-attention) (should (equal (fleet-dashboard--row-at) (cons f1 a2)))
      (fleet-dash-attention) (should (equal (fleet-dashboard--row-at) (cons f2 b1)))
      (fleet-dash-attention) (should (equal (fleet-dashboard--row-at) (cons f1 a2)))
      ;; header severity: alpha bold+error (blocked), beta bold+warning (decision)
      (should (memq 'error (ensure-list (get-text-property (save-excursion (fleet-dashboard--goto-row (cons f1 'commander)) (point)) 'face))))
      (should (memq 'warning (ensure-list (get-text-property (save-excursion (fleet-dashboard--goto-row (cons f2 'commander)) (point)) 'face)))))))

(ert-deftest fleet-dashboard-background-start-does-not-steal-window ()
  (fleet-dash-test-with
    (let* ((fid (fleet-core-test-fleet store))
           (tid (plist-get (fleet-core-test-study store fid) :id))
           (win (selected-window)) (cur (current-buffer)))
      (fleet-core-test-start store tid)
      (fleet-sup-test-settle)
      (should (eq (selected-window) win))
      (should (eq (current-buffer) cur)))))

(ert-deftest fleet-dashboard-brief-view-read-only-and-worktree-message ()
  (fleet-dash-test-with
    (let* ((fid (fleet-core-test-fleet store))
           (task (fleet-core-test-study store fid)) (tid (plist-get task :id)))
      (fleet-dashboard-render)
      (fleet-dashboard--goto-row (cons fid tid))
      (save-window-excursion
        (fleet-dash-brief)
        (should (bound-and-true-p view-mode))
        (should buffer-read-only)
        (should (string-match-p "revision 1" (buffer-string)))
        (kill-buffer))
      (should-error (fleet-dash-report) :type 'user-error)
      (should-error (fleet-dash-worktree) :type 'user-error)
      (fleet-dashboard--goto-row (cons fid 'commander))
      (should-error (fleet-dash-brief) :type 'user-error)
      (should-error (fleet-dash-teardown) :type 'user-error)
      (should-error (fleet-dash-interrupt) :type 'user-error))))

(ert-deftest fleet-dashboard-visit-missing-session-shows-recovery-not-empty-buffer ()
  (fleet-dash-test-with
    (let* ((fid (fleet-core-test-fleet store))
           (tid (plist-get (fleet-core-test-study store fid) :id)))
      (fleet-core-test-start store tid)
      (fleet-test-wait-op store (fleet-core-park-fleet store fid))
      (fleet-dashboard-render)
      (fleet-dashboard--goto-row (cons fid tid))
      (let ((before (buffer-list)))
        (save-window-excursion
          (fleet-dash-visit)
          (let ((peek (get-buffer fleet-dashboard-peek-buffer-name)))
            (should peek)
            (should (string-match-p "no live chat" (with-current-buffer peek (buffer-string))))
            (should (string-match-p "Recovery:" (with-current-buffer peek (buffer-string))))))
        ;; no new eca chat buffer was created
        (should-not (cl-some (lambda (b) (and (not (memq b before)) (string-prefix-p "*eca:" (buffer-name b)))) (buffer-list)))))))

(provide 'fleet-dashboard-tests)
;;; fleet-dashboard-tests.el ends here
