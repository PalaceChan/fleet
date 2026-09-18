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
  "Start TID and wait for the operation; return the op row.
The fixture operator writes a `report.md' in the task directory at start, so
tests can register it as a deliverable (registration requires the path to
exist)."
  (let ((r (fleet-core-start-task store tid)))
    (prog1 (fleet-test-wait-op store (plist-get r :operation-id))
      (let ((task (fleet-store-get store "tasks" tid)))
        (fleet-test-write (expand-file-name "report.md" (fleet-core-task-dir store task)) "# Report\nfixture\n")))))

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

(ert-deftest fleet-core-delivery-follows-the-repository-and-refuses-impossible-review ()
  "Live run 2026-09-17: a commander whose create call lost `delivery' got the
fixed default remote-review on a repository with no remote; teardown refused
the contract only after the work was done.  Judge it at creation instead."
  (fleet-test-with-fakes
    (let* ((local (fleet-git-test-repo "local-only"))
           (hosted (fleet-git-test-repo "hosted"))
           (bare (expand-file-name "hosted.git" fleet-development-root))
           (fid (fleet-core-test-fleet store "fl")))
      (fleet-git-test-git hosted "init" "-q" "--bare" bare)
      (fleet-git-test-git hosted "remote" "add" "origin" bare)
      ;; no remote: omitted delivery follows the repository
      (let ((task (fleet-core-create-task store fid :name "a" :kind "change" :brief fleet-test-brief :repo local)))
        (should (equal "local-ready" (plist-get task :delivery-mode)))
        (should (equal "default-no-remote" (plist-get task :delivery-source)))
        (let ((ev (fleet-store-query1 store "SELECT payload FROM events WHERE task_id = ? AND kind = 'task-created'" (plist-get task :id))))
          (should (equal "local-ready" (plist-get (fleet-store-unjson (plist-get ev :payload)) :delivery)))
          (should (equal "default-no-remote" (plist-get (fleet-store-unjson (plist-get ev :payload)) :delivery-source)))))
      ;; no remote: an explicit promise to push is refused now, not at teardown
      (fleet-test-should-fail 'delivery-needs-remote
                              (fleet-core-create-task store fid :name "b" :kind "change" :brief fleet-test-brief :repo local :delivery "remote-review"))
      (should (equal "integrated"
                     (plist-get (fleet-core-create-task store fid :name "c" :kind "change" :brief fleet-test-brief :repo local :delivery "integrated") :delivery-mode)))
      ;; with a remote: the review default and the explicit choice both stand
      (let ((task (fleet-core-create-task store fid :name "d" :kind "change" :brief fleet-test-brief :repo hosted)))
        (should (equal "remote-review" (plist-get task :delivery-mode)))
        (should (equal "default" (plist-get task :delivery-source))))
      (should (equal "explicit"
                     (plist-get (fleet-core-create-task store fid :name "e" :kind "change" :brief fleet-test-brief :repo hosted :delivery "remote-review") :delivery-source)))
      ;; studies carry no delivery contract at all
      (let ((study (fleet-core-create-task store fid :name "s" :kind "study" :brief fleet-test-brief :repo local)))
        (should-not (plist-get study :delivery-mode))
        (should-not (plist-get study :delivery-source))))))

