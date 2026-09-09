;;; fleet-core-tests.el --- Tests for fleet-core -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)
(require 'fleet-core)
(require 'fleet-test-fakes)
(require 'fleet-git-tests) ; git fixture helpers

(defun fleet-core-test-fleet (store &optional name)
  "Create a fleet and return its id."
  (plist-get (fleet-core-create-fleet store (or name "f")) :id))

(defun fleet-core-test-study (store fid &optional name)
  "Create a study task; return its row."
  (fleet-core-create-task store fid :name (or name "study1") :kind "study" :brief fleet-test-brief))

(defun fleet-core-test-start (store tid)
  "Start TID and wait for the operation; return the op row."
  (let ((r (fleet-core-start-task store tid)))
    (fleet-test-wait-op store (plist-get r :operation-id))))

(defun fleet-core-test-runtime (store tid)
  "Current runtime id of task TID."
  (plist-get (fleet-store-get store "tasks" tid) :current-runtime-id))

(ert-deftest fleet-core-create-fleet-and-task ()
  (fleet-test-with-fakes
    (let* ((fid (fleet-core-test-fleet store "compiler"))
           (fleet (fleet-store-get store "fleets" fid)))
      (should (equal (plist-get fleet :lifecycle) "active"))
      (should (file-exists-p (expand-file-name "about.md" (plist-get fleet :artifact-root))))
      (should (file-exists-p (expand-file-name "commander/context.md" (plist-get fleet :artifact-root))))
      (fleet-test-should-fail 'fleet-exists (fleet-core-create-fleet store "compiler"))
      (fleet-test-should-fail 'invalid-name (fleet-core-create-fleet store "bad name"))
      (let ((task (fleet-core-test-study store fid "parser")))
        (should (equal (plist-get task :lifecycle) "ready"))
        (should (= 1 (plist-get task :brief-revision)))
        (should (fleet-core-brief-runnable-p store task))
        (should (file-exists-p (expand-file-name "briefs/0001.md" (fleet-core-task-dir store task))))
        (should (file-exists-p (expand-file-name "brief.md" (fleet-core-task-dir store task))))
        (should (string-match-p "revision 1" (fleet-paths-read-file (fleet-core-brief-file store task))))
        (fleet-test-should-fail 'task-exists (fleet-core-test-study store fid "parser"))
        (fleet-test-should-fail 'invalid-task (fleet-core-create-task store fid :name "x" :kind "study" :brief "too short"))
        (fleet-test-should-fail 'invalid-task (fleet-core-create-task store fid :name "x" :kind "weird" :brief fleet-test-brief))
        (fleet-test-should-fail 'invalid-task (fleet-core-create-task store fid :name "x" :kind "change" :brief fleet-test-brief :repo "/nonexistent"))))))

(ert-deftest fleet-core-model-and-variant-flow-to-runtimes-and-unknown-models-are-refused ()
  (fleet-test-with-fakes
    ;; Nothing announced yet: any id passes through (ECA judges it later).
    (let* ((fid (plist-get (fleet-core-create-fleet store "m" :model "whatever/x" :variant "high") :id))
           (fleet (fleet-store-get store "fleets" fid)))
      (should (equal (plist-get fleet :commander-model) "whatever/x"))
      (should (equal (plist-get fleet :commander-variant) "high"))
      ;; Catalog known (the fake announces it at every start): refusal with suggestions.
      (fleet-store-record-eca-catalog store :models '("fake/model" "fake/other" "openai/gpt-5.6-terra") :default-model "fake/model")
      (let ((err (fleet-test-should-fail 'unknown-model
                   (fleet-core-create-task store fid :name "bad" :kind "study" :brief fleet-test-brief :model "gpt 5.6 terra"))))
        (should (equal (plist-get (fleet-error-evidence err) :suggestions) '("openai/gpt-5.6-terra"))))
      ;; Explicit task model/variant reach the runtime; a task without them records the effective default.
      (let* ((task (fleet-core-create-task store fid :name "picky" :kind "study" :brief fleet-test-brief :model "fake/other" :variant "low"))
             (plain (fleet-core-test-study store fid "plain")))
        (should (equal (plist-get task :variant) "low"))
        (fleet-core-test-start store (plist-get task :id))
        (fleet-core-test-start store (plist-get plain :id))
        (let ((rt (fleet-store-get store "runtimes" (fleet-core-test-runtime store (plist-get task :id))))
              (rt2 (fleet-store-get store "runtimes" (fleet-core-test-runtime store (plist-get plain :id)))))
          (should (equal (plist-get rt :model) "fake/other"))
          (should (equal (plist-get rt :variant) "low"))
          (should (equal (plist-get rt2 :model) "fake/model"))
          (should-not (plist-get rt2 :variant)))))))

(ert-deftest fleet-core-dependencies-reject-cycles-and-cross-fleet ()
  (fleet-test-with-fakes
    (let* ((f1 (fleet-core-test-fleet store "a")) (f2 (fleet-core-test-fleet store "b"))
           (t1 (fleet-core-test-study store f1 "one"))
           (t2 (fleet-core-create-task store f1 :name "two" :kind "study" :brief fleet-test-brief :dependencies (list (plist-get t1 :id))))
           (other (fleet-core-test-study store f2 "other")))
      (should t2)
      (fleet-test-should-fail 'invalid-dependency
        (fleet-core-create-task store f1 :name "three" :kind "study" :brief fleet-test-brief :dependencies (list (plist-get other :id))))
      (fleet-test-should-fail 'invalid-dependency
        (fleet-core-create-task store f1 :name "three" :kind "study" :brief fleet-test-brief :dependencies '("nope")))
      ;; start of dependent refused until prerequisite verified done
      (fleet-test-should-fail 'dependency-unsatisfied (fleet-core-start-task store (plist-get t2 :id))))))

(ert-deftest fleet-core-brief-publish-crash-boundaries ()
  (fleet-test-with-fakes
    (let* ((fid (fleet-core-test-fleet store))
           (task (fleet-core-test-study store fid))
           (tid (plist-get task :id))
           (dir (fleet-core-task-dir store task)))
      ;; Simulate: file written, DB commit lost.
      (let* ((body (fleet-core--brief-text task "new scope text that is long enough to count\n" 2 "retask"))
             (hash (fleet-paths-sha256-string body))
             (op (fleet-core-operation-begin store "brief-publish" :fleet-id fid :task-id tid
                                             :intent (list :revision 2 :rel-path "briefs/0002.md" :hash hash))))
        (fleet-paths-write-atomically (expand-file-name "briefs/0002.md" dir) body)
        (should (= 1 (plist-get (fleet-store-get store "tasks" tid) :brief-revision)))
        (should (eq 'committed (fleet-core-recover-brief-operation store (fleet-store-get store "operations" op))))
        (should (= 2 (plist-get (fleet-store-get store "tasks" tid) :brief-revision)))
        (should (fleet-core-brief-runnable-p store (fleet-store-get store "tasks" tid))))
      ;; Simulate: intent recorded, file never written.
      (let ((op (fleet-core-operation-begin store "brief-publish" :fleet-id fid :task-id tid
                                            :intent (list :revision 3 :rel-path "briefs/0003.md" :hash "deadbeef"))))
        (should (eq 'failed (fleet-core-recover-brief-operation store (fleet-store-get store "operations" op))))
        (should (= 2 (plist-get (fleet-store-get store "tasks" tid) :brief-revision))))
      ;; Tampered brief file => not runnable, start refused.
      (fleet-paths-write-atomically (expand-file-name "briefs/0002.md" dir) "tampered\n")
      (should-not (fleet-core-brief-runnable-p store (fleet-store-get store "tasks" tid)))
      (fleet-test-should-fail 'brief-not-runnable (fleet-core-start-task store tid)))))

(ert-deftest fleet-core-start-study-task-with-fakes ()
  (fleet-test-with-fakes
    (let* ((fid (fleet-core-test-fleet store))
           (task (fleet-core-test-study store fid))
           (tid (plist-get task :id))
           (op (fleet-core-test-start store tid)))
      (should (equal (plist-get op :state) "done"))
      (let ((task (fleet-store-get store "tasks" tid)))
        (should (equal (plist-get task :lifecycle) "active"))
        (should (equal (plist-get task :phase) "working"))
        (should (file-directory-p (plist-get task :workspace-path)))
        (let ((rt (fleet-store-get store "runtimes" (plist-get task :current-runtime-id))))
          (should (equal (plist-get rt :lifecycle) "ready"))
          (should (equal (plist-get rt :role) "operator"))
          (should (file-exists-p (fleet-paths-credential-file (plist-get rt :id))))
          (should (= #o600 (file-modes (fleet-paths-credential-file (plist-get rt :id)))))
          (should (file-exists-p (expand-file-name "launch.json" (fleet-core--run-dir store rt))))
          ;; launch.json records names only, never the credential token
          (let ((launch (fleet-paths-read-file (expand-file-name "launch.json" (fleet-core--run-dir store rt)))))
            (should (string-match-p "FLEET_CREDENTIAL_FILE" launch))
            (should-not (string-match-p "token" launch)))))
      ;; boot message durable and accepted
      (let ((m (fleet-store-query1 store "SELECT * FROM messages WHERE origin = 'boot' AND task_id = ?" tid)))
        (should (equal (plist-get m :state) "accepted"))
        (should (string-match-p "## Brief" (plist-get m :text)))
        (should (string-match-p "revision 1" (plist-get m :text))))
      ;; a second start is refused while the runtime lives
      (fleet-test-should-fail 'task-not-startable (fleet-core-start-task store tid)))))

(ert-deftest fleet-core-start-action-idempotent ()
  (fleet-test-with-fakes
    (let* ((fid (fleet-core-test-fleet store))
           (tid (plist-get (fleet-core-test-study store fid) :id))
           (actor (fleet-core-actor-commander fid))
           (r1 (fleet-core-start-task store tid :actor actor :action-id "start-1")))
      (fleet-test-wait-op store (plist-get r1 :operation-id))
      (let ((r2 (fleet-core-start-task store tid :actor actor :action-id "start-1")))
        (should (plist-get r2 :replayed))
        (should (equal (plist-get r2 :operation-id) (plist-get r1 :operation-id))))
      (fleet-test-should-fail 'action-payload-mismatch
        (fleet-core-start-task store tid :actor actor :action-id "start-1" :expected-revision 99))
      (should (= 1 (fleet-store-scalar store "SELECT COUNT(*) FROM runtimes WHERE task_id = ?" tid))))))

(ert-deftest fleet-core-start-failure-keeps-brief-and-suspends ()
  (fleet-test-with-fakes
    (let* ((fid (fleet-core-test-fleet store))
           (tid (plist-get (fleet-core-test-study store fid) :id)))
      (setq fleet-test-fake-turn 'reject)
      (let ((op (fleet-core-test-start store tid)))
        (should (equal (plist-get op :state) "failed"))
        (should (string-match-p "boot payload rejected" (plist-get op :error))))
      (let ((task (fleet-store-get store "tasks" tid)))
        (should (equal (plist-get task :lifecycle) "suspended"))
        (should (fleet-core-brief-runnable-p store task))
        (should (equal (plist-get (fleet-store-get store "runtimes" (plist-get task :current-runtime-id)) :lifecycle) "stopped")))
      ;; an actionable operation-failed event exists for the commander
      (should (cl-some (lambda (r) (equal (plist-get r :kind) "operation-failed")) (fleet-store-pending-receipts store fid)))
      ;; retry allowed after stop proof
      (setq fleet-test-fake-turn 'finish)
      (should (equal (plist-get (fleet-core-test-start store tid) :state) "done")))))

(ert-deftest fleet-core-status-acceptance-rules ()
  (fleet-test-with-fakes
    (let* ((fid (fleet-core-test-fleet store))
           (tid (plist-get (fleet-core-test-study store fid) :id)))
      (fleet-core-test-start store tid)
      (let ((rt (fleet-core-test-runtime store tid)))
        ;; unknown / stale runtime refused
        (fleet-test-should-fail 'stale-runtime (fleet-core-task-status store :runtime-id "nope" :phase "working"))
        ;; invalid phase
        (fleet-test-should-fail 'invalid-status (fleet-core-task-status store :runtime-id rt :phase "flying"))
        ;; needs-decision requires question; creates decision + actionable receipt
        (fleet-test-should-fail 'invalid-status (fleet-core-task-status store :runtime-id rt :phase "needs-decision"))
        (let ((r (fleet-core-task-status store :runtime-id rt :phase "needs-decision" :detail "retain offsets?"
                                         :decision '(:question "Retain source offsets?" :options ("yes" "no") :recommendation "yes"))))
          (should (plist-get r :decision-id))
          (should (equal "open" (plist-get (fleet-store-get store "decisions" (plist-get r :decision-id)) :state)))
          (should (cl-some (lambda (x) (equal (plist-get x :kind) "decision-requested")) (fleet-store-pending-receipts store fid)))
          ;; two distinct questions both survive
          (let ((r2 (fleet-core-task-status store :runtime-id rt :phase "needs-decision" :decision '(:question "Second question?"))))
            (should-not (equal (plist-get r2 :decision-id) (plist-get r :decision-id))))
          (should (= 2 (fleet-store-scalar store "SELECT COUNT(*) FROM decisions WHERE task_id = ? AND state = 'open'" tid)))
          ;; resolve requires exact id; human authority not needed for commander-authority decision
          (fleet-test-should-fail 'no-such-decision (fleet-core-decision-resolve store :decision-id "x" :answer "yes" :actor "c" :authority "commander"))
          (should (plist-get (fleet-core-decision-resolve store :decision-id (plist-get r :decision-id) :answer "yes" :actor "c" :authority "commander") :ok))
          (fleet-test-should-fail 'decision-closed (fleet-core-decision-resolve store :decision-id (plist-get r :decision-id) :answer "no" :actor "c" :authority "commander")))
        ;; done needs an artifact
        (fleet-test-should-fail 'invalid-status (fleet-core-task-status store :runtime-id rt :phase "done"))
        (should (plist-get (fleet-core-task-status store :runtime-id rt :phase "done" :detail "report written"
                                                   :artifacts '((:kind "report" :rel-path "report.md")))
                           :ok))
        ;; terminal phase cannot revert
        (fleet-test-should-fail 'terminal-phase (fleet-core-task-status store :runtime-id rt :phase "working"))
        ;; the runtime remains busy/idle independently of the done phase (facts stay separate)
        (should (equal "done" (plist-get (fleet-store-get store "tasks" tid) :phase)))
        (should (equal "active" (plist-get (fleet-store-get store "tasks" tid) :lifecycle)))))))

(ert-deftest fleet-core-paused-wait-expires-once ()
  (fleet-test-with-fakes
    (let* ((fid (fleet-core-test-fleet store))
           (tid (plist-get (fleet-core-test-study store fid) :id)))
      (fleet-core-test-start store tid)
      (let ((rt (fleet-core-test-runtime store tid)))
        (fleet-test-should-fail 'invalid-status (fleet-core-task-status store :runtime-id rt :phase "paused"))
        (fleet-core-task-status store :runtime-id rt :phase "paused" :detail "waiting for CI"
                                :wait (list :reason "CI run 42" :deadline "2000-01-01T00:00:00.000Z"))
        (should (= 1 (fleet-core-expire-waits store)))
        (should (= 0 (fleet-core-expire-waits store)))
        (should (= 1 (fleet-store-scalar store "SELECT COUNT(*) FROM events WHERE kind = 'wait-deadline-expired'")))
        ;; a healthy long wait in the future is untouched
        (fleet-core-task-status store :runtime-id rt :phase "paused" :wait (list :reason "later" :deadline "2999-01-01T00:00:00.000Z"))
        (should (= 0 (fleet-core-expire-waits store)))))))

(ert-deftest fleet-core-artifact-verification-bound-to-hash-and-revision ()
  (fleet-test-with-fakes
    (let* ((fid (fleet-core-test-fleet store))
           (task (fleet-core-test-study store fid)) (tid (plist-get task :id)))
      (fleet-core-test-start store tid)
      (let* ((rt (fleet-core-test-runtime store tid))
             (report (expand-file-name "report.md" (fleet-core-task-dir store task))))
        (fleet-core-task-status store :runtime-id rt :phase "done" :artifacts '((:kind "report" :rel-path "report.md")))
        (let ((art (fleet-store-query1 store "SELECT * FROM artifacts WHERE task_id = ?" tid)))
          ;; missing file: verification refused
          (fleet-test-should-fail 'artifact-missing (fleet-core-artifact-verify store :artifact-id (plist-get art :id) :actor "c" :accepted t))
          (should-not (fleet-core-task-verified-p store (fleet-store-get store "tasks" tid)))
          (fleet-test-write report "# Report\nfindings\n")
          (should (plist-get (fleet-core-artifact-verify store :artifact-id (plist-get art :id) :actor "c" :accepted t :criteria "complete") :verified))
          (should (fleet-core-task-verified-p store (fleet-store-get store "tasks" tid)))
          ;; changed contents invalidate
          (fleet-test-write report "# Report\nchanged after verification\n")
          (should-not (fleet-core-task-verified-p store (fleet-store-get store "tasks" tid))))))))

(ert-deftest fleet-core-artifact-registration-is-idempotent-per-location ()
  "Rehearsal 1 bug I: the operator registered report.md twice (register tool,
then fleet_status :artifacts) and the commander had to verify two rows."
  (fleet-test-with-fakes
    (let* ((fid (fleet-core-test-fleet store))
           (task (fleet-core-test-study store fid)) (tid (plist-get task :id)))
      (fleet-core-test-start store tid)
      (let* ((rt (fleet-core-test-runtime store tid))
             (r1 (fleet-core-artifact-register store :runtime-id rt :kind "report" :rel-path "report.md" :description "first"))
             (r2 (fleet-core-artifact-register store :runtime-id rt :kind "report" :rel-path "report.md" :description "second, fuller")))
        (should (equal (plist-get r1 :artifact-id) (plist-get r2 :artifact-id)))
        (fleet-core-task-status store :runtime-id rt :phase "done" :artifacts '((:kind "report" :rel-path "report.md")))
        (should (= 1 (fleet-store-scalar store "SELECT COUNT(*) FROM artifacts WHERE task_id = ?" tid)))
        (should (equal "second, fuller" (plist-get (fleet-store-query1 store "SELECT description FROM artifacts WHERE task_id = ?" tid) :description)))
        ;; a different location is a different artifact
        (fleet-core-artifact-register store :runtime-id rt :kind "report" :external-ref "file:///elsewhere/report.md")
        (should (= 2 (fleet-store-scalar store "SELECT COUNT(*) FROM artifacts WHERE task_id = ?" tid)))))))

(ert-deftest fleet-core-operator-roots-cover-task-dir-repo-and-worktree ()
  "Rehearsal 1 bug E: ECA forces approval for paths outside its workspace
roots, so the roots must cover the task dir (progress/report), the studied
repo, or the change worktree; commander roots must cover the fleet dir."
  (fleet-test-with-fakes
    (let* ((repo (fleet-git-test-repo "proj"))
           (fid (fleet-core-test-fleet store "fl"))
           (fleet (fleet-store-get store "fleets" fid))
           (study (fleet-core-create-task store fid :name "look" :kind "study" :brief fleet-test-brief :repo repo))
           (study-ws (expand-file-name "workspace" (fleet-core-task-dir store study))))
      ;; study: task dir (workspace nested inside is collapsed) + repo
      (should (equal (fleet-core-operator-roots store study study-ws)
                     (list (fleet-paths-canonical (fleet-core-task-dir store study)) (fleet-paths-canonical repo))))
      ;; no repo: task dir only
      (let ((plain (fleet-core-test-study store fid "plain")))
        (should (equal (fleet-core-operator-roots store plain (expand-file-name "workspace" (fleet-core-task-dir store plain)))
                       (list (fleet-paths-canonical (fleet-core-task-dir store plain))))))
      ;; change: task dir + worktree (the primary clone is NOT a root)
      (let* ((change (fleet-core-create-task store fid :name "feat" :kind "change" :brief fleet-test-brief :repo repo :delivery "local-ready"))
             (tid (plist-get change :id)))
        (should (equal (plist-get (fleet-core-test-start store tid) :state) "done"))
        (let* ((change (fleet-store-get store "tasks" tid))
               (roots (fleet-core-operator-roots store change (plist-get change :workspace-path))))
          (should (equal roots (list (fleet-paths-canonical (fleet-core-task-dir store change)) (plist-get change :workspace-path))))
          (should-not (member (fleet-paths-canonical repo) roots))
          ;; what the runtime was actually launched with
          (let ((ev (fleet-store-unjson (plist-get (fleet-store-get store "runtimes" (fleet-core-test-runtime store tid)) :launch-evidence))))
            (should (equal (append (plist-get ev :roots) nil) roots)))))
      ;; commander: the fleet directory
      (let ((op (fleet-core-start-commander store fid)))
        (fleet-test-wait-op store op)
        (let* ((cid (plist-get (fleet-store-get store "fleets" fid) :commander-runtime-id))
               (ev (fleet-store-unjson (plist-get (fleet-store-get store "runtimes" cid) :launch-evidence))))
          (should (equal (append (plist-get ev :roots) nil) (list (fleet-paths-canonical (plist-get fleet :artifact-root))))))))))

(ert-deftest fleet-core-change-task-creates-worktree-and-claims ()
  (fleet-test-with-fakes
    (let* ((repo (fleet-git-test-repo "proj"))
           (fid (fleet-core-test-fleet store "fl"))
           (task (fleet-core-create-task store fid :name "feature" :kind "change" :brief fleet-test-brief :repo repo :delivery "local-ready"))
           (tid (plist-get task :id))
           (op (fleet-core-test-start store tid)))
      (should (equal (plist-get op :state) "done"))
      (let ((task (fleet-store-get store "tasks" tid)))
        (should (equal (plist-get task :branch) "fleet/fl/feature"))
        (should (equal (plist-get task :base-ref) "main"))
        (should (equal (plist-get task :base-oid) (fleet-git-test-git repo "rev-parse" "main")))
        (should (fleet-paths-contains-p (fleet-paths-worktree-root) (plist-get task :workspace-path)))
        (should (file-directory-p (plist-get task :workspace-path)))
        (should (equal (plist-get task :workspace-ownership) "fleet"))
        (should (equal (plist-get task :repo-common-dir) (fleet-paths-canonical (expand-file-name ".git" repo))))
        ;; primary clone untouched
        (should (equal "main" (fleet-git-test-git repo "symbolic-ref" "--short" "HEAD")))
        (should (fleet-store-query1 store "SELECT * FROM resource_claims WHERE key = ? AND task_id = ?" (plist-get task :workspace-path) tid))
        ;; another task adopting the same worktree is refused by the claim
        (let ((t2 (fleet-core-create-task store fid :name "second" :kind "change" :brief fleet-test-brief :repo repo
                                          :workspace-mode 'adopt-worktree :adopt-path (plist-get task :workspace-path))))
          (let ((op2 (fleet-core-test-start store (plist-get t2 :id))))
            (should (equal (plist-get op2 :state) "failed"))
            (should (string-match-p "claimed" (plist-get op2 :error)))))))))

(ert-deftest fleet-core-park-stops-operators-and-holds-messages ()
  (fleet-test-with-fakes
    (let* ((fid (fleet-core-test-fleet store))
           (t1 (plist-get (fleet-core-test-study store fid "one") :id))
           (t2 (plist-get (fleet-core-test-study store fid "two") :id)))
      (fleet-core-test-start store t1)
      (fleet-core-test-start store t2)
      (fleet-core-task-status store :runtime-id (fleet-core-test-runtime store t2) :phase "done" :artifacts '((:kind "report" :rel-path "report.md")))
      ;; a queued operator message must be held, not lost
      (fleet-store-transaction store
        (fleet-store-insert store "messages" (list :id "m1" :sender "c" :fleet-id fid :task-id t1 :target-runtime-id (fleet-core-test-runtime store t1)
                                                   :origin "commander" :text "hi" :state "queued" :created-at (fleet-paths-now) :updated-at (fleet-paths-now))))
      (let ((op (fleet-core-park-fleet store fid)))
        (should (equal (plist-get (fleet-store-get store "fleets" fid) :lifecycle) "parking"))
        (fleet-test-should-fail 'fleet-not-active (fleet-core-test-study store fid "three"))
        (should (equal (plist-get (fleet-test-wait-op store op) :state) "done")))
      (should (equal (plist-get (fleet-store-get store "fleets" fid) :lifecycle) "parked"))
      (should (equal (plist-get (fleet-store-get store "tasks" t1) :lifecycle) "suspended"))
      (should (equal (plist-get (fleet-store-get store "tasks" t1) :detail) "paused by you; workspace retained"))
      ;; done phase preserved on suspension
      (should (equal (plist-get (fleet-store-get store "tasks" t2) :phase) "done"))
      (should (equal (plist-get (fleet-store-get store "messages" "m1") :state) "held"))
      (should (= 0 (fleet-store-scalar store "SELECT COUNT(*) FROM runtimes WHERE fleet_id = ? AND lifecycle NOT IN ('stopped')" fid)))
      ;; start refused while parked; resume re-queues held messages
      (fleet-test-should-fail 'fleet-not-active (fleet-core-start-task store t1))
      (fleet-core-resume-fleet store fid)
      (should (equal (plist-get (fleet-store-get store "messages" "m1") :state) "queued"))
      (should (equal (plist-get (fleet-core-test-start store t1) :state) "done")))))

(ert-deftest fleet-core-park-stays-parking-on-unknown-stop ()
  (fleet-test-with-fakes
    (let* ((fid (fleet-core-test-fleet store))
           (t1 (plist-get (fleet-core-test-study store fid) :id)))
      (fleet-core-test-start store t1)
      (setq fleet-test-fake-stop-verdict 'stop-unknown)
      (let ((op (fleet-test-wait-op store (fleet-core-park-fleet store fid))))
        (should (equal (plist-get op :state) "failed")))
      (should (equal (plist-get (fleet-store-get store "fleets" fid) :lifecycle) "parking"))
      (should (equal (plist-get (fleet-store-get store "runtimes" (fleet-core-test-runtime store t1)) :lifecycle) "stop-unknown"))
      ;; no replacement possible while unknown
      (fleet-test-should-fail 'fleet-not-active (fleet-core-start-task store t1)))))

(ert-deftest fleet-core-teardown-requires-verified-and-archives ()
  (fleet-test-with-fakes
    (let* ((fid (fleet-core-test-fleet store))
           (task (fleet-core-test-study store fid)) (tid (plist-get task :id)))
      (fleet-core-test-start store tid)
      (fleet-test-should-fail 'deliverable-unverified (fleet-core-teardown-task store tid))
      (let ((rt (fleet-core-test-runtime store tid)))
        (fleet-core-task-status store :runtime-id rt :phase "done" :artifacts '((:kind "report" :rel-path "report.md")))
        (fleet-test-should-fail 'deliverable-unverified (fleet-core-teardown-task store tid))
        (fleet-test-write (expand-file-name "report.md" (fleet-core-task-dir store task)) "# done\n")
        (fleet-core-artifact-verify store :artifact-id (plist-get (fleet-store-query1 store "SELECT id FROM artifacts WHERE task_id = ?" tid) :id) :actor "c" :accepted t)
        (let ((op (fleet-test-wait-op store (plist-get (fleet-core-teardown-task store tid) :operation-id))))
          (should (equal (plist-get op :state) "done")))
        (let ((task (fleet-store-get store "tasks" tid)))
          (should (equal (plist-get task :lifecycle) "archived"))
          ;; artifacts and files retained
          (should (file-exists-p (expand-file-name "report.md" (fleet-core-task-dir store task))))
          (should (equal (plist-get (fleet-store-get store "runtimes" rt) :lifecycle) "stopped"))
          (should (eql 1 (plist-get (fleet-store-get store "runtimes" rt) :credential-revoked))))
        ;; name reusable after archive
        (should (fleet-core-test-study store fid))))))

(ert-deftest fleet-core-teardown-change-task-refuses-dirty-then-retains-and-removes ()
  (fleet-test-with-fakes
    (let* ((repo (fleet-git-test-repo "proj2"))
           (fid (fleet-core-test-fleet store "fl"))
           (task (fleet-core-create-task store fid :name "feat" :kind "change" :brief fleet-test-brief :repo repo :delivery "local-ready"))
           (tid (plist-get task :id)))
      (fleet-core-test-start store tid)
      (let* ((task (fleet-store-get store "tasks" tid))
             (ws (plist-get task :workspace-path))
             (rt (fleet-core-test-runtime store tid)))
        (fleet-git-test-git ws "config" "user.email" "t@e") (fleet-git-test-git ws "config" "user.name" "T")
        (let ((tip (fleet-git-test-commit ws "work.txt" "w\n" "work")))
          (fleet-test-write (expand-file-name "scratch.txt" ws) "dirty\n")
          (fleet-core-task-status store :runtime-id rt :phase "done" :artifacts '((:kind "branch" :external-ref "fleet/fl/feat")))
          (fleet-core-artifact-verify store :artifact-id (plist-get (fleet-store-query1 store "SELECT id FROM artifacts WHERE task_id = ?" tid) :id) :actor "c" :accepted t)
          ;; dirty => refused with evidence, worktree retained, task back to active
          (let ((op (fleet-test-wait-op store (plist-get (fleet-core-teardown-task store tid) :operation-id) 30)))
            (should (equal (plist-get op :state) "failed"))
            (should (string-match-p "tracked/untracked/ignored" (plist-get op :error)))
            (should (plist-get (fleet-store-unjson (plist-get op :evidence)) :evidence)))
          (should (file-exists-p (expand-file-name "scratch.txt" ws)))
          (should (equal (plist-get (fleet-store-get store "tasks" tid) :lifecycle) "active"))
          ;; clean => retention ref created (local-ready), worktree removed natively, branch kept
          (delete-file (expand-file-name "scratch.txt" ws))
          (let ((op (fleet-test-wait-op store (plist-get (fleet-core-teardown-task store tid) :operation-id) 30)))
            (should (equal (plist-get op :state) "done"))
            (let ((ev (fleet-store-unjson (plist-get op :evidence))))
              (should (plist-get ev :worktree-removed))
              (should (equal (plist-get ev :branch-retained) "fleet/fl/feat"))))
          (should-not (file-exists-p ws))
          (should (equal tip (fleet-git-test-git repo "rev-parse" (format "refs/fleet/retained/%s" tid))))
          (should (equal tip (fleet-git-test-git repo "rev-parse" "fleet/fl/feat")))
          (should (equal (plist-get (fleet-store-get store "tasks" tid) :lifecycle) "archived"))
          (should (= 0 (fleet-store-scalar store "SELECT COUNT(*) FROM resource_claims WHERE task_id = ?" tid))))))))

(ert-deftest fleet-core-retire-refuses-nonempty-then-archives ()
  (fleet-test-with-fakes
    (let* ((fid (fleet-core-test-fleet store "gone"))
           (task (fleet-core-test-study store fid)) (tid (plist-get task :id))
           (root (plist-get (fleet-store-get store "fleets" fid) :artifact-root)))
      (fleet-test-should-fail 'fleet-not-empty (fleet-core-retire-fleet store fid))
      (fleet-core-test-start store tid)
      (fleet-core-task-status store :runtime-id (fleet-core-test-runtime store tid) :phase "done" :artifacts '((:kind "report" :rel-path "report.md")))
      (fleet-test-write (expand-file-name "report.md" (fleet-core-task-dir store task)) "r\n")
      (fleet-core-artifact-verify store :artifact-id (plist-get (fleet-store-query1 store "SELECT id FROM artifacts WHERE task_id = ?" tid) :id) :actor "c" :accepted t)
      (fleet-test-wait-op store (plist-get (fleet-core-teardown-task store tid) :operation-id))
      (let ((op (fleet-test-wait-op store (fleet-core-retire-fleet store fid))))
        (should (equal (plist-get op :state) "done")))
      (let ((fleet (fleet-store-get store "fleets" fid)))
        (should (equal (plist-get fleet :lifecycle) "archived"))
        (should-not (file-directory-p root))
        (should (file-directory-p (plist-get fleet :artifact-root)))
        (should (file-exists-p (expand-file-name (concat "tasks/" tid "/report.md") (plist-get fleet :artifact-root)))))
      ;; name reusable, history retained
      (should (fleet-core-create-fleet store "gone"))
      (should (> (fleet-store-scalar store "SELECT COUNT(*) FROM events WHERE fleet_id = ?" fid) 3)))))

(ert-deftest fleet-core-retire-resumes-after-rename-before-commit ()
  (fleet-test-with-fakes
    (let* ((fid (fleet-core-test-fleet store "half"))
           (fleet (fleet-store-get store "fleets" fid))
           (old (plist-get fleet :artifact-root)) (new (fleet-paths-fleet-archive-dir fid))
           (op (fleet-core-operation-begin store "fleet-retire" :fleet-id fid :intent (list :old-root old :new-root new))))
      (fleet-core-operation-step store op "renaming")
      (fleet-store-transaction store (fleet-store-update store "fleets" fid (list :lifecycle "retiring")))
      (make-directory (file-name-directory (directory-file-name new)) t)
      (rename-file old new)
      ;; crash here; new owner resumes from the journal
      (fleet-core-resume-operations store)
      (should (equal (plist-get (fleet-store-get store "fleets" fid) :lifecycle) "archived"))
      (should (equal (plist-get (fleet-store-get store "fleets" fid) :artifact-root) new))
      (should (equal (plist-get (fleet-store-get store "operations" op) :state) "done")))))

(ert-deftest fleet-core-reconcile-after-restart ()
  (fleet-test-with-fakes
    (let* ((fid (fleet-core-test-fleet store))
           (tid (plist-get (fleet-core-test-study store fid) :id)))
      (fleet-core-test-start store tid)
      ;; pretend Emacs restarted: connections gone, a start operation left running
      (clrhash fleet-eca--conns)
      (let ((stale-op (fleet-core-operation-begin store "task-start" :fleet-id fid :task-id tid)))
        (let (done)
          (fleet-core-reconcile-runtimes store (lambda (s) (setq done s)))
          (should (fleet-test-wait-for (lambda () done) 10))
          (should (= 1 (plist-get done :reconciled))))
        (should (equal (plist-get (fleet-store-get store "tasks" tid) :lifecycle) "suspended"))
        (should (equal (plist-get (fleet-store-get store "runtimes" (fleet-core-test-runtime store tid)) :lifecycle) "stopped"))
        (should (equal (plist-get (fleet-store-get store "operations" stale-op) :state) "failed"))
        ;; explicit resume is required; no automatic restart happened
        (should (= 1 (fleet-store-scalar store "SELECT COUNT(*) FROM runtimes WHERE task_id = ?" tid)))))))

(ert-deftest fleet-core-retask-requires-stopped-runtime-and-new-scope ()
  (fleet-test-with-fakes
    (let* ((fid (fleet-core-test-fleet store))
           (tid (plist-get (fleet-core-test-study store fid) :id)))
      (fleet-core-test-start store tid)
      (fleet-test-should-fail 'runtime-not-stopped (fleet-core-retask store tid "new scope that is long enough to count"))
      (fleet-core-task-status store :runtime-id (fleet-core-test-runtime store tid) :phase "done" :artifacts '((:kind "report" :rel-path "report.md")))
      (fleet-test-wait-op store (fleet-core-park-fleet store fid))
      (fleet-core-resume-fleet store fid)
      (fleet-test-should-fail 'invalid-task (fleet-core-retask store tid ""))
      (let ((task (fleet-core-retask store tid "Second scope: extend the report with benchmarks." :note "follow-up")))
        (should (= 2 (plist-get task :brief-revision)))
        (should (equal (plist-get task :lifecycle) "ready"))
        (should (null (plist-get task :phase)))))))

(provide 'fleet-core-tests)
;;; fleet-core-tests.el ends here
