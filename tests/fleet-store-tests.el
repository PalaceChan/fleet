;;; fleet-store-tests.el --- Tests for fleet-store -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)
(require 'fleet-store)
(require 'fleet-test-helpers)

(defmacro fleet-store-test-with (var &rest body)
  "Open a fresh store bound to VAR inside temporary roots."
  (declare (indent 1))
  `(fleet-test-with-roots
     (let ((,var (fleet-store-open (fleet-paths-db-file))))
       (unwind-protect (progn ,@body)
         (fleet-store-close ,var)))))

(defun fleet-store-test-fleet (store &optional name)
  "Insert a fleet and return its id."
  (let ((id (fleet-paths-uuid)) (now (fleet-paths-now)))
    (fleet-store-transaction store
      (fleet-store-insert store "fleets"
                          (list :id id :name (or name "f") :lifecycle "active" :supervision 1
                                :artifact-root (fleet-paths-fleet-dir id) :created-at now :updated-at now)))
    id))

(defun fleet-store-test-task (store fleet-id &optional name)
  "Insert a task and return its id."
  (let ((id (fleet-paths-uuid)) (now (fleet-paths-now)))
    (fleet-store-transaction store
      (fleet-store-insert store "tasks"
                          (list :id id :fleet-id fleet-id :name (or name "t") :kind "study" :lifecycle "ready"
                                :brief-revision 1 :created-at now :updated-at now)))
    id))

(ert-deftest fleet-store-opens-with-schema-and-pragmas ()
  (fleet-store-test-with store
    (should (= (fleet-store--current-version store) fleet-store-schema-version))
    (should (equal (caar (sqlite-select (fleet-store-db store) "PRAGMA journal_mode")) "wal"))
    (should (= (caar (sqlite-select (fleet-store-db store) "PRAGMA foreign_keys")) 1))
    (should (= (caar (sqlite-select (fleet-store-db store) "PRAGMA synchronous")) 2))
    (should (= (fleet-store-snapshot-revision store) 0))))

(ert-deftest fleet-store-refuses-newer-schema ()
  (fleet-test-with-roots
    (let ((store (fleet-store-open (fleet-paths-db-file))))
      (sqlite-execute (fleet-store-db store) "UPDATE meta SET value='99' WHERE key='schema_version'")
      (fleet-store-close store))
    (fleet-test-should-fail 'schema-too-new (fleet-store-open (fleet-paths-db-file)))))

(ert-deftest fleet-store-migration-takes-backup-then-applies ()
  (fleet-test-with-roots
    (let ((store (fleet-store-open (fleet-paths-db-file))))
      (fleet-store-test-fleet store "old")
      (fleet-store-close store))
    ;; Simulate a package upgrade to schema v2 with a small additive script.
    (let ((v2 (fleet-test-write (expand-file-name "002.sql" fleet-test--roots)
                                "CREATE TABLE fleet_test_extra (x TEXT);\n")))
      (cl-letf* ((fleet-store-schema-version 2)
                 (orig (symbol-function 'fleet-paths-schema-file))
                 ((symbol-function 'fleet-paths-schema-file)
                  (lambda (name) (if (equal name "002.sql") v2 (funcall orig name)))))
        (let ((store (fleet-store-open (fleet-paths-db-file))))
          (should (= 2 (fleet-store--current-version store)))
          (should (= 1 (length (fleet-store-fleets store))))
          (should (sqlite-select (fleet-store-db store) "SELECT 1 FROM sqlite_master WHERE name='fleet_test_extra'"))
          (fleet-store-close store))))
    (should (directory-files (fleet-paths-data-root) nil "pre-migration-v1"))
    ;; The old package must now refuse to write the upgraded database.
    (fleet-test-should-fail 'schema-too-new (fleet-store-open (fleet-paths-db-file)))))

(ert-deftest fleet-store-mutation-requires-transaction ()
  (fleet-store-test-with store
    (fleet-test-should-fail 'no-transaction
      (fleet-store-insert store "meta" (list :key "x" :value "y")))))

(ert-deftest fleet-store-transaction-atomic-status-event-receipt ()
  (fleet-store-test-with store
    (let* ((fid (fleet-store-test-fleet store))
           (tid (fleet-store-test-task store fid))
           (rev-before (fleet-store-snapshot-revision store)))
      ;; Failing write rolls back all three.
      (should-error
       (fleet-store-transaction store
         (fleet-store-update store "tasks" tid (list :phase "done"))
         (fleet-store-append-event store :fleet-id fid :task-id tid :kind "task-done" :actionable t)
         (fleet-store-exec store "INSERT INTO nonexistent VALUES (1)")))
      (should (null (plist-get (fleet-store-get store "tasks" tid) :phase)))
      (should (= 0 (fleet-store-scalar store "SELECT COUNT(*) FROM events")))
      (should (= 0 (fleet-store-scalar store "SELECT COUNT(*) FROM event_receipts")))
      (should (= rev-before (fleet-store-snapshot-revision store)))
      ;; Successful write commits all three and bumps snapshot revision once.
      (fleet-store-transaction store
        (fleet-store-update store "tasks" tid (list :phase "done"))
        (fleet-store-append-event store :fleet-id fid :task-id tid :kind "task-done" :actionable t
                                  :payload '(:detail "ok")))
      (should (equal "done" (plist-get (fleet-store-get store "tasks" tid) :phase)))
      (should (= 1 (length (fleet-store-pending-receipts store fid))))
      (should (= (1+ rev-before) (fleet-store-snapshot-revision store)))
      (should (equal '(:detail "ok")
                     (fleet-store-unjson (plist-get (car (fleet-store-pending-receipts store fid)) :payload)))))))

(ert-deftest fleet-store-nested-transaction-joins-outer ()
  (fleet-store-test-with store
    (let ((fid (fleet-store-test-fleet store)))
      (should-error
       (fleet-store-transaction store
         (fleet-store-transaction store
           (fleet-store-update store "fleets" fid (list :name "renamed")))
         (error "boom")))
      (should (equal "f" (plist-get (fleet-store-get store "fleets" fid) :name))))))

(ert-deftest fleet-store-action-idempotency ()
  (fleet-store-test-with store
    (let ((calls 0))
      (cl-flet ((run (payload)
                  (fleet-store-with-action store "fleet:x:commander" "act-1" payload
                    (cl-incf calls)
                    (list :ok t :n calls))))
        (should (equal (plist-get (run '(:a 1 :b "x")) :n) 1))
        ;; Same key + same payload (different key order) => replay, no second run.
        (let ((r (run '(:b "x" :a 1))))
          (should (plist-get r :replayed))
          (should (equal (plist-get r :n) 1)))
        (should (= calls 1))
        ;; Changed payload refuses.
        (fleet-test-should-fail 'action-payload-mismatch (run '(:a 2)))
        (should (= calls 1))))))

(ert-deftest fleet-store-unique-active-names-allow-reuse-after-archive ()
  (fleet-store-test-with store
    (let ((id1 (fleet-store-test-fleet store "same")))
      (should-error (fleet-store-test-fleet store "same"))
      (fleet-store-transaction store (fleet-store-update store "fleets" id1 (list :lifecycle "archived")))
      (should (fleet-store-test-fleet store "same")))))

(ert-deftest fleet-store-read-only-refuses-writes ()
  (fleet-test-with-roots
    (let ((w (fleet-store-open (fleet-paths-db-file))))
      (fleet-store-test-fleet w "ro")
      (fleet-store-close w))
    (let ((ro (fleet-store-open (fleet-paths-db-file) t)))
      (should (= 1 (length (fleet-store-fleets ro))))
      (fleet-test-should-fail 'read-only (fleet-store-transaction ro (fleet-store-exec ro "DELETE FROM fleets")))
      (fleet-store-close ro))))

(ert-deftest fleet-store-snapshot-shape ()
  (fleet-store-test-with store
    (let* ((fid (fleet-store-test-fleet store "snap"))
           (tid (fleet-store-test-task store fid "one")))
      (fleet-store-transaction store
        (fleet-store-append-event store :fleet-id fid :task-id tid :kind "decision-requested" :actionable t))
      (let* ((snap (fleet-store-snapshot store))
             (f (car (plist-get snap :fleets))))
        (should (= (plist-get snap :revision) (fleet-store-snapshot-revision store)))
        (should (equal (plist-get f :name) "snap"))
        (should (= (plist-get f :pending-events) 1))
        (should (equal (plist-get (car (plist-get f :tasks)) :name) "one"))
        (should (null (plist-get (car (plist-get f :tasks)) :runtime)))))))

(ert-deftest fleet-store-json-roundtrip ()
  (should (equal (fleet-store-unjson (fleet-store-json '(:a 1 :b "x" :c (1 2) :d nil :e :false :f (:g t))))
                 '(:a 1 :b "x" :c [1 2] :d nil :e :false :f (:g t))))
  (should (equal (fleet-store-json '(:text "multi\nline — ünicode")) "{\"text\":\"multi\\nline — ünicode\"}")))

(ert-deftest fleet-store-revision-check ()
  (fleet-store-test-with store
    (let ((fid (fleet-store-test-fleet store)))
      (fleet-store-transaction store
        (fleet-store-check-revision store "fleets" fid 1)
        (should (= 2 (fleet-store-bump-revision store "fleets" fid))))
      (fleet-test-should-fail 'revision-mismatch
        (fleet-store-transaction store (fleet-store-check-revision store "fleets" fid 1))))))

(provide 'fleet-store-tests)
;;; fleet-store-tests.el ends here