(ert-deftest fleet-core-open-failed-operations-drop-superseded-failures ()
  "Live run 2026-09-17: a teardown refused on evidence, retried successfully
after a merge, kept showing in doctor after the fleet was destroyed.  History
keeps the row; attention does not."
  (fleet-test-with-fakes
    (let* ((fid (fleet-core-test-fleet store "fl"))
           (t1 (plist-get (fleet-core-test-study store fid "one") :id))
           (t2 (plist-get (fleet-core-test-study store fid "two") :id))
           (ids (lambda () (mapcar (lambda (o) (plist-get o :id)) (fleet-core-open-failed-operations store))))
           (fail (lambda (kind tid)
                   (let ((op (fleet-core-operation-begin store kind :fleet-id fid :task-id tid)))
                     (fleet-core-operation-finish store op :state "failed" :error "nope")
                     ;; created_at has millisecond resolution; keep later ops strictly later
                     (sleep-for 0.01)
                     op))))
      (let ((a (funcall fail "task-teardown" t1))
            (b (funcall fail "task-teardown" t2))
            (c (funcall fail "runtime-stop" t2)))
        (should (equal (sort (copy-sequence (list a b c)) #'string<) (sort (funcall ids) #'string<)))
        ;; a later teardown of t1 succeeds: its failure is history
        (let ((ok (fleet-core-operation-begin store "task-teardown" :fleet-id fid :task-id t1)))
          (fleet-core-operation-finish store ok :state "done"))
        (should (equal (sort (copy-sequence (list b c)) #'string<) (sort (funcall ids) #'string<)))
        ;; a later *different* kind on t2 does not settle its teardown failure
        (let ((ok (fleet-core-operation-begin store "brief-publish" :fleet-id fid :task-id t2)))
          (fleet-core-operation-finish store ok :state "done"))
        (should (member b (funcall ids)))
        ;; archiving t2 settles everything about it
        (fleet-store-transaction store
          (fleet-store-update store "tasks" t2 (fleet-store-touch (list :lifecycle "archived"))))
        (should-not (funcall ids))
        ;; a fleet-level failure with no task is settled by archiving the fleet
        (let ((d (fleet-core-operation-begin store "fleet-retire" :fleet-id fid)))
          (fleet-core-operation-finish store d :state "failed" :error "rename")
          (should (equal (list d) (funcall ids)))
          (fleet-store-transaction store
            (fleet-store-update store "fleets" fid (fleet-store-touch (list :lifecycle "archived"))))
          (should-not (funcall ids))
          ;; every failure is still in the journal
          (should (= 4 (fleet-store-scalar store "SELECT COUNT(*) FROM operations WHERE state = 'failed'"))))))))

(ert-deftest fleet-core-eca-overlay-disables-ask-user-for-operators-only ()
  "Operators and lieutenants lose ask_user (their question channels are
needs-decision and fleet_report); the commander keeps it."
  (let* ((parse (lambda (role) (fleet-store-unjson (fleet-core--role-config-overlay role))))
         (commander (funcall parse "commander"))
         (lieutenant (funcall parse "lieutenant"))
         (operator (funcall parse "operator")))
    (should (equal (append (plist-get commander :disabledTools) nil) '("eca__spawn_agent")))
    (should (equal (append (plist-get lieutenant :disabledTools) nil) '("eca__spawn_agent" "eca__ask_user")))
    (should (equal (append (plist-get operator :disabledTools) nil) '("eca__spawn_agent" "eca__ask_user")))
    ;; All roles still get the MCP bridge entry.
    (dolist (o (list commander lieutenant operator))
      (should (equal (plist-get (plist-get (plist-get o :mcpServers) :fleet) :command) fleet-python-executable)))))

(ert-deftest fleet-core-lieutenant-is-a-child-fleet-with-selector-and-effective-role ()
  "A lieutenant is created under a root with a charter, resolves as root/child,
cannot nest, needs a charter, and its commander runtime acts as a lieutenant."
  (fleet-test-with-fakes
    (let* ((root-id (fleet-core-test-fleet store "workshop"))
           (lt (fleet-core-create-fleet store "frontend" :parent-id root-id :charter "UI work"))
           (lt-id (plist-get lt :id)))
      (should (equal (plist-get lt :parent-id) root-id))
      (should (equal (plist-get lt :charter) "UI work"))
      (should (equal (fleet-core-fleet-selector store lt) "workshop/frontend"))
      (should (equal (plist-get (fleet-core-fleet store "workshop/frontend") :id) lt-id))
      (should (equal (plist-get (fleet-core-fleet store "workshop") :id) root-id))
      (fleet-test-should-fail 'no-such-fleet (fleet-core-fleet store "frontend"))
      (fleet-test-should-fail 'no-such-fleet (fleet-core-fleet store "workshop/backend"))
      ;; Same name under another root is fine; a sibling clash and nesting are not.
      (let ((other (fleet-core-test-fleet store "other")))
        (should (fleet-core-create-fleet store "frontend" :parent-id other :charter "UI elsewhere")))
      (fleet-test-should-fail 'fleet-exists (fleet-core-create-fleet store "frontend" :parent-id root-id :charter "again"))
      (fleet-test-should-fail 'nested-lieutenant (fleet-core-create-fleet store "deeper" :parent-id lt-id :charter "no"))
      (fleet-test-should-fail 'charter-required (fleet-core-create-fleet store "mute" :parent-id root-id))
      (should (equal (mapcar (lambda (f) (plist-get f :name)) (fleet-core-lieutenants store root-id)) '("frontend")))
      (should (equal (plist-get (fleet-core-root-fleet store lt) :id) root-id))
      ;; Effective role: the lieutenant's commander runtime is a lieutenant; the root's is a commander.
      (let ((rt-root (fleet-core--new-runtime store :role "commander" :fleet-id root-id))
            (rt-lt (fleet-core--new-runtime store :role "commander" :fleet-id lt-id)))
        (should (equal (fleet-core-effective-role store rt-root) "commander"))
        (should (equal (fleet-core-effective-role store rt-lt) "lieutenant"))
        (should (equal (fleet-core-runtime-display-name store rt-lt) "*eca:lieutenant:workshop/frontend*"))))))

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

(defconst fleet-core-test-policy-json
  "{\"default\": {\"model\": \"fake/model\"},
    \"ask_first\": [\"fake/pricey\"],
    \"fallback\": {\"fake/model\": \"fake/other\"},
    \"rules\": [
      {\"when\": \"ambiguous feature work\", \"use\": [{\"model\": \"fake/pricey\", \"variant\": \"high\"}, \"fake/other\"], \"why\": \"standing rule\"},
      {\"when\": \"simple chore\", \"use\": \"fake/other\"}]}")

(ert-deftest fleet-core-operator-model-follows-owner-policy-and-ask-first-gate ()
  "The commander routes under the owner's rules and states a reason; Fleet
supplies the default, validates against the catalog, records the choice, and
refuses ask-first models (or everything, under the wildcard) until the
commander asserts the user's approval, however they were chosen."
  (fleet-test-with-fakes
    (let* ((fid (fleet-core-test-fleet store "pol"))
           (fleet-operator-model nil) (fleet-operator-variant nil)
           (mk (lambda (name &rest more)
                 (apply #'fleet-core-create-task store fid :name name :kind "study" :brief fleet-test-brief more)))
           (created (lambda (task) (fleet-store-unjson (plist-get (fleet-store-query1 store "SELECT payload FROM events WHERE task_id = ? AND kind = 'task-created'" (plist-get task :id)) :payload)))))
      ;; No policy file: the ECA default as before, and the audit trail says so.
      (let ((task (funcall mk "plain" :model-reason "no policy, default")))
        (should-not (plist-get task :model))
        (should (equal (plist-get task :model-source) "eca-default"))
        (should (equal (plist-get (funcall created task) :model-source) "eca-default"))
        (should (equal (plist-get (funcall created task) :model-reason) "no policy, default")))
      (let ((fleet-operator-model "fake/other"))
        (should (equal (plist-get (funcall mk "cfg") :model-source) "config")))
      ;; A malformed policy refuses creation rather than silently using defaults.
      (fleet-test-write-config :models "{\"rules\": 3}")
      (fleet-test-should-fail 'invalid-model-policy (funcall mk "broken"))
      (should (string-match-p "could not be loaded" (fleet-core--models-section store '(:id "none"))))
      (fleet-test-write-config :models fleet-core-test-policy-json)
      ;; The commander applied rule 1: the model is ask-first, so creation is refused with the reason echoed.
      (let ((err (fleet-test-should-fail 'model-needs-approval
                   (funcall mk "ask" :model "fake/pricey" :variant "high" :model-reason "rule 1: ambiguous feature work"))))
        (should (equal (plist-get (fleet-error-evidence err) :model) "fake/pricey"))
        (should (equal (plist-get (fleet-error-evidence err) :variant) "high"))
        (should (equal (plist-get (fleet-error-evidence err) :source) "explicit"))
        (should (equal (plist-get (fleet-error-evidence err) :reason) "rule 1: ambiguous feature work")))
      (should-not (fleet-store-task-by-name store fid "ask"))
      (let ((task (funcall mk "ask" :model "fake/pricey" :variant "high" :model-reason "rule 1" :owner-approved t)))
        (should (equal (plist-get task :model) "fake/pricey"))
        (should (equal (plist-get task :variant) "high"))
        (should (equal (plist-get task :model-source) "explicit"))
        (should (eq t (plist-get (funcall created task) :owner-approved)))
        (should (equal (plist-get (funcall created task) :model-reason) "rule 1")))
      ;; No rule applies: omit model, get the policy default, no approval, no variant unless asked.
      (let ((task (funcall mk "easy" :model-reason "no rule applies")))
        (should (equal (plist-get task :model) "fake/model"))
        (should-not (plist-get task :variant))
        (should (equal (plist-get task :model-source) "policy-default")))
      (should (equal (plist-get (funcall mk "easy-low" :variant "low") :variant) "low"))
      ;; A non-ask-first rule model needs no approval.
      (should (equal (plist-get (funcall mk "chore" :model "fake/other" :model-reason "rule 2") :model) "fake/other"))
      ;; Catalog known: models the catalog lacks are refused even when approved; the default falls through when absent.
      (fleet-store-record-eca-catalog store :models '("fake/model" "fake/other") :default-model "fake/model")
      (fleet-test-should-fail 'unknown-model (funcall mk "gone" :model "fake/pricey" :owner-approved t))
      (fleet-store-record-eca-catalog store :models '("fake/other" "fake/pricey"))
      (let ((fleet-operator-model "fake/other"))
        (should (equal (plist-get (funcall mk "nodefault") :model-source) "config")))
      (fleet-store-record-eca-catalog store :models '("fake/model" "fake/other" "fake/pricey"))
      ;; Retask: "default" returns to the policy default; an explicit ask-first model needs approval too.
      (let* ((tid (plist-get (fleet-store-task-by-name store fid "chore") :id)))
        (should (equal (plist-get (fleet-core-retask store tid "" :model "default" :variant "default") :model) "fake/model"))
        (fleet-test-should-fail 'model-needs-approval (fleet-core-retask store tid "" :model "fake/pricey"))
        (should (equal (plist-get (fleet-core-retask store tid "" :model "fake/pricey" :owner-approved t) :model) "fake/pricey")))
      ;; The commander's boot message explains the policy it works under.
      (let ((boot (fleet-core--models-section store '(:id "none"))))
        (should (string-match-p "Operator default: `fake/model`" boot))
        (should (string-match-p "### Operator model policy" boot))
        (should (string-match-p "1\\. when ambiguous feature work → `fake/pricey` (variant `high`), then `fake/other` (why: standing rule)" boot))
        (should (string-match-p "2\\. when simple chore → `fake/other`" boot))
        (should (string-match-p "Ask first.*`fake/pricey`" boot))
        (should (string-match-p "fallback.*`fake/model` → `fake/other`" boot))
        (should-not (string-match-p "does not offer" boot)))
      (fleet-store-record-eca-catalog store :models '("fake/model" "fake/other"))
      (should (string-match-p "does not offer.*`fake/pricey`" (fleet-core--models-section store '(:id "none"))))
      ;; Wildcard: while the owner is shaping the rules, everything asks first — the default included.
      (fleet-test-write-config :models "{\"default\": \"fake/model\", \"ask_first\": [\"*\"]}")
      (fleet-test-should-fail 'model-needs-approval (funcall mk "wild" :model-reason "default"))
      (fleet-test-should-fail 'model-needs-approval (funcall mk "wild" :model "fake/other" :model-reason "user named it"))
      (should (equal (plist-get (funcall mk "wild" :model-reason "default, user agreed" :owner-approved t) :model) "fake/model"))
      (should (string-match-p "Ask first: \\*\\*every task\\*\\*" (fleet-core--models-section store '(:id "none"))))
      (delete-file (fleet-config-file))
      (should (string-match-p "No owner policy file" (fleet-core--models-section store '(:id "none")))))))

(ert-deftest fleet-core-commander-model-pin-is-changeable-and-governs-the-next-start ()
  "A fleet created without a model can be pinned later; the pin (else the
defcustom, else the ECA default) is what each commander start launches with."
  (fleet-test-with-fakes
    (let* ((fid (fleet-core-test-fleet store "pin"))
           (commander-rt (lambda () (fleet-store-get store "runtimes" (plist-get (fleet-store-get store "fleets" fid) :commander-runtime-id))))
           (start (lambda ()
                    (fleet-test-wait-op store (fleet-core-start-commander store fid))
                    (let (done)
                      (fleet-core-stop-commander store fid :callback (lambda (_) (setq done t)))
                      (fleet-test-wait-for (lambda () done) 10)))))
      (should-not (plist-get (fleet-store-get store "fleets" fid) :commander-model))
      ;; No pin, no defcustom: the runtime records the announced default.
      (let ((fleet-commander-model nil) (fleet-commander-variant nil))
        (should (equal (fleet-core-commander-model (fleet-store-get store "fleets" fid)) (cons nil nil)))
        (funcall start)
        (should (equal (plist-get (funcall commander-rt) :model) "fake/model")))
      ;; No pin, no defcustom: the policy `default' is for operators only, so
      ;; the commander still follows the ECA default; the policy's own
      ;; `commander' selection is what governs it.
      (let ((fleet-commander-model nil) (fleet-commander-variant nil))
        (fleet-test-write-config :models "{\"default\": {\"model\": \"fake/other\", \"variant\": \"low\"}}")
        (should (equal (fleet-core-commander-model (fleet-store-get store "fleets" fid)) (cons nil nil)))
        (fleet-test-write-config :models "{\"default\": \"fake/model\", \"commander\": {\"model\": \"fake/other\", \"variant\": \"low\"}, \"lieutenant\": \"fake/model\"}")
        (should (equal (fleet-core-commander-model (fleet-store-get store "fleets" fid)) (cons "fake/other" "low")))
        (funcall start)
        (should (equal (plist-get (funcall commander-rt) :model) "fake/other"))
        (should (equal (plist-get (funcall commander-rt) :variant) "low"))
        ;; a variant defcustom alone overrides only the variant
        (let ((fleet-commander-variant "high"))
          (should (equal (fleet-core-commander-model (fleet-store-get store "fleets" fid)) (cons "fake/other" "high"))))
        ;; a fleet with a parent reads the lieutenant selection instead
        (should (equal (fleet-core-commander-model (list :parent-id "some-root")) (cons "fake/model" nil)))
        (delete-file (fleet-config-file)))
      ;; No pin: the defcustoms now apply to an existing fleet too (previously only at creation).
      (let ((fleet-commander-model "fake/other") (fleet-commander-variant "low"))
        (funcall start)
        (should (equal (plist-get (funcall commander-rt) :model) "fake/other"))
        (should (equal (plist-get (funcall commander-rt) :variant) "low")))
      ;; Pin: validated against the known catalog, persisted, evented, and it beats the defcustom.
      (fleet-store-record-eca-catalog store :models '("fake/model" "fake/other") :default-model "fake/model")
      (let ((err (fleet-test-should-fail 'unknown-model (fleet-core-set-commander-model store fid :model "the Other one"))))
        (should (equal (plist-get (fleet-error-evidence err) :suggestions) '("fake/other"))))
      (should-not (plist-get (fleet-store-get store "fleets" fid) :commander-model))
      (let ((fleet (fleet-core-set-commander-model store fid :model "fake/model" :variant "high")))
        (should (equal (plist-get fleet :commander-model) "fake/model"))
        (should (equal (plist-get fleet :commander-variant) "high"))
        (let ((fleet-commander-model "fake/other") (fleet-commander-variant "low"))
          (should (equal (fleet-core-commander-model fleet) (cons "fake/model" "high")))
          (funcall start)
          (should (equal (plist-get (funcall commander-rt) :model) "fake/model"))
          (should (equal (plist-get (funcall commander-rt) :variant) "high"))))
      (let ((ev (fleet-store-unjson (fleet-store-scalar store "SELECT payload FROM events WHERE fleet_id = ? AND kind = 'commander-model-changed' ORDER BY seq DESC LIMIT 1" fid))))
        (should (equal (plist-get ev :model) "fake/model"))
        (should-not (plist-get ev :previous-model)))
      ;; Clearing the pin falls back again; the live commander is never touched by a pin change.
      (fleet-core-set-commander-model store fid :model nil :variant nil)
      (should-not (plist-get (fleet-store-get store "fleets" fid) :commander-model))
      (fleet-test-wait-op store (fleet-core-start-commander store fid))
      (fleet-core-set-commander-model store fid :model "fake/other")
      (should (equal (plist-get (funcall commander-rt) :model) "fake/model"))
      (should (equal (plist-get (funcall commander-rt) :lifecycle) "ready")))))

(ert-deftest fleet-core-configured-lieutenants-are-created-updated-and-never-removed ()
  "ensure-lieutenants creates configured lieutenants (pin from the entry, else
the root's), records charter/pin changes, reports lieutenants no longer in the
file without touching them, and refuses on a lieutenant."
  (fleet-test-with-fakes
    (let* ((fleet-commander-model nil) (fleet-commander-variant nil)
           (root (fleet-core-create-fleet store "workshop" :model "fake/model" :variant "high"))
           (rid (plist-get root :id))
           (by-name (lambda (n) (fleet-store-fleet-by-name store n rid))))
      ;; No config: nothing to do, nothing created.
      (should (equal (fleet-core-ensure-lieutenants store rid) '(:created nil :updated nil :unconfigured nil)))
      (fleet-test-write-config
       :fleets "{\"workshop\": {\"lieutenants\": {\"frontend\": {\"charter\": \"UI\"}, \"backend\": {\"charter\": \"data\", \"model\": \"fake/other\"}}}}")
      (let ((r (fleet-core-ensure-lieutenants store rid)))
        (should (equal (mapcar (lambda (f) (plist-get f :name)) (plist-get r :created)) '("frontend" "backend")))
        (should-not (plist-get r :updated)))
      (should (equal (plist-get (funcall by-name "frontend") :commander-model) "fake/model"))
      (should (equal (plist-get (funcall by-name "frontend") :commander-variant) "high"))
      (should (equal (plist-get (funcall by-name "backend") :commander-model) "fake/other"))
      (should-not (plist-get (funcall by-name "backend") :commander-variant))
      (should (file-exists-p (expand-file-name "commander/context.md" (plist-get (funcall by-name "frontend") :artifact-root))))
      ;; Idempotent.
      (should (equal (fleet-core-ensure-lieutenants store rid) '(:created nil :updated nil :unconfigured nil)))
      ;; Charter edit is recorded; a dropped entry is reported, not removed.
      (fleet-test-write-config :fleets "{\"workshop\": {\"lieutenants\": {\"frontend\": {\"charter\": \"UI and a11y\"}}}}")
      (let ((r (fleet-core-ensure-lieutenants store rid)))
        (should (equal (mapcar (lambda (f) (plist-get f :name)) (plist-get r :updated)) '("frontend")))
        (should (equal (mapcar (lambda (f) (plist-get f :name)) (plist-get r :unconfigured)) '("backend"))))
      (should (equal (plist-get (funcall by-name "frontend") :charter) "UI and a11y"))
      (should (funcall by-name "backend"))
      (should (= 2 (length (fleet-core-lieutenants store rid))))
      ;; The owner's `lieutenant' selection beats the root's pin for entries
      ;; without a model of their own; an entry model still wins.
      (fleet-test-write-config :models "{\"lieutenant\": {\"model\": \"fake/other\", \"variant\": \"low\"}}"
                               :fleets "{\"workshop\": {\"lieutenants\": {\"frontend\": {\"charter\": \"UI and a11y\"}, \"backend\": {\"charter\": \"data\", \"model\": \"fake/model\"}}}}")
      (let ((r (fleet-core-ensure-lieutenants store rid)))
        (should (equal (sort (mapcar (lambda (f) (plist-get f :name)) (plist-get r :updated)) #'string<) '("backend" "frontend"))))
      (should (equal (plist-get (funcall by-name "frontend") :commander-model) "fake/other"))
      (should (equal (plist-get (funcall by-name "frontend") :commander-variant) "low"))
      (should (equal (plist-get (funcall by-name "backend") :commander-model) "fake/model"))
      ;; An unpinned root and no lieutenant selection leave the lieutenant
      ;; unpinned too: its start follows the ECA default rather than freezing
      ;; today's default into a pin.
      (let ((bare (fleet-core-create-fleet store "bare")))
        (fleet-test-write-config :fleets "{\"bare\": {\"lieutenants\": {\"a\": {\"charter\": \"x\"}}}}")
        (fleet-core-ensure-lieutenants store (plist-get bare :id))
        (let ((a (fleet-store-fleet-by-name store "a" (plist-get bare :id))))
          (should-not (plist-get a :commander-model))
          (should (equal (fleet-core-commander-model a) (cons nil nil)))))
      ;; Malformed section: refused with the reason, nothing changed.
      (fleet-test-write-config :fleets "{\"workshop\": {\"lieutenants\": {\"x\": {}}}}")
      (fleet-test-should-fail 'invalid-fleet-config (fleet-core-ensure-lieutenants store rid))
      (should (= 2 (length (fleet-core-lieutenants store rid))))
      (fleet-test-should-fail 'nested-lieutenant (fleet-core-ensure-lieutenants store (plist-get (funcall by-name "frontend") :id))))))

(ert-deftest fleet-core-lieutenant-boot-carries-charter-and-root-boot-lists-lieutenants ()
  "A lieutenant boots as a commander of its own fleet plus the lieutenant
overlay and charter; the root's boot lists its lieutenants and charters."
  (fleet-test-with-fakes
    (let* ((rid (fleet-core-test-fleet store "workshop"))
           (lt (fleet-core-create-fleet store "frontend" :parent-id rid :charter "UI and browser-facing work"))
           (lid (plist-get lt :id)))
      (fleet-test-wait-op store (fleet-core-start-commander store lid))
      (let* ((lt (fleet-store-get store "fleets" lid))
             (rt (fleet-store-get store "runtimes" (plist-get lt :commander-runtime-id)))
             (boot (plist-get (car (last fleet-test-fake-submissions)) :text)))
        (should (equal (plist-get rt :lifecycle) "ready"))
        (should (equal (plist-get rt :role) "commander"))
        (should (equal (fleet-core-effective-role store rt) "lieutenant"))
        (should (equal (fleet-eca-conn-display-name (fleet-eca-conn (plist-get rt :id))) "*eca:lieutenant:workshop/frontend*"))
        (should (string-match-p "# You are a lieutenant" boot))
        (should (string-match-p "## Your charter\nUI and browser-facing work" boot))
        (should (string-match-p (format "lieutenant `frontend` of fleet `workshop` (id `%s`)" rid) boot))
        (should (string-match-p "Fleet: `workshop/frontend`" boot))
        ;; The doctrine's Lieutenants section is shared; the listing of lieutenants is the root's alone.
        (should-not (string-match-p "(fleet id `" boot)))
      (fleet-test-wait-op store (fleet-core-start-commander store rid))
      (let ((boot (plist-get (car fleet-test-fake-submissions) :text)))
        (should (string-match-p "## Lieutenants" boot))
        (should (string-match-p (format "- `frontend` (fleet id `%s`): UI and browser-facing work\n  runtime ready · 0 open request(s)" lid) boot))
        (should (string-match-p "fleet_delegate" boot))
        (should-not (string-match-p "# You are a lieutenant" boot))))))

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
          ;; file gone since registration: verification refused, naming where it looked
          (delete-file report)
          (let ((err (fleet-test-should-fail 'artifact-missing (fleet-core-artifact-verify store :artifact-id (plist-get art :id) :actor "c" :accepted t))))
            (should (member report (plist-get (fleet-error-evidence err) :looked-at))))
          (should-not (fleet-core-task-verified-p store (fleet-store-get store "tasks" tid)))
          (fleet-test-write report "# Report\nfindings\n")
          (should (plist-get (fleet-core-artifact-verify store :artifact-id (plist-get art :id) :actor "c" :accepted t :criteria "complete") :verified))
          (should (fleet-core-task-verified-p store (fleet-store-get store "tasks" tid)))
          ;; changed contents invalidate
          (fleet-test-write report "# Report\nchanged after verification\n")
          (should-not (fleet-core-task-verified-p store (fleet-store-get store "tasks" tid))))))))

(ert-deftest fleet-core-directory-artifacts-verify-by-tree-digest ()
  "openclaw 2026-09-10: a rollback bundle registered as a directory could not be
verified (raw read error), so a fully successful task could not be torn down."
  (fleet-test-with-fakes
    (let* ((fid (fleet-core-test-fleet store))
           (task (fleet-core-test-study store fid)) (tid (plist-get task :id)))
      (fleet-core-test-start store tid)
      (let* ((rt (fleet-core-test-runtime store tid))
             (dir (fleet-core-task-dir store task))
             (bundle (expand-file-name "workspace/rollback-pre-deploy" dir)))
        (fleet-test-write (expand-file-name "report.md" dir) "# Report\n")
        (fleet-test-write (expand-file-name "live/a.py" bundle) "print(1)\n")
        (fleet-test-write (expand-file-name "target-sha256.before" bundle) "abc a.py\n")
        ;; An empty directory or a special file is refused at registration, with a code.
        (make-directory (expand-file-name "workspace/empty" dir) t)
        (fleet-test-should-fail 'artifact-empty (fleet-core-artifact-register store :runtime-id rt :kind "bundle" :rel-path "workspace/empty"))
        (when (zerop (call-process "mkfifo" nil nil nil (expand-file-name "workspace/pipe" dir)))
          (fleet-test-should-fail 'artifact-unreadable (fleet-core-artifact-register store :runtime-id rt :kind "bundle" :rel-path "workspace/pipe")))
        ;; A directory registers, verifies and gates teardown like a file.
        (let ((r (fleet-core-artifact-register store :runtime-id rt :kind "rollback-bundle" :rel-path "workspace/rollback-pre-deploy")))
          (fleet-core-task-status store :runtime-id rt :phase "done" :artifacts '((:kind "report" :rel-path "report.md")))
          (let ((report (fleet-store-query1 store "SELECT id FROM artifacts WHERE task_id = ? AND kind = 'report'" tid)))
            (should (plist-get (fleet-core-artifact-verify store :artifact-id (plist-get report :id) :actor "c" :accepted t) :verified))
            (should-not (fleet-core-task-verified-p store (fleet-store-get store "tasks" tid)))
            (let ((v (fleet-core-artifact-verify store :artifact-id (plist-get r :artifact-id) :actor "c" :accepted t)))
              (should (plist-get v :verified))
              (should (string= (plist-get v :hash) (fleet-paths-sha256-tree bundle))))
            (should (fleet-core-task-verified-p store (fleet-store-get store "tasks" tid)))
            ;; Any change under the tree after verification invalidates it.
            (fleet-test-write (expand-file-name "live/a.py" bundle) "print(2)\n")
            (should-not (fleet-core-task-verified-p store (fleet-store-get store "tasks" tid)))
            (fleet-test-write (expand-file-name "live/a.py" bundle) "print(1)\n")
            (should (fleet-core-task-verified-p store (fleet-store-get store "tasks" tid)))
            (fleet-test-write (expand-file-name "extra" bundle) "")
            (should-not (fleet-core-task-verified-p store (fleet-store-get store "tasks" tid)))
            ;; A tree emptied after verification is "changed", not an error.
            (delete-directory bundle t)
            (make-directory bundle)
            (should-not (fleet-core-task-verified-p store (fleet-store-get store "tasks" tid)))))))))

(ert-deftest fleet-core-artifact-paths-resolve-against-task-dir-and-workspace ()
  "openclaw 2026-09-10: an ops operator wrote seven deliverables under
workspace/ and registered them as bare names; verification looked at the task
root and refused `artifact-missing' for all of them, so a successful deploy
could not be torn down.  rel_path is relative to the task directory and the
`workspace/' prefix is the workspace; registration resolves, requires
existence and stores the canonical form; verification follows the same rule."
  (fleet-test-with-fakes
    (let* ((fid (fleet-core-test-fleet store))
           (task (fleet-core-test-study store fid)) (tid (plist-get task :id)))
      (fleet-core-test-start store tid)
      (let* ((task (fleet-store-get store "tasks" tid)) (rt (fleet-core-test-runtime store tid))
             (dir (fleet-core-task-dir store task)) (ws (plist-get task :workspace-path))
             (rel-of (lambda (aid) (plist-get (fleet-store-get store "artifacts" aid) :rel-path))))
        (should (equal ws (expand-file-name "workspace" dir)))
        (fleet-test-write (expand-file-name "validation.log" ws) "ok\n")
        (fleet-test-write (expand-file-name "rollback-pre-deploy/live-SKILL.md" ws) "old\n")
        ;; bare name found only in the workspace => stored canonically
        (let ((r (fleet-core-artifact-register store :runtime-id rt :kind "log" :rel-path "validation.log")))
          (should (equal "workspace/validation.log" (plist-get r :rel-path)))
          (should (equal "workspace/validation.log" (funcall rel-of (plist-get r :artifact-id))))
          ;; registering it again under either spelling is the same row
          (should (equal (plist-get r :artifact-id)
                         (plist-get (fleet-core-artifact-register store :runtime-id rt :kind "log" :rel-path "workspace/validation.log") :artifact-id)))
          (should (equal (plist-get r :artifact-id)
                         (plist-get (fleet-core-artifact-register store :runtime-id rt :kind "log" :rel-path "validation.log") :artifact-id))))
        ;; nested bare path, same rule; the task-dir report keeps its bare name
        (should (equal "workspace/rollback-pre-deploy/live-SKILL.md"
                       (plist-get (fleet-core-artifact-register store :runtime-id rt :kind "rollback" :rel-path "rollback-pre-deploy/live-SKILL.md") :rel-path)))
        (should (equal "report.md" (plist-get (fleet-core-artifact-register store :runtime-id rt :kind "report" :rel-path "report.md") :rel-path)))
        ;; a path that exists nowhere is refused at registration, naming both places
        (let ((err (fleet-test-should-fail 'artifact-missing (fleet-core-artifact-register store :runtime-id rt :kind "log" :rel-path "missing.log"))))
          (should (equal (list (expand-file-name "missing.log" dir) (expand-file-name "missing.log" ws))
                         (plist-get (fleet-error-evidence err) :looked-at))))
        (fleet-test-should-fail 'artifact-missing (fleet-core-task-status store :runtime-id rt :phase "working" :artifacts '((:kind "log" :rel-path "nope.log"))))
        (fleet-test-should-fail 'invalid-path (fleet-core-artifact-register store :runtime-id rt :kind "log" :rel-path "../escape"))
        ;; everything registered verifies, and gates the task like before
        (fleet-core-task-status store :runtime-id rt :phase "done")
        (dolist (a (fleet-store-query store "SELECT id FROM artifacts WHERE task_id = ?" tid))
          (should (plist-get (fleet-core-artifact-verify store :artifact-id (plist-get a :id) :actor "c" :accepted t) :verified)))
        (should (fleet-core-task-verified-p store (fleet-store-get store "tasks" tid)))
        ;; a row registered by the previous code with a bare name resolves through the same fallback
        (fleet-test-write (expand-file-name "legacy.txt" ws) "legacy\n")
        (fleet-store-transaction store
          (fleet-store-insert store "artifacts" (list :id "legacy-art" :task-id tid :kind "file" :rel-path "legacy.txt"
                                                      :created-at (fleet-paths-now) :updated-at (fleet-paths-now))))
        (should (plist-get (fleet-core-artifact-verify store :artifact-id "legacy-art" :actor "c" :accepted t) :verified))
        (should (fleet-core-task-verified-p store (fleet-store-get store "tasks" tid)))))))

(ert-deftest fleet-core-change-task-artifacts-reach-the-worktree ()
  "A change task's workspace is a worktree outside the task directory, so no
bare rel_path could ever name a file in it.  `workspace/<path>' does."
  (fleet-test-with-fakes
    (let* ((repo (fleet-git-test-repo "proj3"))
           (fid (fleet-core-test-fleet store "fl"))
           (task (fleet-core-create-task store fid :name "feat" :kind "change" :brief fleet-test-brief :repo repo :delivery "local-ready"))
           (tid (plist-get task :id)))
      (fleet-core-test-start store tid)
      (let* ((task (fleet-store-get store "tasks" tid)) (ws (plist-get task :workspace-path))
             (rt (fleet-core-test-runtime store tid)))
        (should-not (string-prefix-p (fleet-core-task-dir store task) ws))
        (fleet-git-test-git ws "config" "user.email" "t@e") (fleet-git-test-git ws "config" "user.name" "T")
        (fleet-git-test-commit ws "skills/x/SKILL.md" "# x\n" "add skill")
        (let ((r (fleet-core-artifact-register store :runtime-id rt :kind "skill" :rel-path "workspace/skills/x/SKILL.md")))
          (should (equal "workspace/skills/x/SKILL.md" (plist-get r :rel-path)))
          (should (equal (expand-file-name "skills/x/SKILL.md" ws) (fleet-core-artifact-file store task "workspace/skills/x/SKILL.md")))
          ;; a bare worktree path is found too and canonicalized
          (should (equal (plist-get r :artifact-id)
                         (plist-get (fleet-core-artifact-register store :runtime-id rt :kind "skill" :rel-path "skills/x/SKILL.md") :artifact-id)))
          (should (plist-get (fleet-core-artifact-verify store :artifact-id (plist-get r :artifact-id) :actor "c" :accepted t) :verified)))))))

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

(ert-deftest fleet-core-park-and-resume-cover-lieutenants-and-retire-refuses-them ()
  "Parking a root parks its lieutenants (operators stop, supervisors stay);
resume reactivates both; a lieutenant cannot be parked or resumed alone;
a root with lieutenants or open requests cannot be retired."
  (fleet-test-with-fakes
    (let* ((rid (fleet-core-test-fleet store "workshop"))
           (lid (plist-get (fleet-core-create-fleet store "frontend" :parent-id rid :charter "UI") :id))
           (root-task (plist-get (fleet-core-test-study store rid "audit") :id))
           (lt-task (plist-get (fleet-core-test-study store lid "nav") :id)))
      (fleet-test-wait-op store (fleet-core-start-commander store rid))
      (fleet-test-wait-op store (fleet-core-start-commander store lid))
      (fleet-core-test-start store root-task)
      (fleet-core-test-start store lt-task)
      (should (= 2 (fleet-store-scalar store "SELECT COUNT(*) FROM runtimes WHERE role = 'operator' AND lifecycle = 'ready'")))
      (let (result)
        (fleet-core-park-fleet store rid :callback (lambda (op) (setq result op)))
        (should (fleet-test-wait-for (lambda () result) 10))
        (should (equal (plist-get result :state) "done"))
        (should (equal (plist-get result :fleet-id) rid))
        (should (= 1 (length (plist-get result :lieutenants))))
        (should (equal (plist-get (car (plist-get result :lieutenants)) :fleet-id) lid)))
      (should (equal (plist-get (fleet-store-get store "fleets" rid) :lifecycle) "parked"))
      (should (equal (plist-get (fleet-store-get store "fleets" lid) :lifecycle) "parked"))
      (should (equal (plist-get (fleet-store-get store "tasks" lt-task) :lifecycle) "suspended"))
      (should (= 0 (fleet-store-scalar store "SELECT COUNT(*) FROM runtimes WHERE role = 'operator' AND lifecycle <> 'stopped'")))
      ;; Both supervisors are retained.
      (should (= 2 (fleet-store-scalar store "SELECT COUNT(*) FROM runtimes WHERE role = 'commander' AND lifecycle = 'ready'")))
      ;; The lieutenant cannot start operators while its root is parked, and cannot resume alone.
      (fleet-test-should-fail 'fleet-not-active (fleet-core-start-task store lt-task))
      (fleet-test-should-fail 'fleet-not-root (fleet-core-resume-fleet store lid))
      (should (equal (fleet-core-resume-fleet store rid) (list rid lid)))
      (should (equal (plist-get (fleet-store-get store "fleets" lid) :lifecycle) "active"))
      (should (equal (plist-get (fleet-core-test-start store lt-task) :state) "done"))
      ;; Retirement never recurses: even a root without tasks keeps its lieutenants.
      (fleet-test-should-fail 'fleet-not-empty (fleet-core-retire-fleet store rid))
      (let* ((bare (fleet-core-test-fleet store "bare"))
             (bare-lt (plist-get (fleet-core-create-fleet store "side" :parent-id bare :charter "x") :id))
             (err (fleet-test-should-fail 'fleet-not-empty (fleet-core-retire-fleet store bare))))
        (should (string-match-p "lieutenants" (fleet-error-message err)))
        (should (equal (plist-get (fleet-error-evidence err) :lieutenants) '("side")))
        ;; The lieutenant itself retires like any empty fleet; then the root can.
        (should (equal (plist-get (fleet-test-wait-op store (fleet-core-retire-fleet store bare-lt)) :state) "done"))
        (should (equal (plist-get (fleet-test-wait-op store (fleet-core-retire-fleet store bare)) :state) "done"))))))

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
            ;; openclaw 2026-09-10: "(0/2/0)" alone sent the commander into the
            ;; worktree to find two __pycache__ files; the refusal names them.
            (should (string-match-p "?? scratch.txt" (plist-get op :error)))
            (let ((ev (fleet-store-unjson (plist-get op :evidence))))
              (should (plist-get ev :evidence))
              (should (equal ["?? scratch.txt"] (plist-get (plist-get (plist-get ev :evidence) :status) :paths)))))
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

(ert-deftest fleet-core-delivery-change-lets-teardown-judge-the-owner-s-contract ()
  "Live run 2026-09-17 (frev-skill): the owner switched from review-by-PR to
merging locally while the task was in flight.  Only the brief could follow,
the row kept remote-review, and teardown of the finished, locally merged task
refused until the commander pushed a branch nobody wanted.  The owner's word
now changes the contract itself, and a local mode is judged against the
local target."
  (fleet-test-with-fakes
    (let* ((repo (fleet-git-test-repo "hosted2"))
           (bare (expand-file-name "hosted2.git" fleet-development-root))
           (fid (fleet-core-test-fleet store "fl")))
      (fleet-git-test-git repo "init" "-q" "--bare" bare)
      (fleet-git-test-git repo "remote" "add" "origin" bare)
      (fleet-git-test-git repo "push" "-q" "-u" "origin" "main")
      (let* ((task (fleet-core-create-task store fid :name "feat" :kind "change" :brief fleet-test-brief :repo repo :delivery "remote-review"))
             (tid (plist-get task :id))
             (study (fleet-core-test-study store fid "s")))
        ;; the contract is the owner's: no approval, no change; studies have none
        (fleet-test-should-fail 'delivery-needs-approval (fleet-core-set-delivery store tid "integrated" :actor "c"))
        (fleet-test-should-fail 'invalid-task (fleet-core-set-delivery store (plist-get study :id) "integrated" :actor "c" :owner-approved t))
        (fleet-test-should-fail 'invalid-task (fleet-core-set-delivery store tid "by-carrier-pigeon" :actor "c" :owner-approved t))
        (fleet-core-test-start store tid)
        (let* ((task (fleet-store-get store "tasks" tid))
               (ws (plist-get task :workspace-path))
               (rt (fleet-core-test-runtime store tid)))
          (should (equal "origin" (plist-get task :remote)))
          (fleet-git-test-git ws "config" "user.email" "t@e") (fleet-git-test-git ws "config" "user.name" "T")
          (let ((tip (fleet-git-test-commit ws "work.txt" "w\n" "work")))
            ;; the owner merges locally; nothing is pushed
            (fleet-git-test-git repo "merge" "-q" "--ff-only" "fleet/fl/feat")
            (should (equal tip (fleet-git-test-git repo "rev-parse" "main")))
            (fleet-core-task-status store :runtime-id rt :phase "done" :artifacts '((:kind "branch" :external-ref "fleet/fl/feat")))
            (fleet-core-artifact-verify store :artifact-id (plist-get (fleet-store-query1 store "SELECT id FROM artifacts WHERE task_id = ?" tid) :id) :actor "c" :accepted t)
            ;; under remote-review the unpushed tip is refused, exactly as live
            (let ((op (fleet-test-wait-op store (plist-get (fleet-core-teardown-task store tid) :operation-id) 30)))
              (should (equal (plist-get op :state) "failed"))
              (should (string-match-p "delivery contract remote-review not satisfied" (plist-get op :error))))
            (should (equal (plist-get (fleet-store-get store "tasks" tid) :lifecycle) "active"))
            ;; the owner's word changes the contract on the done task; the remote is cleared
            (let ((row (fleet-core-set-delivery store tid "integrated" :actor "c" :owner-approved t :note "owner: merge locally, no PR")))
              (should (equal "integrated" (plist-get row :delivery-mode)))
              (should-not (plist-get row :remote))
              (should (equal "done" (plist-get row :phase))))
            (let ((ev (fleet-store-unjson (plist-get (fleet-store-query1 store "SELECT payload FROM events WHERE task_id = ? AND kind = 'task-delivery-changed'" tid) :payload))))
              (should (equal "remote-review" (plist-get ev :from)))
              (should (equal "integrated" (plist-get ev :to)))
              (should (eq t (plist-get ev :owner-approved))))
            ;; judged against local main, the merged tip is integrated by ancestry
            (let ((op (fleet-test-wait-op store (plist-get (fleet-core-teardown-task store tid) :operation-id) 30)))
              (should (equal (plist-get op :state) "done"))
              (should (eq t (plist-get (fleet-store-unjson (plist-get op :evidence)) :integrated-ancestry))))
            (should (equal (plist-get (fleet-store-get store "tasks" tid) :lifecycle) "archived"))
            ;; archived: the contract is history
            (fleet-test-should-fail 'task-closed (fleet-core-set-delivery store tid "local-ready" :actor "c" :owner-approved t))))
        ;; remote-review still needs a remote to promise
        (let* ((local (fleet-git-test-repo "local2"))
               (t2 (fleet-core-create-task store fid :name "loc" :kind "change" :brief fleet-test-brief :repo local)))
          (fleet-test-should-fail 'delivery-needs-remote (fleet-core-set-delivery store (plist-get t2 :id) "remote-review" :actor "c" :owner-approved t))
          (should (equal "local-ready" (plist-get (fleet-core-set-delivery store (plist-get t2 :id) "local-ready" :actor "c" :owner-approved t) :delivery-mode))))))))

(ert-deftest fleet-core-close-archives-what-teardown-never-admits ()
  "openclaw 2026-09-13: a failed task and unverifiable done tasks left a parked
fleet unretirable.  A human close archives them; it never stops or deletes."
  (fleet-test-with-fakes
    (let* ((fid (fleet-core-test-fleet store "stale"))
           (failed (plist-get (fleet-core-test-study store fid "failed1") :id))
           (done (plist-get (fleet-core-test-study store fid "done1") :id))
           (never (plist-get (fleet-core-test-study store fid "never-started") :id)))
      (fleet-core-test-start store failed)
      (fleet-core-test-start store done)
      (fleet-core-task-status store :runtime-id (fleet-core-test-runtime store failed) :phase "failed" :detail "gave up")
      ;; done, artifact registered but never verified => teardown refuses forever
      (fleet-core-task-status store :runtime-id (fleet-core-test-runtime store done) :phase "done" :artifacts '((:kind "report" :rel-path "report.md")))
      (fleet-test-should-fail 'deliverable-unverified (fleet-core-teardown-task store done))
      ;; a reason is mandatory; a live operator is refused
      (fleet-test-should-fail 'invalid-request (fleet-core-close-task store failed :reason " "))
      (fleet-test-should-fail 'runtime-not-stopped (fleet-core-close-task store failed :reason "abandon"))
      (should (equal (plist-get (fleet-store-get store "tasks" failed) :lifecycle) "active"))
      ;; parked => operators stopped, tasks suspended => closable
      (should (equal (plist-get (fleet-test-wait-op store (fleet-core-park-fleet store fid)) :state) "done"))
      (fleet-test-should-fail 'fleet-not-empty (fleet-core-retire-fleet store fid))
      (dolist (tid (list failed done never))
        (let* ((task (fleet-store-get store "tasks" tid))
               (r (fleet-core-close-task store tid :reason "project migrated; history stale" :expected-revision (plist-get task :entity-revision)))
               (op (fleet-store-get store "operations" (plist-get r :operation-id)))
               (after (fleet-store-get store "tasks" tid)))
          (should (equal (plist-get op :state) "done"))
          (should (equal (plist-get op :kind) "task-close"))
          (should (equal (plist-get after :lifecycle) "archived"))
          (should (string-match-p "closed: project migrated" (plist-get after :detail)))
          (should (= 1 (fleet-store-scalar store "SELECT COUNT(*) FROM events WHERE task_id = ? AND kind = 'task-closed'" tid)))
          (should (= 1 (fleet-store-scalar store "SELECT COUNT(*) FROM events WHERE task_id = ? AND kind = 'task-archived'" tid)))
          (should (= 0 (fleet-store-scalar store "SELECT COUNT(*) FROM resource_claims WHERE task_id = ?" tid)))
          ;; closing twice is refused; the archived row is untouched
          (fleet-test-should-fail 'task-closed (fleet-core-close-task store tid :reason "again"))))
      (let ((ev (fleet-store-unjson (plist-get (fleet-store-query1 store "SELECT payload FROM events WHERE task_id = ? AND kind = 'task-closed'" failed) :payload))))
        (should (equal (plist-get ev :phase) "failed"))
        (should (equal (plist-get ev :reason) "project migrated; history stale"))
        (should-not (plist-get ev :verified)))
      ;; files and runtimes retained; credentials revoked
      (should (file-exists-p (expand-file-name "report.md" (fleet-core-task-dir store (fleet-store-get store "tasks" done)))))
      (should (eql 1 (plist-get (fleet-store-get store "runtimes" (fleet-core-test-runtime store done)) :credential-revoked)))
      ;; and the fleet is now retirable
      (should (equal (plist-get (fleet-test-wait-op store (fleet-core-retire-fleet store fid)) :state) "done")))))

(ert-deftest fleet-core-close-change-task-requires-the-worktree-gone ()
  "Close never removes a worktree: present => refused (teardown's job); gone => archived, branch named."
  (fleet-test-with-fakes
    (let* ((repo (fleet-git-test-repo "proj3"))
           (fid (fleet-core-test-fleet store "fl3"))
           (tid (plist-get (fleet-core-create-task store fid :name "feat" :kind "change" :brief fleet-test-brief :repo repo :delivery "local-ready") :id)))
      (fleet-core-test-start store tid)
      (let* ((ws (plist-get (fleet-store-get store "tasks" tid) :workspace-path)))
        (fleet-core-task-status store :runtime-id (fleet-core-test-runtime store tid) :phase "failed" :detail "could not finish")
        (should (equal (plist-get (fleet-test-wait-op store (fleet-core-park-fleet store fid)) :state) "done"))
        (let ((err (fleet-test-should-fail 'worktree-present (fleet-core-close-task store tid :reason "abandon"))))
          (should (equal (plist-get (fleet-error-evidence err) :workspace) ws)))
        (should (file-directory-p ws))
        (should (equal (plist-get (fleet-store-get store "tasks" tid) :lifecycle) "suspended"))
        ;; the human removed it by hand (as happened on openclaw): now closable
        (fleet-git-test-git repo "worktree" "remove" "--force" ws)
        (should-not (file-directory-p ws))
        (fleet-core-close-task store tid :reason "abandoned; worktree removed by hand")
        (let ((ev (fleet-store-unjson (plist-get (fleet-store-query1 store "SELECT payload FROM events WHERE task_id = ? AND kind = 'task-closed'" tid) :payload))))
          (should (eq (plist-get ev :workspace-missing) t))
          (should (equal (plist-get ev :branch-retained) "fleet/fl3/feat")))
        (should (equal (plist-get (fleet-store-get store "tasks" tid) :lifecycle) "archived"))
        ;; the branch is still there: close deleted nothing
        (should (fleet-git-test-git repo "rev-parse" "--verify" "fleet/fl3/feat"))))))

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
      ;; keep the boot turn open: an operator mid-turn is never yanked away
      (setq fleet-test-fake-turn 'busy)
      (fleet-core-test-start store tid)
      (fleet-test-should-fail 'runtime-busy (fleet-core-retask store tid "new scope that is long enough to count"))
      (fleet-test-fake-finish (fleet-eca-conn (fleet-core-test-runtime store tid)))
      (fleet-core-task-status store :runtime-id (fleet-core-test-runtime store tid) :phase "done" :artifacts '((:kind "report" :rel-path "report.md")))
      (fleet-test-wait-op store (fleet-core-park-fleet store fid))
      (fleet-core-resume-fleet store fid)
      (fleet-test-should-fail 'invalid-task (fleet-core-retask store tid ""))
      ;; stopped runtime: immediate, returns the task row
      (let ((task (fleet-core-retask store tid "Second scope: extend the report with benchmarks." :note "follow-up")))
        (should (= 2 (plist-get task :brief-revision)))
        (should (equal (plist-get task :lifecycle) "ready"))
        (should (null (plist-get task :phase)))))))

(ert-deftest fleet-core-retask-failed-task-stops-idle-runtime-and-keeps-claims ()
  "openclaw incident (2026-09-10): a failed ops task with a live idle runtime
must be retaskable; the retask stops the runtime, the named resource claim
stays with the task, and a replacement task is refused with the holder."
  (fleet-test-with-fakes
    (let* ((fid (fleet-core-test-fleet store))
           (task (fleet-core-create-task store fid :name "prepare-clone" :kind "ops" :brief fleet-test-brief :resources '("openclaw-development-clone")))
           (tid (plist-get task :id)))
      (fleet-core-test-start store tid)
      (let ((rt (fleet-core-test-runtime store tid)))
        (fleet-test-wait-for (lambda () (null (fleet-eca-conn-turn (fleet-eca-conn rt)))) 5)
        (fleet-core-task-status store :runtime-id rt :phase "blocked" :detail "source is not a git root")
        (fleet-core-task-status store :runtime-id rt :phase "failed" :detail "ending at owner's request")
        ;; the runtime is alive by design after a terminal status
        (should (equal (plist-get (fleet-store-get store "runtimes" rt) :lifecycle) "ready"))
        ;; a replacement task for the same resource is a structured refusal naming the holder, not a SQL error
        (let ((err (fleet-test-should-fail 'resource-claimed
                     (fleet-core-create-task store fid :name "prepare-clone-2" :kind "ops" :brief fleet-test-brief :resources '("openclaw-development-clone")))))
          (should (equal (plist-get (fleet-error-evidence err) :task-id) tid))
          (should (equal (plist-get (fleet-error-evidence err) :task-name) "prepare-clone")))
        ;; retask stops the idle runtime as an operation, then commits ready
        (let* ((r (fleet-core-retask store tid "Corrected scope: clone from the real OpenClaw repository root." :note "fix source"))
               (op (fleet-test-wait-op store (plist-get r :operation-id))))
          (should (plist-get r :operation-id))
          (should (equal (plist-get op :kind) "task-retask"))
          (should (equal (plist-get op :state) "done")))
        (let ((task (fleet-store-get store "tasks" tid)) (rt-row (fleet-store-get store "runtimes" rt)))
          (should (equal (plist-get rt-row :lifecycle) "stopped"))
          (should (eql 1 (plist-get rt-row :credential-revoked)))
          (should (equal (plist-get task :lifecycle) "ready"))
          (should (null (plist-get task :phase)))
          (should (= 2 (plist-get task :brief-revision))))
        ;; the commander is woken to start the task again
        (should (cl-some (lambda (r) (equal (plist-get r :kind) "task-retasked")) (fleet-store-pending-receipts store fid)))
        ;; claims stayed with the task; a fresh start reuses them
        (should (= 1 (fleet-store-scalar store "SELECT COUNT(*) FROM resource_claims WHERE key = ? AND task_id = ?" "openclaw-development-clone" tid)))
        (should (equal (plist-get (fleet-core-test-start store tid) :state) "done"))
        (should-not (equal (fleet-core-test-runtime store tid) rt))
        (should (equal (plist-get (fleet-store-get store "tasks" tid) :phase) "working"))))))

(ert-deftest fleet-core-retask-changes-model-and-variant-for-next-operator ()
  "A struggling operator can be replaced in place by a stronger model/variant:
retask carries the selection, the next start launches on it, and the
workspace/brief/progress carry over.  Unknown models are refused before
anything is stopped; \"default\" returns to the configured default."
  (fleet-test-with-fakes
    (let* ((fid (fleet-core-test-fleet store))
           (tid (plist-get (fleet-core-test-study store fid) :id))
           (fleet-operator-model nil) (fleet-operator-variant nil))
      (fleet-store-record-eca-catalog store :models '("fake/model" "fake/other") :default-model "fake/model" :variants '("low" "high"))
      (fleet-core-test-start store tid)
      (let ((rt1 (fleet-core-test-runtime store tid)))
        (should (equal (plist-get (fleet-store-get store "runtimes" rt1) :model) "fake/model"))
        (fleet-test-wait-for (lambda () (null (fleet-eca-conn-turn (fleet-eca-conn rt1)))) 5)
        (fleet-core-task-status store :runtime-id rt1 :phase "failed" :detail "cannot make progress")
        ;; refused up front: nothing stopped, nothing written
        (fleet-test-should-fail 'unknown-model (fleet-core-retask store tid "" :model "nope/model"))
        (should (equal (plist-get (fleet-store-get store "runtimes" rt1) :lifecycle) "ready"))
        (should (= 0 (fleet-store-scalar store "SELECT COUNT(*) FROM operations WHERE task_id = ? AND kind = 'task-retask'" tid)))
        ;; blank text with only a selection change is fine on a task that is not done
        (let ((op (fleet-test-wait-op store (plist-get (fleet-core-retask store tid "" :model "fake/other" :variant "high" :note "stronger model") :operation-id))))
          (should (equal (plist-get op :state) "done")))
        (let ((task (fleet-store-get store "tasks" tid)))
          (should (equal (plist-get task :lifecycle) "ready"))
          (should (equal (plist-get task :model) "fake/other"))
          (should (equal (plist-get task :variant) "high"))
          (should (= 1 (plist-get task :brief-revision))))
        (let ((ev (fleet-store-unjson (plist-get (fleet-store-query1 store "SELECT payload FROM events WHERE task_id = ? AND kind = 'task-retasked' ORDER BY created_at DESC LIMIT 1" tid) :payload))))
          (should (equal (plist-get ev :model) "fake/other"))
          (should (equal (plist-get ev :variant) "high"))
          (should (eq (plist-get ev :selection-changed) t)))
        ;; the next operator runs on the new selection, same task
        (should (equal (plist-get (fleet-core-test-start store tid) :state) "done"))
        (let ((rt2 (fleet-store-get store "runtimes" (fleet-core-test-runtime store tid))))
          (should-not (equal (plist-get rt2 :id) rt1))
          (should (equal (plist-get rt2 :model) "fake/other"))
          (should (equal (plist-get rt2 :variant) "high")))
        ;; a retask without a selection keeps it; "default" clears it
        (let ((rt2 (fleet-core-test-runtime store tid)))
          (fleet-test-wait-for (lambda () (null (fleet-eca-conn-turn (fleet-eca-conn rt2)))) 5)
          (fleet-core-task-status store :runtime-id rt2 :phase "failed" :detail "still stuck")
          (fleet-test-wait-op store (plist-get (fleet-core-retask store tid "Narrower scope: only the parser module, please." :note "narrow") :operation-id))
          (should (equal (plist-get (fleet-store-get store "tasks" tid) :model) "fake/other"))
          (should (= 2 (plist-get (fleet-store-get store "tasks" tid) :brief-revision)))
          (let ((task (fleet-core-retask store tid "" :model "default" :variant "default")))
            (should (null (plist-get task :model)))
            (should (null (plist-get task :variant)))))))))

(ert-deftest fleet-core-retask-unproven-stop-leaves-task-unchanged ()
  (fleet-test-with-fakes
    (let* ((fid (fleet-core-test-fleet store))
           (tid (plist-get (fleet-core-test-study store fid) :id)))
      (fleet-core-test-start store tid)
      (let ((rt (fleet-core-test-runtime store tid)))
        (fleet-test-wait-for (lambda () (null (fleet-eca-conn-turn (fleet-eca-conn rt)))) 5)
        (fleet-core-task-status store :runtime-id rt :phase "failed" :detail "gave up")
        (setq fleet-test-fake-stop-verdict 'stop-unknown)
        (let ((op (fleet-test-wait-op store (plist-get (fleet-core-retask store tid "Retry with a different approach, please." :note "retry") :operation-id))))
          (should (equal (plist-get op :state) "failed"))
          (should (string-match-p "stop not proven" (plist-get op :error))))
        (let ((task (fleet-store-get store "tasks" tid)))
          (should (equal (plist-get task :lifecycle) "active"))
          (should (equal (plist-get task :phase) "failed"))
          (should (= 1 (plist-get task :brief-revision))))
        (should (equal (plist-get (fleet-store-get store "runtimes" rt) :lifecycle) "stop-unknown"))
        ;; an unproven stop is not silently retried: retask stays refused until reconciliation
        (fleet-test-should-fail 'runtime-not-stopped (fleet-core-retask store tid "Retry again with the same scope text here."))))))

(provide 'fleet-core-tests)
;;; fleet-core-tests.el ends here
