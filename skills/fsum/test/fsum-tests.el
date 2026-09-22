;;; fsum-tests.el --- ERT tests for the fsum skill (faked store, no live fleet) -*- lexical-binding: t; -*-

;;; Commentary:

;; Runs in a DISPOSABLE Emacs server (socket `fleet-test'), never the owner's
;; editing server; see skills/fsum/README.md.  The installed Fleet read API is
;; replaced by fakes over an in-memory fixture, and a spy records every call:
;; a test fails if the reader touches anything outside the read allowlist or any
;; function on the mutation denylist.  No SQLite, no ECA, no owner fleets.
;;
;; The unresolved-result checkpoint and the transcript collector of
;; `scripts/fleet-result.el' are covered here too, because that module lives in
;; this skill.  Every fixture points `fleet-result-data-root' at a throwaway
;; directory and synthesizes its own minimal transcripts: no real user fleet,
;; data root or transcript is ever used.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'json)

(defconst fsum-test--root
  (file-name-directory (directory-file-name (file-name-directory (or load-file-name buffer-file-name))))
  "The skills/fsum directory.")

(load (expand-file-name "scripts/fsum.el" fsum-test--root) nil t)

(defvar fleet-supervisor--store nil)

(defvar fsum-test--calls nil "Names of faked Fleet functions called, in order.")
(defvar fsum-test--mutations nil "Names of denylisted functions called (must stay empty).")
(defvar fsum-test--data-root nil "Throwaway result-review data root of the current fixture.")
(defvar fsum-test--artifact-root nil "Throwaway fleet artifact root of the current fixture.")

(defconst fsum-test--read-allowlist
  '(fleet-core-fleet fleet-store-get fleet-store-lieutenants fleet-store-snapshot fleet-config-lieutenants)
  "The only installed Fleet functions the reader may call.")

(defconst fsum-test--mutation-denylist
  '(fleet-core-ensure-lieutenants fleet-store-exec fleet-store-insert fleet-store-update fleet-store-append-event
    fleet-store-open fleet-store-migrate fleet-supervisor-start fleet-supervisor-send fleet-supervisor-ack
    fleet-supervisor-delegate fleet-supervisor-report fleet-core-start-task fleet-core-create-task fleet-core-park
    fleet-core-decision-resolve fleet-core-artifact-register fleet-core-set-supervision fleet-dashboard fleet-new
    fleet-commander-replace fleet-store-pending-receipts fleet-git-worktree-evidence)
  "Functions the reader must never call while observing.")

;;;; Fixture

(defconst fsum-test--root-id "11111111-1111-1111-1111-111111111111")
(defconst fsum-test--other-id "22222222-2222-2222-2222-222222222222")
(defconst fsum-test--child-id "33333333-3333-3333-3333-333333333333")

(defun fsum-test--fleet (id name &rest props)
  "Fleet row ID/NAME with defaults, overridden by PROPS."
  (append props (list :id id :name name :lifecycle "active" :supervision 1 :parent-id nil :charter nil
                      :commander-runtime-id nil :artifact-root (concat "/nonexistent/" id))))

(defun fsum-test--task (id name &rest props)
  "Enriched task plist ID/NAME with defaults, overridden by PROPS."
  (append props (list :id id :name name :kind "change" :lifecycle "active" :phase "working" :detail (concat name " detail")
                      :detail-at "2026-09-17T10:00:00.000Z" :runtime nil :artifacts nil :decisions nil :operations nil
                      :external-jobs nil :dependencies nil :messages-recent nil)))

(defun fsum-test--rt (lifecycle &rest props)
  "Runtime row with LIFECYCLE and PROPS.
A credential hash is present to prove the reader drops it."
  (append props (list :id (concat "rt-" lifecycle) :lifecycle lifecycle :turn-state "idle" :connection-state "ready"
                      :credential-hash "SECRET-HASH" :model "test/model" :pending-question nil :pending-approvals nil
                      :active-tool nil)))

(defun fsum-test--decision (id question authority)
  "Open decision row."
  (list :id id :question question :authority authority :state "open" :created-at "2026-09-17T10:30:00.000Z"))

(cl-defun fsum-test--basic-fixture (&key root child rows config (store 'fake-store store-p) fail-snapshots config-error)
  "Root `workshop' (live), sibling root `other', lieutenant `frontend' (live).
ROOT and CHILD are extra enriched plists for workshop/frontend; the other
keys override wholesale."
  (append (when store-p (list :store store))
          (list :rows (or rows (list (fsum-test--fleet fsum-test--root-id "workshop" :commander-runtime-id "rt-ready")
                                     (fsum-test--fleet fsum-test--other-id "other")
                                     (fsum-test--fleet fsum-test--child-id "frontend" :parent-id fsum-test--root-id :charter "UI and accessibility")))
                :enriched (list (cons fsum-test--root-id (append root (list :commander (fsum-test--rt "ready"))))
                                (cons fsum-test--child-id (append child (list :commander (fsum-test--rt "ready")))))
                :config (or config '("frontend"))
                :fail-snapshots fail-snapshots
                :config-error config-error)))

(defun fsum-test--children-fixture ()
  "Declared: frontend backend docs.
Existing: frontend (live), backend (stopped), legacy (unconfigured, none)."
  (let ((backend-id "44444444-4444-4444-4444-444444444444") (legacy-id "55555555-5555-5555-5555-555555555555"))
    (list :rows (list (fsum-test--fleet fsum-test--root-id "workshop" :commander-runtime-id "rt-ready")
                      (fsum-test--fleet fsum-test--child-id "frontend" :parent-id fsum-test--root-id :charter "UI work")
                      (fsum-test--fleet backend-id "backend" :parent-id fsum-test--root-id :charter "APIs")
                      (fsum-test--fleet legacy-id "legacy" :parent-id fsum-test--root-id :charter "Old domain"))
          :enriched (list (cons fsum-test--root-id (list :commander (fsum-test--rt "ready")))
                          (cons fsum-test--child-id (list :commander (fsum-test--rt "ready") :tasks (list (fsum-test--task "t1" "navigation"))))
                          (cons backend-id (list :commander (fsum-test--rt "stopped")))
                          (cons legacy-id (list :commander nil)))
          :config '("frontend" "backend" "docs"))))

(defun fsum-test--row (fixture id)
  "Fleet row ID from FIXTURE, or nil."
  (cl-find id (plist-get fixture :rows) :key (lambda (r) (plist-get r :id)) :test #'equal))

(defun fsum-test--active-by-name (fixture name parent-id)
  "Non-archived fleet NAME under PARENT-ID in FIXTURE, or nil."
  (cl-find-if (lambda (r) (and (equal (plist-get r :name) name) (equal (plist-get r :parent-id) parent-id)
                               (not (equal (plist-get r :lifecycle) "archived"))))
              (plist-get fixture :rows)))

(defun fsum-test--fake-core-fleet (fixture ref)
  "Mirror of `fleet-core-fleet' semantics over FIXTURE for REF."
  (or (fsum-test--row fixture ref)
      (if (string-match "\\`\\([^/]+\\)/\\([^/]+\\)\\'" ref)
          (when-let* ((root (fsum-test--active-by-name fixture (match-string 1 ref) nil)))
            (fsum-test--active-by-name fixture (match-string 2 ref) (plist-get root :id)))
        (fsum-test--active-by-name fixture ref nil))
      (signal 'error (list "No such fleet" ref))))

(defun fsum-test--fake-snapshot (fixture id)
  "Single-fleet enriched snapshot of ID from FIXTURE."
  (when (member id (plist-get fixture :fail-snapshots)) (signal 'error (list "database is locked")))
  (let ((row (fsum-test--row fixture id)))
    (list :revision 42
          :fleets (and row (list (append (cdr (assoc id (plist-get fixture :enriched)))
                                         row
                                         (list :commander nil :pending-events 0 :queued-wakes 0 :open-decisions nil
                                               :running-operations nil :open-requests nil :tasks nil)))))))

(defmacro fsum-test-with-fixture (fixture &rest body)
  "Run BODY with the Fleet read API faked over FIXTURE and the spy armed.
The unresolved-result checkpoint is redirected to a throwaway data root and
initialized unless FIXTURE carries a non-nil :no-checkpoint.  Afterwards
assert no denylisted function ran and only allowlisted reads."
  (declare (indent 1))
  ;; The data root is bound before FIXTURE is evaluated so a fixture may write
  ;; its throwaway transcripts under it.
  `(let* ((fsum-test--data-root (file-truename (make-temp-file "fsum-test-rr-" t)))
          (fleet-result-data-root fsum-test--data-root)
          (fleet-result-namespace-override "test-ns")
          (fsum-test--artifact-root (expand-file-name "fleet-artifacts" fsum-test--data-root))
          (fx ,fixture)
          (fleet-supervisor--store (if (plist-member fx :store) (plist-get fx :store) 'fake-store))
          (fsum-test--calls nil) (fsum-test--mutations nil))
     (cl-letf (((symbol-function 'fleet-core-fleet)
                (lambda (_s ref) (push 'fleet-core-fleet fsum-test--calls) (fsum-test--fake-core-fleet fx ref)))
               ((symbol-function 'fleet-store-get)
                (lambda (_s table id) (push 'fleet-store-get fsum-test--calls)
                  (cl-assert (equal table "fleets")) (fsum-test--row fx id)))
               ((symbol-function 'fleet-store-lieutenants)
                (lambda (_s id) (push 'fleet-store-lieutenants fsum-test--calls)
                  (cl-remove-if-not (lambda (r) (and (equal (plist-get r :parent-id) id) (not (equal (plist-get r :lifecycle) "archived"))))
                                    (plist-get fx :rows))))
               ((symbol-function 'fleet-store-snapshot)
                (lambda (_s &optional id) (push 'fleet-store-snapshot fsum-test--calls)
                  (cl-assert id nil "unscoped all-fleets snapshot is not allowed") (fsum-test--fake-snapshot fx id)))
               ((symbol-function 'fleet-config-lieutenants)
                (lambda (_name) (push 'fleet-config-lieutenants fsum-test--calls)
                  (when (plist-get fx :config-error) (signal 'error (list (plist-get fx :config-error))))
                  (mapcar (lambda (n) (list :name n :charter (concat n " charter"))) (plist-get fx :config)))))
       (cl-letf* ,(mapcar (lambda (f) `((symbol-function ',f) (lambda (&rest _) (push ',f fsum-test--mutations) (error "mutation %s" ',f))))
                          fsum-test--mutation-denylist)
         (unwind-protect
             (progn (unless (plist-get fx :no-checkpoint)
                      (fleet-result-init :root-id fsum-test--root-id :actor "test"))
                    ,@body)
           (should (null fsum-test--mutations))
           (should (cl-every (lambda (c) (memq c fsum-test--read-allowlist)) fsum-test--calls))
           (ignore-errors (delete-directory fsum-test--data-root t)))))))

(defun fsum-test--code (thunk)
  "Stable `fleet-read-error' code signaled by THUNK, or nil when it returns."
  (condition-case err (progn (funcall thunk) nil)
    (fleet-read-error (fleet-read-error-code err))))

(defun fsum-test--member (b name)
  "Member NAME of bearings B."
  (cl-find name (plist-get b :members) :key (lambda (m) (plist-get m :name)) :test #'equal))

(defun fsum-test--md (&rest args)
  "Rendered bearings for `fleet-read-bearings' ARGS (default: workshop)."
  (fsum-render (apply #'fleet-read-bearings (or args (list :session-fleet-id fsum-test--root-id)))))

;;;; Fail closed

(ert-deftest fsum-test-store-not-open-fails-closed ()
  (fsum-test-with-fixture (fsum-test--basic-fixture :store nil)
    (should (eq (fsum-test--code (lambda () (fleet-read-bearings :session-fleet-id fsum-test--root-id))) 'store-not-open))
    (let ((md (fsum-bearings :session-fleet-id fsum-test--root-id)))
      (should (string-match-p "store-not-open" md))
      (should (string-match-p "not permission to start" md)))
    (should (null fsum-test--calls))))

(ert-deftest fsum-test-fleet-not-loaded-fails-closed ()
  (fsum-test-with-fixture (fsum-test--basic-fixture)
    (cl-letf (((symbol-function 'fleet-store-snapshot) nil))
      (should (eq (fsum-test--code (lambda () (fleet-read-bearings :session-fleet-id fsum-test--root-id))) 'fleet-not-loaded)))))

;;;; Identity

(ert-deftest fsum-test-identity-required ()
  (fsum-test-with-fixture (fsum-test--basic-fixture)
    (should (eq (fsum-test--code (lambda () (fleet-read-bearings))) 'no-fleet-identity))))

(ert-deftest fsum-test-session-identity-selects-root ()
  (fsum-test-with-fixture (fsum-test--basic-fixture)
    (let ((b (fleet-read-bearings :session-fleet-id fsum-test--root-id :runtime-id "rt-ready")))
      (should (equal (plist-get (plist-get b :root) :name) "workshop"))
      (should (eq (plist-get (plist-get b :caller) :current-commander-p) t))
      (should (equal (plist-get b :revision) 42))
      (should (equal (mapcar (lambda (m) (plist-get m :name)) (plist-get b :members)) '("workshop" "frontend")))
      (should (equal (plist-get (fsum-test--member b "frontend") :selector) "workshop/frontend"))
      (should-not (fsum-test--member b "other"))
      (should (null (plist-get b :diagnostics))))))

(ert-deftest fsum-test-selector-conflict-refuses-without-reading ()
  (fsum-test-with-fixture (fsum-test--basic-fixture)
    (should (eq (fsum-test--code (lambda () (fleet-read-bearings :session-fleet-id fsum-test--root-id :selector "other"))) 'selector-conflict))
    (should-not (memq 'fleet-store-snapshot fsum-test--calls))
    (should (string-match-p "selector-conflict" (fsum-bearings :session-fleet-id fsum-test--root-id :selector "other")))))

(ert-deftest fsum-test-selector-agreeing-with-session-or-alone ()
  (fsum-test-with-fixture (fsum-test--basic-fixture)
    (should (equal (plist-get (plist-get (fleet-read-bearings :session-fleet-id fsum-test--root-id :selector "workshop") :root) :id) fsum-test--root-id))
    (should (equal (plist-get (plist-get (fleet-read-bearings :selector fsum-test--root-id) :root) :name) "workshop"))
    (should (eq (fsum-test--code (lambda () (fleet-read-bearings :selector "nope"))) 'no-such-fleet))
    (should (eq (fsum-test--code (lambda () (fleet-read-bearings :session-fleet-id "stale-uuid"))) 'no-such-fleet))))

(ert-deftest fsum-test-lieutenant-and-archived-refused ()
  (fsum-test-with-fixture (fsum-test--basic-fixture
                           :rows (list (fsum-test--fleet fsum-test--root-id "workshop")
                                       (fsum-test--fleet fsum-test--child-id "frontend" :parent-id fsum-test--root-id)
                                       (fsum-test--fleet fsum-test--other-id "gone" :lifecycle "archived")))
    (should (eq (fsum-test--code (lambda () (fleet-read-bearings :selector "workshop/frontend"))) 'not-a-root))
    (should (eq (fsum-test--code (lambda () (fleet-read-bearings :session-fleet-id fsum-test--child-id))) 'not-a-root))
    (should (eq (fsum-test--code (lambda () (fleet-read-bearings :session-fleet-id fsum-test--other-id))) 'fleet-archived))))

(ert-deftest fsum-test-caller-runtime-mismatch-is-a-diagnostic ()
  (fsum-test-with-fixture (fsum-test--basic-fixture)
    (let ((b (fleet-read-bearings :session-fleet-id fsum-test--root-id :runtime-id "rt-old")))
      (should (eq (plist-get (plist-get b :caller) :current-commander-p) nil))
      (should (cl-some (lambda (d) (string-match-p "rt-old.*not the root's current commander" d)) (plist-get b :diagnostics))))))

;;;; Children coverage

(ert-deftest fsum-test-children-union-keeps-stopped-uninitialized-and-declared ()
  (fsum-test-with-fixture (fsum-test--children-fixture)
    (let* ((b (fleet-read-bearings :session-fleet-id fsum-test--root-id))
           (names (mapcar (lambda (m) (plist-get m :name)) (plist-get b :members))))
      (should (equal names '("workshop" "frontend" "backend" "legacy" "docs")))
      (should (equal (plist-get (fsum-test--member b "docs") :status) "declared-not-created"))
      (should (null (plist-get (fsum-test--member b "docs") :id)))
      (should (eq (plist-get (fsum-test--member b "backend") :configured) t))
      (should (equal (plist-get (fsum-test--member b "backend") :commander-label) "stopped"))
      (should (eq (plist-get (fsum-test--member b "legacy") :configured) nil))
      (should (equal (plist-get (fsum-test--member b "legacy") :commander-label) "none"))
      (should (cl-some (lambda (d) (string-match-p "workshop/docs is declared" d)) (plist-get b :diagnostics)))
      (should (cl-some (lambda (d) (string-match-p "workshop/legacy exists but is no longer in config" d)) (plist-get b :diagnostics)))
      (should (equal (plist-get (plist-get b :counts) :members-existing) 4))
      (should (equal (plist-get (plist-get b :counts) :members-declared) 3))
      (should (equal (plist-get (plist-get b :counts) :tasks) 1))
      ;; the credential hash of runtime rows never leaves the reader
      (should-not (string-match-p "SECRET-HASH" (format "%S" b)))
      (let ((md (fsum-render b)))
        (should (string-match-p "`docs` | declared in config, not created | — | —" md))
        (should (string-match-p "`backend` | stopped |" md))
        (should (string-match-p "Lieutenant `backend` has no live session (stopped)" md))
        (should (string-match-p "Lieutenant `legacy` has no live session (none)" md))
        (should (string-match-p "1 task moving; 2 of 5 supervisors live, 1 not observed" md))))))

(ert-deftest fsum-test-config-unreadable-is-unknown-coverage ()
  (fsum-test-with-fixture (plist-put (fsum-test--children-fixture) :config-error "fleets.workshop.lieutenants.docs must be an object")
    (let ((b (fleet-read-bearings :session-fleet-id fsum-test--root-id)))
      (should (equal (plist-get (plist-get b :config) :status) "error"))
      (should (equal (mapcar (lambda (m) (plist-get m :name)) (plist-get b :members)) '("workshop" "frontend" "backend" "legacy")))
      (should (eq (plist-get (fsum-test--member b "frontend") :configured) 'unknown))
      (should (cl-some (lambda (d) (string-match-p "configuration unreadable" d)) (plist-get b :diagnostics)))
      (should-not (cl-some (lambda (d) (string-match-p "no longer in config" d)) (plist-get b :diagnostics)))
      (should (string-match-p "\\*\\*Coverage\\*\\*\n- Owner configuration unreadable" (fsum-render b))))))

(ert-deftest fsum-test-partial-read-failure-names-the-member ()
  (fsum-test-with-fixture (plist-put (fsum-test--children-fixture) :fail-snapshots (list fsum-test--child-id))
    (let* ((b (fleet-read-bearings :session-fleet-id fsum-test--root-id))
           (fe (fsum-test--member b "frontend")))
      (should (equal (plist-get fe :status) "read-failed"))
      (should (equal (plist-get fe :id) fsum-test--child-id))
      (should (null (plist-get fe :tasks)))
      (should (cl-some (lambda (d) (string-match-p "workshop/frontend: read failed (database is locked)" d)) (plist-get b :diagnostics)))
      (should (equal (plist-get (fsum-test--member b "backend") :status) "observed"))
      (let ((md (fsum-render b)))
        (should (string-match-p "`frontend` | read failed: database is locked | — | —" md))
        (should (string-match-p "2 not observed" md))))))

(ert-deftest fsum-test-root-with-zero-lieutenants-is-valid ()
  (fsum-test-with-fixture (list :rows (list (fsum-test--fleet fsum-test--root-id "solo"))
                                :enriched (list (cons fsum-test--root-id (list :commander (fsum-test--rt "ready")))))
    (let ((b (fleet-read-bearings :session-fleet-id fsum-test--root-id)))
      (should (= 1 (length (plist-get b :members))))
      (should (null (plist-get b :diagnostics)))
      (let ((md (fsum-render b)))
        (should (string-match-p "No tasks retained; 1 of 1 supervisor live" md))
        (should (string-match-p "No tasks retained\\.\n" md))
        (should (string-match-p "Nothing needs you right now" md))))))

;;;; Requests, tasks, states

(ert-deftest fsum-test-requests-deduplicated-and-not-tasks ()
  (let ((req (list :id "r1" :parent-fleet-id fsum-test--root-id :child-fleet-id fsum-test--child-id
                   :subject "navigation" :state "open" :created-at "2026-09-17T09:00:00Z")))
    (fsum-test-with-fixture (fsum-test--basic-fixture :root (list :open-requests (list req))
                                                      :child (list :open-requests (list req) :tasks (list (fsum-test--task "t1" "navigation"))))
      (let* ((b (fleet-read-bearings :session-fleet-id fsum-test--root-id)) (md (fsum-render b)))
        (should (= 1 (length (plist-get b :requests))))
        (should (= 1 (plist-get (plist-get b :counts) :tasks)))
        (should (string-match-p "1 request open to lieutenants" md))
        (should (string-match-p "UI and accessibility (1 request open)" md))
        (should (string-match-p "| frontend | `navigation` | Working (reported; no runtime)" md))
        (should (string-match-p "1 task moving; 2 of 2 supervisors live\\." md))))))

(ert-deftest fsum-test-done-is-not-verified ()
  (fsum-test-with-fixture (fsum-test--basic-fixture
                           :root (list :tasks (list (fsum-test--task "t1" "audit" :phase "done"
                                                                     :artifacts (list (list :kind "report" :rel-path "report.md" :verified 0)))
                                                    (fsum-test--task "t2" "pr-work" :phase "done"
                                                                     :artifacts (list (list :kind "pr" :external-ref "https://example.test/pr/7" :verified 1))))))
    (let ((md (fsum-test--md)))
      (should (string-match-p "`audit` | Reported done | verification pending |" md))
      (should (string-match-p "`pr-work` | Reported done · verified | closeout (teardown) pending · https://example.test/pr/7 (reported, not rechecked)" md))
      (should (string-match-p "1 reported done pending verification, 1 verified awaiting closeout" md))
      (should (string-match-p "1 reported-done task to verify" md))
      (should (string-match-p "Nothing needs you right now" md)))))

(ert-deftest fsum-test-decision-authority-routes-needs-you ()
  (fsum-test-with-fixture (fsum-test--basic-fixture
                           :root (list :tasks (list (fsum-test--task "t1" "contrast" :phase "needs-decision"
                                                                     :decisions (list (fsum-test--decision "d1" "Which threshold?" "human")))
                                                    (fsum-test--task "t2" "naming" :phase "needs-decision"
                                                                     :decisions (list (fsum-test--decision "d2" "snake or kebab?" "commander")))
                                                    (fsum-test--task "t3" "orphan" :phase "needs-decision" :detail "asked in chat only"))))
    (let* ((b (fleet-read-bearings :session-fleet-id fsum-test--root-id)) (md (fsum-render b)))
      (should (equal (plist-get (car (plist-get (car (plist-get (fsum-test--member b "workshop") :tasks)) :decisions)) :authority) "human"))
      (should (string-match-p "- Decide for `contrast` (Commander): Which threshold\\?" md))
      (should-not (string-match-p "Decide for `naming`" md))
      (should (string-match-p "`naming` | Decision (commander) | snake or kebab\\?" md))
      (should (string-match-p "`orphan` | Decision (routing unverified) | asked in chat only" md))
      (should (string-match-p "Supervisors' queue: 1 commander-authority decision, 1 decision with unverified routing\\." md))
      (should (string-match-p "3 waiting on an answer" md))
      (should-not (string-match-p "/frev" md)))))

(ert-deftest fsum-test-working-is-evidence-qualified ()
  (fsum-test-with-fixture (fsum-test--basic-fixture
                           :root (list :tasks (list (fsum-test--task "t1" "live" :runtime (fsum-test--rt "ready" :turn-state "running" :active-tool "{\"name\":\"shell\"}"))
                                                    (fsum-test--task "t2" "idle" :runtime (fsum-test--rt "ready")
                                                                     :messages-recent (list (list :id "m1" :origin "commander" :state "accepted" :created-at "2026-09-17T11:00:00.000Z")
                                                                                            (list :id "m0" :origin "human" :state "finished" :created-at "2026-09-17T09:00:00.000Z")))
                                                    (fsum-test--task "t3" "gone")
                                                    (fsum-test--task "t4" "lost" :runtime (fsum-test--rt "lost"))
                                                    (fsum-test--task "t5" "parked" :lifecycle "suspended"))))
    (let ((md (fsum-test--md)))
      (should (string-match-p "`live` | Working · shell | live detail" md))
      (should (string-match-p "`idle` | Working (reported; idle now) | idle detail · 1 message sent since this status" md))
      (should (string-match-p "`gone` | Working (reported; no runtime) | gone detail" md))
      (should (string-match-p "`lost` | Runtime lost | connection lost; service not proven stopped" md))
      (should (string-match-p "`parked` | Suspended (parked) | no resume requested" md))
      (should (string-match-p "- `lost` (Commander): connection lost" md))
      (should-not (string-match-p "- `parked`" md))
      (should (< (string-match "`live`" md) (string-match "`lost`" md) (string-match "`parked`" md))))))

(ert-deftest fsum-test-native-prompts-need-the-user ()
  (fsum-test-with-fixture (fsum-test--basic-fixture
                           :root (list :commander (fsum-test--rt "ready" :pending-question "{\"question\":\"Proceed with the merge?\"}")
                                       :pending-events 2
                                       :tasks (list (fsum-test--task "t1" "approve-me" :runtime (fsum-test--rt "ready" :pending-approvals "[\"tc1\"]")))))
    (let ((md (fsum-test--md)))
      (should (string-match-p "2 events pending · native question waiting" md))
      (should (string-match-p "- Commander has a native question waiting in its chat: Proceed with the merge\\?" md))
      (should (string-match-p "`approve-me` | Native approval waiting | only you can approve it" md))
      (should (string-match-p "- `approve-me` (Commander): only you can approve it" md))
      (should (string-match-p "2 pending events" md)))))

(ert-deftest fsum-test-park-and-watch-are-administrative ()
  (fsum-test-with-fixture (fsum-test--basic-fixture
                           :rows (list (fsum-test--fleet fsum-test--root-id "workshop" :lifecycle "parked" :supervision 0)
                                       (fsum-test--fleet fsum-test--child-id "frontend" :parent-id fsum-test--root-id :lifecycle "parked"))
                           :child (list :commander (fsum-test--rt "stopped")))
    (let ((md (fsum-test--md)))
      (should (string-match-p "parked · watch paused" md))
      (should (string-match-p "`frontend` | stopped · parked" md))
      (should (string-match-p "Nothing needs you right now" md)))))

(ert-deftest fsum-test-detail-bounded-identity-kept ()
  (let ((long (concat (make-string 900 ?x) " sent since: 2 messages")))
    (fsum-test-with-fixture (fsum-test--basic-fixture :root (list :tasks (list (fsum-test--task "t1" "verbose" :detail long))))
      (let* ((b (fleet-read-bearings :session-fleet-id fsum-test--root-id))
             (task (car (plist-get (fsum-test--member b "workshop") :tasks))))
        (should (< (length (plist-get task :detail)) (length long)))
        (should (string-match-p "…abbreviated…" (plist-get task :detail)))
        (should (string-suffix-p "sent since: 2 messages" (plist-get task :detail)))
        (should (equal (plist-get task :name) "verbose"))
        (should (string-match-p "`verbose`" (fsum-render b)))))))

(ert-deftest fsum-test-rollup-keeps-exceptions-and-names-tasks ()
  (let* ((routine (cl-loop for i from 1 to 12 collect (fsum-test--task (format "w%d" i) (format "routine-%02d" i)
                                                                        :runtime (fsum-test--rt "ready" :turn-state "running"))))
         (tasks (append routine
                        (list (fsum-test--task "b" "stuck" :phase "blocked" :detail "needs credentials")
                              (fsum-test--task "d" "choose" :phase "needs-decision" :decisions (list (fsum-test--decision "d1" "A or B?" "human")))
                              (fsum-test--task "o" "finished" :phase "done")))))
    (fsum-test-with-fixture (fsum-test--basic-fixture :root (list :tasks tasks))
      (let ((md (fsum-test--md)))
        (should (string-match-p "| Commander | 12 tasks (rolled up) | Working | `routine-01`, `routine-02`" md))
        (dolist (task routine) (should (string-match-p (regexp-quote (format "`%s`" (plist-get task :name))) md)))
        (should (string-match-p "`stuck` | Blocked | needs credentials" md))
        (should (string-match-p "`choose` | Decision (yours) | A or B\\?" md))
        (should (string-match-p "`finished` | Reported done | verification pending" md))
        (should (string-match-p "12 tasks moving, 1 waiting on an answer, 1 blocked, failed or lost, 1 reported done pending verification" md))
        (should (string-match-p "- Decide for `choose`" md))))))

(ert-deftest fsum-test-frev-hint-only-when-several-owners-need-you ()
  (fsum-test-with-fixture (fsum-test--basic-fixture
                           :root (list :tasks (list (fsum-test--task "a" "one" :phase "needs-decision" :decisions (list (fsum-test--decision "d1" "q1" "human")))
                                                    (fsum-test--task "b" "two" :phase "needs-decision" :decisions (list (fsum-test--decision "d2" "q2" "human")))))
                           :child (list :tasks (list (fsum-test--task "c" "three" :phase "needs-decision" :decisions (list (fsum-test--decision "d3" "q3" "human"))))))
    (let ((md (fsum-test--md)))
      (should (string-match-p "3 items need you across 2 owners — `/frev`" md)))))

(ert-deftest fsum-test-json-export-parses ()
  (fsum-test-with-fixture (fsum-test--children-fixture)
    (let ((parsed (json-parse-string (fleet-read-bearings-json :session-fleet-id fsum-test--root-id) :object-type 'alist)))
      (should (eql (alist-get 'schema parsed) 1))
      (should (equal (alist-get 'name (alist-get 'root parsed)) "workshop"))
      (should (= 5 (length (alist-get 'members parsed)))))))

(ert-deftest fsum-test-table-cells-are-safe ()
  (fsum-test-with-fixture (fsum-test--basic-fixture :root (list :tasks (list (fsum-test--task "t1" "pipes" :detail "a | b\nc\td"))))
    (should (string-match-p (regexp-quote "a \\| b c d") (fsum-test--md)))))

;;;; Unresolved owner-facing results — fixtures

(defun fsum-test--transcript (runtime-id entries)
  "Write ENTRIES as RUNTIME-ID's commander transcript under the fixture artifact root.
An entry is a plist (serialized as one JSON line) or a raw string, so a
deliberately damaged line can be injected."
  (let ((file (expand-file-name (format "commander/runs/%s/transcript.jsonl" runtime-id) fsum-test--artifact-root))
        ;; Pinned like Fleet's own transcript writer: an unpinned write of
        ;; non-ASCII content asks which coding system to use, which hangs.
        (coding-system-for-write 'utf-8))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (dolist (e entries) (insert (if (stringp e) e (json-serialize e)) "\n")))
    file))

(defun fsum-test--submit (at text) "Fleet submit line AT with TEXT." (list :at at :role "fleet" :kind "submit" :message-id "m" :text text))
(defun fsum-test--user (at text) "ECA user line AT with TEXT." (list :at at :role "user" :kind "text" :text text))
(defun fsum-test--assistant (at text) "Assistant line AT with TEXT." (list :at at :role "assistant" :kind "text" :text text))
(defun fsum-test--tool (at name) "Tool line AT for tool NAME." (list :at at :role "tool" :kind "called" :tool-id "tc" :name name :ms 7))

(cl-defun fsum-test--result-fixture (&key runs empty-runs no-checkpoint tasks)
  "Basic fixture whose root fleet has a throwaway artifact root.
RUNS is an alist of (RUNTIME-ID . ENTRIES) written as commander transcripts;
EMPTY-RUNS names run directories with no transcript at all; NO-CHECKPOINT
suppresses checkpoint creation; TASKS are extra root tasks."
  (make-directory fsum-test--artifact-root t)
  (dolist (run runs) (fsum-test--transcript (car run) (cdr run)))
  (dolist (id empty-runs)
    (make-directory (expand-file-name (format "commander/runs/%s" id) fsum-test--artifact-root) t))
  (append (list :no-checkpoint no-checkpoint)
          (fsum-test--basic-fixture
           :rows (list (fsum-test--fleet fsum-test--root-id "workshop" :artifact-root fsum-test--artifact-root
                                         :commander-runtime-id "rt-ready")
                       (fsum-test--fleet fsum-test--child-id "frontend" :parent-id fsum-test--root-id :charter "UI"))
           :root (list :tasks tasks))))

(defun fsum-test--result-code (thunk)
  "Stable `fleet-result-error' code signaled by THUNK, or nil when it returns."
  (condition-case err (progn (funcall thunk) nil)
    (fleet-result-error (fleet-result-error-code err))))

(cl-defun fsum-test--declare (summary &key (why "no disposition recorded") (expected "answer it")
                                      (presented t) fingerprints)
  "Declare SUMMARY in the fixture checkpoint and return the new item id.
WHY, EXPECTED, PRESENTED and FINGERPRINTS are passed through."
  (let ((res (fleet-result-declare :root-id fsum-test--root-id :summary summary :why why :expected expected
                                   :presented presented :fingerprints fingerprints :actor "test")))
    (plist-get (car (last (plist-get res :items))) :id)))

(defun fsum-test--tree-digest (dir)
  "Name, size and content hash of every file under DIR, sorted."
  (mapcar (lambda (f)
            (list (file-relative-name f dir)
                  (file-attribute-size (file-attributes f))
                  (secure-hash 'sha256 (with-temp-buffer (insert-file-contents-literally f) (buffer-string)))))
          (sort (directory-files-recursively dir "" nil) #'string<)))

(defun fsum-test--scan (&rest args)
  "Scan the fixture artifact root's transcripts with ARGS."
  (apply #'fleet-result-scan :runs-dir (fleet-result-runs-directory fsum-test--artifact-root) args))

(defun fsum-test--coverage (md)
  "Non-nil when MD has a Coverage section."
  (string-match-p "\\*\\*Coverage\\*\\*" md))

(defun fsum-test--run (scan runtime-id)
  "Per-run report for RUNTIME-ID in SCAN."
  (cl-find runtime-id (plist-get scan :runs) :key (lambda (r) (plist-get r :runtime-id)) :test #'equal))

;;;; Unresolved owner-facing results — the two axes

(ert-deftest fsum-test-result-acknowledged-but-still-outstanding ()
  "The decisive case: \"I saw it; I'll review later\" acknowledges without resolving."
  (fsum-test-with-fixture (fsum-test--result-fixture)
    (let* ((id (fsum-test--declare "PR #4 delivered; last reported open and unmerged"
                                   :why "no disposition recorded" :expected "report merged, declined or deferred"))
           (before (fsum-test--md)))
      (should (string-match-p (regexp-quote (format "`%s`" id)) before))
      (should (string-match-p "not acknowledged, disposition outstanding" before))
      (should-not (string-match-p "Nothing needs you" before))
      (fleet-result-record :root-id fsum-test--root-id :id id :acknowledged t :basis "owner-report"
                           :note "owner: saw it, will review later" :actor "test")
      (let* ((read (fleet-result-read :root-id fsum-test--root-id))
             (item (fleet-result-item read id))
             (md (fsum-test--md)))
        (should (equal (plist-get item :acknowledgement) "acknowledged"))
        (should (equal (plist-get item :disposition) "outstanding"))
        (should (equal (plist-get item :basis) "owner-report"))
        (should-not (string-match-p "not acknowledged" md))
        (should (string-match-p "acknowledged, disposition outstanding" md))
        (should (string-match-p "Last: owner: saw it, will review later" md))
        (should-not (string-match-p "Nothing needs you" md))))))

(ert-deftest fsum-test-result-declaration-needs-summary-reason-and-expectation ()
  (fsum-test-with-fixture (fsum-test--result-fixture)
    (should (eq (fsum-test--result-code
                 (lambda () (fleet-result-declare :root-id fsum-test--root-id :summary "done" :why "  " :expected "x")))
                'incomplete-declaration))
    (should (eq (fsum-test--result-code
                 (lambda () (fleet-result-declare :root-id fsum-test--root-id :summary "done" :why "x" :expected nil)))
                'incomplete-declaration))
    (should (null (plist-get (fleet-result-read :root-id fsum-test--root-id) :items)))))

(ert-deftest fsum-test-result-record-needs-a-basis-and-refuses-terminal-items ()
  (fsum-test-with-fixture (fsum-test--result-fixture)
    (let ((id (fsum-test--declare "a result")))
      (should (eq (fsum-test--result-code (lambda () (fleet-result-record :root-id fsum-test--root-id :id id :acknowledged t)))
                  'invalid-basis))
      (should (eq (fsum-test--result-code (lambda () (fleet-result-record :root-id fsum-test--root-id :id id :basis "guess"
                                                                          :disposition "resolved")))
                  'invalid-basis))
      (fleet-result-record :root-id fsum-test--root-id :id id :disposition "resolved" :basis "owner-report" :note "owner: done")
      (should (eq (fsum-test--result-code (lambda () (fleet-result-record :root-id fsum-test--root-id :id id
                                                                          :disposition "outstanding" :basis "owner-report")))
                  'item-terminal)))))

(ert-deftest fsum-test-result-multiple-results-in-one-turn-are-independent ()
  (fsum-test-with-fixture (fsum-test--result-fixture)
    (let ((ids (mapcar (lambda (n) (fsum-test--declare (format "result %s of one turn" n))) '("A" "B" "C"))))
      (should (= 3 (length (cl-remove-duplicates ids :test #'equal))))
      (fleet-result-record :root-id fsum-test--root-id :id (nth 0 ids) :acknowledged t :disposition "resolved"
                           :basis "owner-report" :note "owner answered the diagnosis")
      (let ((md (fsum-test--md)))
        (should-not (string-match-p (regexp-quote (nth 0 ids)) md))
        (should (string-match-p (regexp-quote (nth 1 ids)) md))
        (should (string-match-p (regexp-quote (nth 2 ids)) md))))))

(ert-deftest fsum-test-result-resolution-invents-no-follow-up-thread ()
  "A submitted support draft resolves; the waiting thread exists only if declared."
  (fsum-test-with-fixture (fsum-test--result-fixture)
    (let ((draft (fsum-test--declare "Support ticket draft ready" :expected "submit or decline, then report the outcome")))
      (fleet-result-record :root-id fsum-test--root-id :id draft :acknowledged t :disposition "resolved"
                           :basis "owner-report" :note "owner: submitted, case 84721")
      (should (= 1 (length (plist-get (fleet-result-read :root-id fsum-test--root-id) :items))))
      (should (string-match-p "Nothing needs you right now" (fsum-test--md)))
      (let ((relay (fsum-test--declare "Case 84721 submitted; the support answer is not back"
                                       :expected "relay the support response and the next step")))
        (let ((md (fsum-test--md)))
          (should (= 2 (length (plist-get (fleet-result-read :root-id fsum-test--root-id) :items))))
          (should (string-match-p (regexp-quote relay) md))
          (should-not (string-match-p (regexp-quote draft) md)))))))

(ert-deftest fsum-test-result-supersede-links-and-needs-an-existing-successor ()
  (fsum-test-with-fixture (fsum-test--result-fixture)
    (let ((old (fsum-test--declare "the first ask")))
      (should (eq (fsum-test--result-code (lambda () (fleet-result-supersede :root-id fsum-test--root-id :id old
                                                                             :successor-id "rr-nothing")))
                  'no-such-successor))
      (let ((new (fsum-test--declare "the replacement ask")))
        (fleet-result-supersede :root-id fsum-test--root-id :id old :successor-id new :note "narrowed")
        (let ((item (fleet-result-item (fleet-result-read :root-id fsum-test--root-id) old)))
          (should (equal (plist-get item :disposition) "superseded"))
          (should (equal (plist-get item :successor-id) new)))))))

(ert-deftest fsum-test-result-staged-item-is-coverage-not-needs-you ()
  (fsum-test-with-fixture (fsum-test--result-fixture)
    (let ((id (fsum-test--declare "staged, never emitted" :presented nil)))
      (let ((md (fsum-test--md)))
        (should-not (string-match-p (regexp-quote id) md))
        (should (string-match-p "1 unresolved result was declared but never confirmed presented" md)))
      (fleet-result-presented :root-id fsum-test--root-id :id id)
      (let ((item (fleet-result-item (fleet-result-read :root-id fsum-test--root-id) id)))
        ;; presentation is not acknowledgement
        (should (equal (plist-get item :presentation) "presented"))
        (should (equal (plist-get item :acknowledgement) "unacknowledged")))
      (should (string-match-p (regexp-quote id) (fsum-test--md))))))

;;;; Unresolved owner-facing results — durability and failure

(ert-deftest fsum-test-result-absent-checkpoint-is-not-a-clean-bill ()
  (fsum-test-with-fixture (fsum-test--result-fixture :no-checkpoint t)
    (let ((md (fsum-test--md)))
      (should-not (string-match-p "Nothing needs you right now" md))
      (should (string-match-p "not a clean bill" md))
      (should (fsum-test--coverage md))
      (should (string-match-p "No result-review checkpoint exists for this fleet yet" md)))))

(ert-deftest fsum-test-result-corrupt-checkpoint-is-preserved-and-refuses-writes ()
  (fsum-test-with-fixture (fsum-test--result-fixture)
    (let* ((dir (fleet-result-directory :root-id fsum-test--root-id))
           (file (fleet-result-state-file dir))
           (garbage "{\"schema\": 1, \"items\": [tru"))
      (with-temp-file file (insert garbage))
      (let ((md (fsum-test--md)))
        (should (string-match-p "did not parse" md))
        (should (string-match-p "not a clean bill" md)))
      (should (eq (fsum-test--result-code (lambda () (fsum-test--declare "anything"))) 'checkpoint-corrupt))
      (should (equal garbage (with-temp-buffer (insert-file-contents file) (buffer-string)))))))

(ert-deftest fsum-test-result-newer-schema-is-refused-not-downgraded ()
  (fsum-test-with-fixture (fsum-test--result-fixture)
    (let ((file (fleet-result-state-file (fleet-result-directory :root-id fsum-test--root-id))))
      (with-temp-file file (insert "{\"schema\":99,\"items\":[]}"))
      (should (equal (plist-get (fleet-result-read :root-id fsum-test--root-id) :status) "unsupported"))
      (should (eq (fsum-test--result-code (lambda () (fsum-test--declare "anything"))) 'checkpoint-unsupported))
      (should (string-match-p "schema 99" (fsum-test--md))))))

(ert-deftest fsum-test-result-held-lock-fails-visibly-and-is-not-broken ()
  (fsum-test-with-fixture (fsum-test--result-fixture)
    (let* ((dir (fleet-result-directory :root-id fsum-test--root-id))
           (lock (fleet-result-lock-file dir))
           (fleet-result-lock-timeout 0.1))
      (write-region "4242 another writer\n" nil lock nil 'silent)
      (should (eq (fsum-test--result-code (lambda () (fsum-test--declare "blocked by the lock"))) 'checkpoint-locked))
      (should (file-exists-p lock))
      (should (null (plist-get (fleet-result-read :root-id fsum-test--root-id) :items)))
      (delete-file lock)
      (should (stringp (fsum-test--declare "now it works"))))))

(ert-deftest fsum-test-result-batch-is-all-or-nothing ()
  (fsum-test-with-fixture (fsum-test--result-fixture)
    (let ((before (plist-get (fleet-result-read :root-id fsum-test--root-id) :revision)))
      (should (eq (fsum-test--result-code
                   (lambda () (fleet-result-apply
                               :root-id fsum-test--root-id
                               :ops (list (list :op "declare" :summary "first" :why "w" :expected "e")
                                          (list :op "record" :id "rr-missing" :basis "owner-report" :acknowledged t)))))
                  'no-such-item))
      (let ((read (fleet-result-read :root-id fsum-test--root-id)))
        (should (null (plist-get read :items)))
        (should (equal before (plist-get read :revision)))))))

(ert-deftest fsum-test-result-audit-log-records-every-applied-operation ()
  (fsum-test-with-fixture (fsum-test--result-fixture)
    (let* ((id (fsum-test--declare "audited"))
           (dir (fleet-result-directory :root-id fsum-test--root-id)))
      (fleet-result-record :root-id fsum-test--root-id :id id :acknowledged t :basis "owner-report" :note "seen")
      (let ((lines (with-temp-buffer (insert-file-contents (fleet-result-events-file dir))
                                     (split-string (buffer-string) "\n" t))))
        ;; init, declare, record
        (should (= 3 (length lines)))
        (should (equal '("init" "declare" "record")
                       (mapcar (lambda (l) (plist-get (json-parse-string l :object-type 'plist) :op)) lines)))
        (should (equal 3 (plist-get (json-parse-string (car (last lines)) :object-type 'plist) :to-revision)))
        (should (equal 3 (plist-get (fleet-result-read :root-id fsum-test--root-id) :revision)))))))

(ert-deftest fsum-test-result-non-ascii-text-round-trips ()
  "Clipping appends `…'; an unpinned write would ask which coding system to use.
That prompt hangs a daemon (and the owner's Emacs) instead of failing, so
every checkpoint write pins UTF-8.  This is the regression for it."
  (fsum-test-with-fixture (fsum-test--result-fixture)
    (let* ((long (concat "résumé " (make-string fleet-result-summary-limit ?é)))
           (id (fsum-test--declare long :why "naïve — still open" :expected "réponse")))
      (let ((item (fleet-result-item (fleet-result-read :root-id fsum-test--root-id) id)))
        (should (string-prefix-p "résumé" (plist-get item :summary)))
        (should (string-suffix-p "…" (plist-get item :summary)))
        (should (equal (plist-get item :expected) "réponse")))
      (let ((audit (with-temp-buffer
                     (let ((coding-system-for-read 'utf-8))
                       (insert-file-contents (fleet-result-events-file
                                              (fleet-result-directory :root-id fsum-test--root-id))))
                     (buffer-string))))
        (should (string-match-p "résumé" audit))
        (should (string-match-p "naïve" audit)))
      (should (string-match-p "réponse" (fsum-test--md))))))

(ert-deftest fsum-test-result-survives-commander-replacement ()
  "A new commander runtime keeps the checkpoint and still sees the old transcript."
  (fsum-test-with-fixture
      (fsum-test--result-fixture
       :runs (list (cons "rt-old" (list (fsum-test--submit "2026-09-20T09:00:00.000Z" "go")
                                        (fsum-test--assistant "2026-09-20T09:01:00.000Z"
                                                              "The migration plan is ready. Shall I start it?")))
                   (cons "rt-new" (list (fsum-test--submit "2026-09-22T09:00:00.000Z" "boot")
                                        (fsum-test--assistant "2026-09-22T09:01:00.000Z" "Booted; nothing to report.")))))
    (let ((id (fsum-test--declare "declared before the replacement")))
      (let ((md (fsum-test--md)))
        (should (string-match-p (regexp-quote id) md))
        (should (string-match-p "may need acknowledgement" md))
        (should (string-match-p "runtime `rt-old`" md))
        (should (string-match-p "Shall I start it" md))))))

;;;; Unresolved owner-facing results — the transcript collector

(ert-deftest fsum-test-result-collector-pairs-turns-and-keeps-run-boundaries ()
  (fsum-test-with-fixture
      (fsum-test--result-fixture
       :runs (list (cons "rt-old" (list (fsum-test--submit "2026-09-20T09:00:00.000Z" "the question")
                                        (fsum-test--user "2026-09-20T09:00:00.100Z" "the question")
                                        (fsum-test--tool "2026-09-20T09:00:30.000Z" "shell")
                                        (fsum-test--assistant "2026-09-20T09:01:00.000Z" "the answer")))
                   (cons "rt-new" (list (fsum-test--submit "2026-09-22T09:00:00.000Z" "a later question")
                                        (fsum-test--assistant "2026-09-22T09:01:00.000Z" "a later answer")))))
    (let* ((scan (fsum-test--scan))
           (turns (plist-get scan :turns)))
      (should (equal '("rt-old" "rt-new") (mapcar (lambda (tn) (plist-get tn :runtime-id)) turns)))
      (should (equal '("the answer" "a later answer") (mapcar (lambda (tn) (plist-get tn :text)) turns)))
      ;; the duplicate user rendering of the submitted prompt is suppressed, not paired
      (should (equal "the question" (plist-get (car turns) :input)))
      (should (equal 1 (plist-get (fsum-test--run scan "rt-old") :tool-lines)))
      (should (equal 0 (plist-get (fsum-test--run scan "rt-new") :tool-lines)))
      (should-not (plist-get scan :truncated))
      (should (null (plist-get scan :coverage))))))

(ert-deftest fsum-test-result-collector-reports-clipped-missing-corrupt-and-unfinished ()
  (fsum-test-with-fixture
      (fsum-test--result-fixture
       :empty-runs '("rt-empty")
       :runs (list (cons "rt-ready"
                         (list (fsum-test--submit "2026-09-22T09:00:00.000Z" "go")
                               "{\"at\":\"2026-09-22T09:00:30.000Z\", this is not json"
                               (fsum-test--assistant "2026-09-22T09:01:00.000Z"
                                                     (concat (make-string 3999 ?x) "?…"))
                               (fsum-test--submit "2026-09-22T09:02:00.000Z" "and then?")))))
    (let* ((scan (fsum-test--scan))
           (coverage (string-join (plist-get scan :coverage) "\n"))
           (md (fsum-test--md)))
      (should (string-match-p "unparsable line" coverage))
      (should (string-match-p "no transcript.jsonl" coverage))
      (should (string-match-p "unfinished turn" coverage))
      (should (string-match-p "clipped at 4000 characters" coverage))
      (should (plist-get (car (plist-get scan :turns)) :clipped))
      (should (string-match-p "transcript clipped; the end of this result was not retained" md))
      ;; damage never becomes closure
      (should (string-match-p "may need acknowledgement" md)))))

(ert-deftest fsum-test-result-collector-resumes-from-cursors-and-notices-a-shrunken-file ()
  (fsum-test-with-fixture
      (fsum-test--result-fixture
       :runs (list (cons "rt-ready" (list (fsum-test--assistant "2026-09-22T09:01:00.000Z" "first, shall I?")))))
    (let* ((first (fsum-test--scan))
           (cursors (plist-get first :cursors)))
      (should (= 1 (length (plist-get first :turns))))
      (should (= 1 (length cursors)))
      ;; nothing new: the same cursor yields no turns and no invented coverage
      (should (null (plist-get (fsum-test--scan :cursors cursors) :turns)))
      (fsum-test--transcript "rt-ready" (list (fsum-test--assistant "2026-09-22T09:01:00.000Z" "first, shall I?")
                                              (fsum-test--assistant "2026-09-22T09:05:00.000Z" "second, shall I?")))
      (let ((next (fsum-test--scan :cursors cursors)))
        (should (equal '("second, shall I?") (mapcar (lambda (tn) (plist-get tn :text)) (plist-get next :turns)))))
      ;; a cursor past the end of a shrunken transcript rescans and says so
      (let* ((stale (list (list :runtime-id "rt-ready" :bytes 999999 :size 999999
                                :head-hash (plist-get (car (plist-get (fsum-test--scan) :cursors)) :head-hash))))
             (rescan (fsum-test--scan :cursors stale)))
        (should (= 2 (length (plist-get rescan :turns))))
        (should (string-match-p "shrank since the last review"
                                (string-join (plist-get rescan :coverage) "\n"))))
      ;; a transcript replaced by a different one is rescanned from the start too
      (let* ((changed (list (list :runtime-id "rt-ready" :bytes 10 :size 10 :head-hash "not-this-file")))
             (rescan (fsum-test--scan :cursors changed)))
        (should (= 2 (length (plist-get rescan :turns))))
        (should (string-match-p "changed identity since the last review"
                                (string-join (plist-get rescan :coverage) "\n")))))))

(ert-deftest fsum-test-result-completed-report-produces-nothing ()
  (fsum-test-with-fixture
      (fsum-test--result-fixture
       :runs (list (cons "rt-ready"
                         (list (fsum-test--assistant "2026-09-22T09:01:00.000Z"
                                                     "The telemetry fix is installed and complete. No follow-up is expected from anyone.")))))
    (let ((md (fsum-test--md)))
      (should-not (string-match-p "may need acknowledgement" md))
      (should (string-match-p "Nothing needs you right now" md))
      (should (null (plist-get (fleet-result-read :root-id fsum-test--root-id) :items))))))

(ert-deftest fsum-test-result-candidates-are-separate-capped-and-not-authoritative ()
  (fsum-test-with-fixture
      (fsum-test--result-fixture
       :runs (list (cons "rt-ready"
                         (cl-loop for i from 1 to 5
                                  collect (fsum-test--assistant (format "2026-09-22T09:0%d:00.000Z" i)
                                                                (format "Result %d is ready. Please review it." i))))))
    (let ((md (fsum-test--md)))
      (should (string-match-p "Nothing confirmed needs you; 3 recent results below may need acknowledgement" md))
      (should (string-match-p "not acknowledged, not a disposition, not Fleet truth" md))
      ;; newest three only, and never promoted into Needs you
      (should (string-match-p "Result 5 is ready" md))
      (should (string-match-p "Result 3 is ready" md))
      (should-not (string-match-p "Result 2 is ready" md))
      (should (< (string-match "Nothing confirmed needs you" md) (string-match "Result 3 is ready" md))))))

(ert-deftest fsum-test-result-unrelated-reply-updates-nothing ()
  (fsum-test-with-fixture
      (fsum-test--result-fixture
       :runs (list (cons "rt-ready"
                         (list (fsum-test--assistant "2026-09-22T09:01:00.000Z"
                                                     "The study recommends option A. Should Fleet implement it?")
                               (fsum-test--submit "2026-09-22T09:05:00.000Z"
                                                  "Also, what is the status of the telemetry task?")
                               (fsum-test--assistant "2026-09-22T09:06:00.000Z" "Telemetry is running.")))))
    (let* ((id (fsum-test--declare "the study recommendation"))
           (before (fleet-result-read :root-id fsum-test--root-id)))
      (let ((md (fsum-test--md)))
        (should (string-match-p "Should Fleet implement it" md))
        (should (string-match-p "next user message (context only, not an acknowledgement): Also, what is the status" md)))
      (let ((after (fleet-result-read :root-id fsum-test--root-id)))
        (should (equal (plist-get before :revision) (plist-get after :revision)))
        (should (equal (fleet-result-item before id) (fleet-result-item after id))))
      ;; and the candidate is still offered on the next reading
      (should (string-match-p "Should Fleet implement it" (fsum-test--md))))))

(ert-deftest fsum-test-result-adjudicated-fingerprints-do-not-return ()
  (fsum-test-with-fixture
      (fsum-test--result-fixture
       :runs (list (cons "rt-ready"
                         (list (fsum-test--assistant "2026-09-22T09:01:00.000Z" "Noise: shall I keep going?")
                               (fsum-test--assistant "2026-09-22T09:02:00.000Z" "The real ask: please review the draft.")))))
    (let* ((read (fleet-result-read :root-id fsum-test--root-id))
           (candidates (fleet-result-candidates (fsum-test--scan) read)))
      (should (= 2 (length candidates)))
      (fleet-result-dismiss :root-id fsum-test--root-id :fingerprints (list (plist-get (nth 0 candidates) :fingerprint))
                            :note "informational")
      (fsum-test--declare "the real ask" :fingerprints (list (plist-get (nth 1 candidates) :fingerprint)))
      (let ((md (fsum-test--md)))
        (should (null (fleet-result-candidates (fsum-test--scan) (fleet-result-read :root-id fsum-test--root-id))))
        (should-not (string-match-p "may need acknowledgement" md))
        (should (string-match-p "the real ask" md))))))

;;;; The read path writes nothing

(ert-deftest fsum-test-result-read-path-writes-nothing ()
  (fsum-test-with-fixture
      (fsum-test--result-fixture
       :runs (list (cons "rt-ready" (list (fsum-test--assistant "2026-09-22T09:01:00.000Z" "Ready. Please review it.")))))
    (fsum-test--declare "an open result")
    (let ((before (fsum-test--tree-digest fsum-test--data-root)))
      ;; not even a refused write: the single writer is never entered
      (cl-letf (((symbol-function 'fleet-result-apply)
                 (lambda (&rest _) (error "the /fsum read path must never write the checkpoint"))))
        (let ((md (fsum-bearings :session-fleet-id fsum-test--root-id :runtime-id "rt-ready")))
          (should (string-match-p "an open result" md))
          (should (string-match-p "may need acknowledgement" md)))
        (fleet-read-bearings-json :session-fleet-id fsum-test--root-id))
      (should (equal before (fsum-test--tree-digest fsum-test--data-root)))
      (should-not (file-exists-p (fleet-result-lock-file (fleet-result-directory :root-id fsum-test--root-id)))))))

(ert-deftest fsum-test-result-frev-adjudication-shows-in-the-next-fsum ()
  "An adjudication applied through the /frev bridge is what the next /fsum reads."
  (let ((frev (expand-file-name "../frev/scripts/frev.el" fsum-test--root)))
    (skip-unless (file-readable-p frev))
    (load frev nil t)
    (fsum-test-with-fixture
        (fsum-test--result-fixture
         :runs (list (cons "rt-ready" (list (fsum-test--assistant "2026-09-22T09:01:00.000Z"
                                                                  "Two things are ready. Please review them.")))))
      (let* ((root (list :id fsum-test--root-id :name "workshop" :artifact-root fsum-test--artifact-root))
             (review (frev-result-review :root root))
             (fingerprint (plist-get (car (plist-get review :candidates)) :fingerprint)))
        (should (equal (plist-get review :status) "ok"))
        (should (= 1 (length (plist-get review :candidates))))
        (should (null (plist-get review :open)))
        ;; split one transcript line into two independently addressable items
        (frev-result-apply
         :root root :actor "frev-test"
         :ops (list (list :op "declare" :summary "first of the two" :why "unanswered" :expected "decide"
                          :origin "inferred" :presented t :fingerprints (list fingerprint))
                    (list :op "declare" :summary "second of the two" :why "unanswered" :expected "decide"
                          :origin "inferred" :presented t :fingerprints (list fingerprint))))
        (let ((md (fsum-test--md)))
          (should (string-match-p "first of the two" md))
          (should (string-match-p "second of the two" md))
          (should-not (string-match-p "may need acknowledgement" md)))
        ;; and the cursors only move when an adjudication commits them
        (should (null (plist-get (fleet-result-read :root-id fsum-test--root-id) :cursors)))
        (frev-result-apply :root root :actor "frev-test"
                           :ops (list (list :op "cursors" :cursors (plist-get review :cursors))))
        (should (= 1 (length (plist-get (fleet-result-read :root-id fsum-test--root-id) :cursors))))))))

(provide 'fsum-tests)
;;; fsum-tests.el ends here
