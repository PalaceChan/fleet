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
    ;; A database left by the v1 package: open with the version pinned to 1.
    (cl-letf (((symbol-value 'fleet-store-schema-version) 1))
      (let ((store (fleet-store-open (fleet-paths-db-file))))
        (should (= 1 (fleet-store--current-version store)))
        (fleet-store-test-fleet store "old")
        (fleet-store-close store)))
    ;; The current package upgrades it additively (real schema/002.sql).
    (let ((store (fleet-store-open (fleet-paths-db-file))))
      (should (= fleet-store-schema-version (fleet-store--current-version store)))
      (should (= 1 (length (fleet-store-fleets store))))
      (should (member "variant" (mapcar (lambda (r) (nth 1 r)) (sqlite-select (fleet-store-db store) "PRAGMA table_info(tasks)"))))
      (should (member "commander_variant" (mapcar (lambda (r) (nth 1 r)) (sqlite-select (fleet-store-db store) "PRAGMA table_info(fleets)"))))
      (fleet-store-close store))
    (should (directory-files (fleet-paths-data-root) nil "pre-migration-v1"))
    ;; The old package must now refuse to write the upgraded database.
    (cl-letf (((symbol-value 'fleet-store-schema-version) 1))
      (fleet-test-should-fail 'schema-too-new (fleet-store-open (fleet-paths-db-file))))))

(ert-deftest fleet-store-eca-catalog-round-trips-and-keeps-fuller-data ()
  (fleet-store-test-with store
    (should (equal (fleet-store-eca-catalog store) '(:models nil :default-model nil :variants nil)))
    (fleet-store-record-eca-catalog store :models '("a/x" "b/y") :default-model "a/x" :variants '("low" "high"))
    (should (equal (fleet-store-eca-catalog store) '(:models ("a/x" "b/y") :default-model "a/x" :variants ("low" "high"))))
    ;; An announcement without models or variants must not erase them.
    (fleet-store-record-eca-catalog store :models nil :default-model "b/y" :variants nil)
    (should (equal (fleet-store-eca-catalog store) '(:models ("a/x" "b/y") :default-model "b/y" :variants ("low" "high"))))))

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

(defun fleet-store-test-lieutenant (store parent-id name)
  "Insert a child fleet NAME under PARENT-ID and return its id."
  (let ((id (fleet-paths-uuid)) (now (fleet-paths-now)))
    (fleet-store-transaction store
      (fleet-store-insert store "fleets"
                          (list :id id :name name :parent-id parent-id :charter "domain" :lifecycle "active" :supervision 1
                                :artifact-root (fleet-paths-fleet-dir id) :created-at now :updated-at now)))
    id))

(ert-deftest fleet-store-lieutenant-names-are-unique-per-parent ()
  "Two roots may each have a `frontend'; a lieutenant may share a root's name; siblings may not clash."
  (fleet-store-test-with store
    (let ((a (fleet-store-test-fleet store "a")) (b (fleet-store-test-fleet store "b")))
      (let ((a-front (fleet-store-test-lieutenant store a "frontend")))
        (should (fleet-store-test-lieutenant store b "frontend"))
        (should (fleet-store-test-lieutenant store a "b"))
        (should-error (fleet-store-test-lieutenant store a "frontend"))
        (should (equal a-front (plist-get (fleet-store-fleet-by-name store "frontend" a) :id)))
        (should-not (fleet-store-fleet-by-name store "frontend"))
        (should (equal '("a" "b") (mapcar (lambda (f) (plist-get f :name)) (fleet-store-root-fleets store))))
        (should (equal '("b" "frontend") (mapcar (lambda (f) (plist-get f :name)) (fleet-store-lieutenants store a))))
        (should-not (fleet-store-lieutenants store a-front))))))

(ert-deftest fleet-store-v2-database-upgrades-to-v3-keeping-roots ()
  "A populated v2 store gains parent_id/charter/requests; old fleets stay roots and the per-parent name index applies."
  (fleet-test-with-roots
    (cl-letf (((symbol-value 'fleet-store-schema-version) 2))
      (let ((store (fleet-store-open (fleet-paths-db-file))))
        (fleet-store-test-fleet store "old")
        (fleet-store-close store)))
    (let ((store (fleet-store-open (fleet-paths-db-file))))
      (unwind-protect
          (let ((old (fleet-store-fleet-by-name store "old")))
            (should (= 3 (fleet-store--current-version store)))
            (should old)
            (should-not (plist-get old :parent-id))
            (should (member "requests" (mapcar #'car (sqlite-select (fleet-store-db store) "SELECT name FROM sqlite_master WHERE type='table'"))))
            ;; The old global name index is gone: a lieutenant may be called `old'.
            (should (fleet-store-test-lieutenant store (plist-get old :id) "old"))
            (should-error (fleet-store-test-fleet store "old"))
            (should (equal 0 (length (plist-get (car (plist-get (fleet-store-snapshot store (plist-get old :id)) :fleets)) :open-requests)))))
        (fleet-store-close store)))
    (should (directory-files (fleet-paths-data-root) nil "pre-migration-v2"))))

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
