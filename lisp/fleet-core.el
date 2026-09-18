;;; fleet-core.el --- Lifecycle operations and operation recovery -*- lexical-binding: t; -*-

;;; Commentary:

;; Domain operations over the store.  Every external effect (Git, systemd,
;; ECA) happens between two short transactions: one that admits and records
;; intent in `operations', one that records the result.  Each operation is a
;; small step machine keyed by its persisted `step', so it can be resumed by
;; inspecting reality after a crash (`fleet-core-resume-operation').
;;
;; The same functions serve the dashboard, M-x commands and the RPC tools,
;; so an agent cannot skip a safety check by choosing a tool over a key.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'fleet-paths)
(require 'fleet-policy)
(require 'fleet-store)
(require 'fleet-git)
(require 'fleet-runtime)
(require 'fleet-eca)

;;;; Owner fencing

(defvar fleet-core-owner nil
  "Plist (:epoch STRING :live-p FUNCTION) of the current supervisor, or nil.
Every mutation/launch admission checks it; the supervisor installs it.")

(defun fleet-core-owner-epoch ()
  "Current owner epoch, or signal `owner-unproven'."
  (unless (and fleet-core-owner (funcall (plist-get fleet-core-owner :live-p)))
    (fleet-fail 'owner-unproven "No live Fleet owner lease in this Emacs"))
  (plist-get fleet-core-owner :epoch))

(defvar fleet-core-event-sink nil
  "Function (EVENT) receiving normalized adapter events.
Installed by the supervisor.")

(defun fleet-core--emit (event)
  "Forward EVENT to `fleet-core-event-sink' when installed."
  (when fleet-core-event-sink (funcall fleet-core-event-sink event)))

;;;; Actors

(defun fleet-core-actor-commander (fleet-id) "Logical commander actor of FLEET-ID." (format "fleet:%s:commander" fleet-id))
(defun fleet-core-actor-operator (task-id) "Logical operator actor of TASK-ID." (format "task:%s:operator" task-id))
(defconst fleet-core-actor-human "human")

;;;; Fleets

(defun fleet-core-assert-model (store model)
  "Refuse MODEL when the ECA catalog is known and does not list it.
Before any runtime has announced the catalog there is nothing to check
against, so MODEL passes through and ECA judges it at first prompt."
  (when model
    (let ((known (plist-get (fleet-store-eca-catalog store) :models)))
      (when (and known (not (member model known)))
        (fleet-fail 'unknown-model "Model is not in the ECA catalog; use an exact id from the list"
                    :model model
                    :suggestions (cl-remove-if-not
                                  (lambda (m) (cl-some (lambda (w) (string-match-p (regexp-quote w) m))
                                                       (split-string (downcase model) "[^a-z0-9.]+" t)))
                                  known))))
    model))

(cl-defun fleet-core-create-fleet (store name &key model agent variant parent-id charter)
  "Create an active fleet NAME; return its row.
MODEL, AGENT and VARIANT select the commander's ECA model.  With PARENT-ID
the fleet is a lieutenant of that root fleet with CHARTER (required prose
the root commander routes by); one level only (docs/lieutenants.md §2)."
  (fleet-paths-assert-name name "fleet")
  (when parent-id
    (let ((parent (fleet-core-fleet store parent-id)))
      (when (plist-get parent :parent-id)
        (fleet-fail 'nested-lieutenant "A lieutenant cannot have lieutenants" :parent (fleet-core-fleet-selector store parent)))
      (when (or (null charter) (string-blank-p charter))
        (fleet-fail 'charter-required "A lieutenant needs a charter" :name name))
      (setq parent-id (plist-get parent :id))))
  (when (fleet-store-fleet-by-name store name parent-id)
    (fleet-fail 'fleet-exists "A fleet with that name is active or parked" :name name :parent-id parent-id))
  (fleet-core-assert-model store (or model fleet-commander-model))
  (let* ((id (fleet-paths-uuid)) (now (fleet-paths-now))
         (root (fleet-paths-fleet-dir id)))
    (fleet-paths-ensure-dir (expand-file-name "commander" root))
    (fleet-paths-ensure-dir (expand-file-name "tasks" root))
    (unless (file-exists-p (expand-file-name "about.md" root))
      (fleet-paths-write-atomically (expand-file-name "about.md" root)
                                    (format "# %s\n\nProject context for the commander. Edit freely.\n" name)))
    (unless (file-exists-p (expand-file-name "commander/context.md" root))
      (fleet-paths-write-atomically (expand-file-name "commander/context.md" root)
                                    "# Commander handoff\n\nDecisions, next steps, artifact pointers.\n"))
    (fleet-store-transaction store
      (fleet-store-insert store "fleets"
                          (list :id id :name name :lifecycle "active" :supervision 1 :artifact-root root
                                :parent-id parent-id :charter (and parent-id charter)
                                :context-path "commander/context.md"
                                :commander-model (or model fleet-commander-model)
                                :commander-agent (or agent fleet-agent)
                                :commander-variant (or variant fleet-commander-variant)
                                :created-at now :updated-at now))
      (fleet-store-append-event store :fleet-id id :kind "fleet-created" :actor fleet-core-actor-human
                                :payload (list :name name :parent-id parent-id)))
    (fleet-store-get store "fleets" id)))

;;;; Lieutenants: selectors, hierarchy, effective role (docs/lieutenants.md)

(defun fleet-core-fleet-selector (store fleet)
  "Human-facing name of FLEET row: `root' or `root/child'."
  (if-let* ((pid (plist-get fleet :parent-id)))
      (format "%s/%s" (plist-get (fleet-store-get store "fleets" pid) :name) (plist-get fleet :name))
    (plist-get fleet :name)))

(defun fleet-core-lieutenants (store fleet-id)
  "Non-archived lieutenant fleets of FLEET-ID."
  (fleet-store-lieutenants store fleet-id))

(defun fleet-core-root-fleet (store fleet)
  "Root fleet row of FLEET (itself when it has no parent)."
  (if-let* ((pid (plist-get fleet :parent-id)))
      (fleet-store-get store "fleets" pid)
    fleet))

(defun fleet-core-effective-role (store rt)
  "Role runtime RT acts under: `commander', `lieutenant' or `operator'.
A commander runtime whose fleet has a parent is a lieutenant; the stored
`runtimes.role' stays `commander' (it commands its own fleet)."
  (let ((role (plist-get rt :role)))
    (if (and (equal role "commander")
             (plist-get (fleet-store-get store "fleets" (plist-get rt :fleet-id)) :parent-id))
        "lieutenant"
      role)))

(defun fleet-core-ensure-lieutenants (store fleet-id)
  "Apply the owner's configured lieutenants of root FLEET-ID (docs/lieutenants.md §3).
Creates missing lieutenants (model/variant from the entry, else the policy's
`lieutenant' selection, else the root's own pin, else unpinned so the start
resolves it — see `fleet-core-commander-model') and records changed charters
or pins.  Never removes,
detaches or reparents: a lieutenant absent from the file is left alone.
Returns (:created (ROW...) :updated (ROW...) :unconfigured (ROW...)).
Signals `invalid-fleet-config' when the fleets section is malformed."
  (let* ((fleet (fleet-core-fleet store fleet-id))
         (configured (progn
                       (when (plist-get fleet :parent-id)
                         (fleet-fail 'nested-lieutenant "Only a root fleet has lieutenants" :fleet (fleet-core-fleet-selector store fleet)))
                       (fleet-config-lieutenants (plist-get fleet :name))))
         ;; What a lieutenant without its own entry model is pinned to: the
         ;; owner's lieutenant selection, else the root's persisted pin.  Not
         ;; the root's *effective* model, which would freeze the ECA default
         ;; of the moment into a pin.
         (pin (or (fleet-policy-supervisor (fleet-core-model-policy) "lieutenant")
                  (cons (plist-get fleet :commander-model) (plist-get fleet :commander-variant))))
         created updated)
    (dolist (c configured)
      (let* ((model (or (plist-get c :model) (car pin)))
             (variant (if (plist-get c :model) (plist-get c :variant) (cdr pin)))
             (existing (fleet-store-fleet-by-name store (plist-get c :name) (plist-get fleet :id))))
        (cond
         ((null existing)
          (push (fleet-core-create-fleet store (plist-get c :name) :parent-id (plist-get fleet :id) :charter (plist-get c :charter)
                                         :model model :variant variant :agent (plist-get fleet :commander-agent))
                created))
         ((not (and (equal (plist-get existing :charter) (plist-get c :charter))
                    (equal (plist-get existing :commander-model) model)
                    (equal (plist-get existing :commander-variant) variant)))
          (fleet-core-assert-model store model)
          (fleet-store-transaction store
            (fleet-store-update store "fleets" (plist-get existing :id)
                                (fleet-store-touch (list :charter (plist-get c :charter) :commander-model model :commander-variant variant)))
            (fleet-store-append-event store :fleet-id (plist-get existing :id) :kind "lieutenant-configured" :actor fleet-core-actor-human
                                      :payload (list :charter (plist-get c :charter) :model model :variant variant)))
          (push (fleet-store-get store "fleets" (plist-get existing :id)) updated)))))
    (list :created (nreverse created) :updated (nreverse updated)
          :unconfigured (cl-remove-if (lambda (lt) (cl-find (plist-get lt :name) configured :key (lambda (c) (plist-get c :name)) :test #'equal))
                                      (fleet-core-lieutenants store (plist-get fleet :id))))))

(cl-defun fleet-core-set-commander-model (store fleet-id &key model variant)
  "Pin FLEET-ID's commander to MODEL/VARIANT; return the updated fleet row.
Nil MODEL clears the pin (the next commander uses `fleet-commander-model',
else the owner policy's `commander'/`lieutenant' selection, else the ECA
default; see `fleet-core-commander-model'); nil VARIANT clears the variant.  Takes effect at the
next commander start: a live commander keeps the model it was launched with."
  (let ((fleet (fleet-core-fleet store fleet-id)))
    (fleet-core-assert-model store model)
    (fleet-store-transaction store
      (fleet-store-update store "fleets" (plist-get fleet :id)
                          (fleet-store-touch (list :commander-model model :commander-variant variant)))
      (fleet-store-append-event store :fleet-id (plist-get fleet :id) :kind "commander-model-changed" :actor fleet-core-actor-human
                                :payload (list :model model :variant variant
                                               :previous-model (plist-get fleet :commander-model)
                                               :previous-variant (plist-get fleet :commander-variant))))
    (fleet-store-get store "fleets" (plist-get fleet :id))))

(defun fleet-core-commander-model (fleet)
  "Effective (MODEL . VARIANT) the next commander of FLEET launches with.
The fleet's pin wins, else `fleet-commander-model'/`fleet-commander-variant',
else the owner policy's `commander' selection (`lieutenant' for a fleet
with a parent); nil means the ECA default.  The policy `default' is for
operators and is never consulted here.  The variant follows whichever
source supplied the model."
  (let ((pinned (or (plist-get fleet :commander-model) fleet-commander-model)))
    (if pinned
        (cons pinned (or (plist-get fleet :commander-variant) fleet-commander-variant))
      (let ((s (fleet-policy-supervisor (fleet-core-model-policy) (if (plist-get fleet :parent-id) "lieutenant" "commander"))))
        (cons (car s) (or (plist-get fleet :commander-variant) fleet-commander-variant (cdr s)))))))

(defun fleet-core-fleet (store ref)
  "Fleet row by id, active root name, or `root/child' selector REF.
Signal `no-such-fleet' otherwise."
  (or (fleet-store-get store "fleets" ref)
      (if (string-match "\\`\\([^/]+\\)/\\([^/]+\\)\\'" ref)
          (when-let* ((root (fleet-store-fleet-by-name store (match-string 1 ref))))
            (fleet-store-fleet-by-name store (match-string 2 ref) (plist-get root :id)))
        (fleet-store-fleet-by-name store ref))
      (fleet-fail 'no-such-fleet "No such fleet" :ref ref)))

(defun fleet-core-set-supervision (store fleet-id on)
  "Persist the supervision flag ON for FLEET-ID."
  (fleet-store-transaction store
    (fleet-store-update store "fleets" fleet-id (fleet-store-touch (list :supervision (if on 1 0))))
    (fleet-store-append-event store :fleet-id fleet-id :kind (if on "supervision-on" "supervision-paused")
                              :actor fleet-core-actor-human)))

(defun fleet-core-fleet-artifact-root (fleet) "Absolute artifact root of FLEET row." (plist-get fleet :artifact-root))

(defun fleet-core-fleet-file (fleet rel) "Absolute path of managed REL under FLEET's root." (fleet-paths-join-managed (fleet-core-fleet-artifact-root fleet) rel))

;;;; Tasks

(defconst fleet-core-task-kinds '("change" "study" "ops"))
(defconst fleet-core-delivery-modes '("remote-review" "local-ready" "integrated"))
(defconst fleet-core-operator-phases '("working" "needs-decision" "blocked" "paused" "done" "failed"))
(defconst fleet-core-terminal-phases '("done" "failed"))

;;;; Operator model selection (owner policy, see fleet-policy.el)

(defun fleet-core-model-policy ()
  "The owner's model policy, or nil when there is no policy file."
  (fleet-policy-load))

(defun fleet-core-operator-default (store policy)
  "(MODEL . VARIANT) an operator gets when nothing chooses otherwise.
POLICY's `default' when it is in the known catalog, else
`fleet-operator-model'/`fleet-operator-variant'; nil means the ECA default."
  (let ((d (fleet-policy-default policy (plist-get (fleet-store-eca-catalog store) :models))))
    (if d (cons (plist-get d :model) (plist-get d :variant))
      (cons fleet-operator-model fleet-operator-variant))))

(defun fleet-core-assert-approved (policy model owner-approved &rest evidence)
  "Refuse MODEL when POLICY wants the owner asked first and OWNER-APPROVED is nil.
That is a listed ask-first model, or any model while `ask_first' holds the
wildcard.  The refusal carries EVIDENCE (the selection and its reason) so
the commander can put a concrete proposal to the user.  The gate applies
however the model was chosen: an explicit request needs the flag too, which
makes the commander state that the user agreed.  Returns MODEL."
  (when (and (fleet-policy-ask-first-p policy model) (not owner-approved))
    (apply #'fleet-fail 'model-needs-approval
           "The owner wants to be asked before this runs. Propose the model, variant and your reason to the user; then retry with owner_approved true, or pass the model the user chose instead"
           :model model evidence))
  model)

(cl-defun fleet-core-select-operator-model (store &key model variant model-reason owner-approved)
  "Settle what an operator runs on from the commander's MODEL/VARIANT request.
Routing is the commander's judgement under the owner's policy rules (see
`fleet-policy-describe'); MODEL-REASON is its stated ground (the rule it
applied, or the user's words) and is recorded, not interpreted.  An explicit
MODEL wins; otherwise the policy default; otherwise the defcustoms; nil
means the ECA default.  VARIANT alone overrides only the variant.  The
model must be in the catalog when one is known, and an ask-first model —
or any model while the policy asks for everything — is refused with
`model-needs-approval' unless OWNER-APPROVED (`fleet-core-assert-approved').
Returns (:model M :variant V :source SOURCE :reason R) where SOURCE is
explicit, policy-default, config or eca-default."
  (let* ((policy (fleet-core-model-policy))
         (pd (fleet-policy-default policy (plist-get (fleet-store-eca-catalog store) :models)))
         (sel (cond
               (model (list :model model :variant variant :source "explicit"))
               (pd (list :model (plist-get pd :model) :variant (or variant (plist-get pd :variant)) :source "policy-default"))
               (fleet-operator-model (list :model fleet-operator-model :variant (or variant fleet-operator-variant) :source "config"))
               (t (list :model nil :variant (or variant fleet-operator-variant) :source "eca-default")))))
    (fleet-core-assert-model store (plist-get sel :model))
    (fleet-core-assert-approved policy (plist-get sel :model) owner-approved
                                :variant (plist-get sel :variant) :source (plist-get sel :source)
                                :reason model-reason)
    (append sel (list :reason model-reason))))

(defun fleet-core-task (store ref &optional fleet-id)
  "Task row by id, or by name within FLEET-ID; signal `no-such-task'."
  (or (fleet-store-get store "tasks" ref)
      (and fleet-id (fleet-store-task-by-name store fleet-id ref))
      (fleet-fail 'no-such-task "No such task" :ref ref)))

(defun fleet-core-task-dir (store task) "Absolute task directory of TASK row." (expand-file-name (concat "tasks/" (plist-get task :id)) (plist-get (fleet-store-get store "fleets" (plist-get task :fleet-id)) :artifact-root)))

(defun fleet-core--dependency-cycle-p (store task-id deps)
  "Non-nil when adding DEPS to TASK-ID would create a cycle."
  (let ((seen (make-hash-table :test 'equal)) (stack (copy-sequence deps)))
    (catch 'cycle
      (while stack
        (let ((cur (pop stack)))
          (when (equal cur task-id) (throw 'cycle t))
          (unless (gethash cur seen)
            (puthash cur t seen)
            (dolist (row (fleet-store-query store "SELECT depends_on_id FROM task_dependencies WHERE task_id = ?" cur))
              (push (plist-get row :depends-on-id) stack)))))
      nil)))

(cl-defun fleet-core-create-task (store fleet-id &key name kind brief repo base-ref branch delivery
                                        workspace-mode adopt-path dependencies resources model variant context-paths
                                        model-reason owner-approved actor)
  "Create a ready task in FLEET-ID from a complete BRIEF; return its row.
KIND is change/study/ops.  For change tasks REPO is the primary clone,
WORKSPACE-MODE is `new' (default), `adopt-branch' or `adopt-worktree' with
ADOPT-PATH naming the branch or worktree; BASE-REF/BRANCH/DELIVERY describe
the Git contract.  DEPENDENCIES are task ids in the same fleet; RESOURCES are
named exclusive resources; CONTEXT-PATHS list extra read context.

The operator's model is settled by `fleet-core-select-operator-model': the
commander's MODEL/VARIANT (chosen under the owner's policy rules, with
MODEL-REASON saying why) wins, else the policy default, else the
defcustoms.  OWNER-APPROVED asserts the user agreed where the policy asks
first.  The returned row carries extra `:model-source' and
`:delivery-source' keys (\"explicit\", \"default\", \"default-no-remote\")."
  (let ((fleet (fleet-core-fleet store fleet-id)) (selection nil) (delivery-source nil))
    (fleet-paths-assert-name name "task")
    (unless (member kind fleet-core-task-kinds) (fleet-fail 'invalid-task "Unknown task kind" :kind kind))
    (setq selection (fleet-core-select-operator-model store :model model :variant variant :model-reason model-reason
                                                      :owner-approved owner-approved))
    (unless (and (stringp brief) (>= (length (string-trim brief)) 40))
      (fleet-fail 'invalid-task "Brief is missing or too short to be complete" :length (length (or brief ""))))
    (when (member (plist-get fleet :lifecycle) '("parking" "parked" "retiring" "archived"))
      (fleet-fail 'fleet-not-active "Fleet does not accept new tasks" :lifecycle (plist-get fleet :lifecycle)))
    (when (fleet-store-task-by-name store fleet-id name)
      (fleet-fail 'task-exists "Task name already active in this fleet" :name name))
    (when (equal kind "change")
      (unless (and repo (file-directory-p repo)) (fleet-fail 'invalid-task "Change task needs an existing repository path" :repo repo))
      (unless (fleet-paths-contains-p (fleet-paths-development-root) repo)
        (fleet-fail 'invalid-task "Repository must live under the development root" :repo repo :root (fleet-paths-development-root)))
      (when (and delivery (not (member delivery fleet-core-delivery-modes)))
        (fleet-fail 'invalid-task "Unknown delivery mode" :delivery delivery))
      ;; remote-review is a promise to push for review.  A repository with
      ;; no remote cannot keep it, and teardown would only discover that
      ;; after the work is done.  Judge the contract here: refuse an
      ;; explicit remote-review, and let an omitted delivery follow the
      ;; repository rather than a fixed default.
      (let ((remotes (fleet-git-remotes-now repo)))
        (cond
         (delivery
          (when (and (equal delivery "remote-review") (null remotes))
            (fleet-fail 'delivery-needs-remote "remote-review delivery needs a remote to push to; this repository has none (use local-ready or integrated)"
                        :repo repo :delivery delivery))
          (setq delivery-source "explicit"))
         (remotes (setq delivery "remote-review" delivery-source "default"))
         (t (setq delivery "local-ready" delivery-source "default-no-remote"))))
      (when (and (memq workspace-mode '(adopt-branch adopt-worktree)) (not adopt-path))
        (fleet-fail 'invalid-task "Adoption needs the branch or worktree to adopt")))
    (dolist (d dependencies)
      (let ((dep (fleet-store-get store "tasks" d)))
        (unless dep (fleet-fail 'invalid-dependency "Dependency does not exist" :id d))
        (unless (equal (plist-get dep :fleet-id) fleet-id)
          (fleet-fail 'invalid-dependency "Cross-fleet dependencies are not allowed" :id d))))
    ;; Named exclusive resources are held until the owning task is archived.
    ;; Refuse with the holder instead of surfacing a UNIQUE constraint error.
    (dolist (r resources)
      (when-let* ((held (fleet-store-query1 store "SELECT task_id FROM resource_claims WHERE key = ?" r)))
        (let ((holder (fleet-store-get store "tasks" (plist-get held :task-id))))
          (fleet-fail 'resource-claimed "Resource is claimed by another task until it is archived; retask that task or tear it down first"
                      :resource r :task-id (plist-get held :task-id) :task-name (plist-get holder :name)
                      :lifecycle (plist-get holder :lifecycle) :phase (plist-get holder :phase)))))
    (let* ((id (fleet-paths-uuid)) (now (fleet-paths-now))
           (dir (fleet-paths-join-managed (plist-get fleet :artifact-root) (concat "tasks/" id))))
      (when (fleet-core--dependency-cycle-p store id dependencies)
        (fleet-fail 'invalid-dependency "Dependencies would form a cycle"))
      (fleet-paths-ensure-dir (expand-file-name "briefs" dir))
      (fleet-paths-ensure-dir (expand-file-name "artifacts" dir))
      (fleet-paths-ensure-dir (expand-file-name "runs" dir))
      (unless (file-exists-p (expand-file-name "progress.md" dir))
        (fleet-paths-write-atomically (expand-file-name "progress.md" dir)
                                      (format "# Progress — %s\n\n(restart-relevant facts, commands, remaining work)\n" name)))
      (fleet-store-transaction store
        (fleet-store-insert store "tasks"
                            (list :id id :fleet-id fleet-id :name name :kind kind :lifecycle "draft"
                                  :brief-revision 0
                                  :repo-path (and repo (fleet-paths-canonical repo))
                                  :workspace-ownership (pcase workspace-mode ('adopt-worktree "adopted") (_ (and (equal kind "change") "fleet")))
                                  :workspace-path (and (eq workspace-mode 'adopt-worktree) (fleet-paths-canonical adopt-path))
                                  :branch (pcase workspace-mode ('adopt-branch adopt-path) ('adopt-worktree nil) (_ branch))
                                  :branch-ownership (pcase workspace-mode ((or 'adopt-branch 'adopt-worktree) "adopted") (_ (and (equal kind "change") "fleet")))
                                  :base-ref base-ref
                                  :delivery-mode (and (equal kind "change") delivery)
                                  :model (plist-get selection :model)
                                  :variant (plist-get selection :variant)
                                  :created-at now :updated-at now))
        (dolist (d dependencies)
          (fleet-store-insert store "task_dependencies" (list :task-id id :depends-on-id d)))
        (dolist (r resources)
          (fleet-store-insert store "resource_claims"
                              (list :id (fleet-paths-uuid) :fleet-id fleet-id :kind "resource" :key r :task-id id :created-at now)))
        (fleet-store-append-event store :fleet-id fleet-id :task-id id :kind "task-created" :actor actor
                                  :payload (list :name name :kind kind :context-paths (vconcat context-paths)
                                                 ;; Delivery and its provenance: a defaulted contract must be
                                                 ;; visible as such when it later refuses a teardown.
                                                 :delivery (and (equal kind "change") delivery)
                                                 :delivery-source (and (equal kind "change") delivery-source)
                                                 ;; The routing judgement is not a column: the choice and
                                                 ;; the commander's stated reason are what stay auditable.
                                                 :model (plist-get selection :model) :variant (plist-get selection :variant)
                                                 :model-source (plist-get selection :source)
                                                 :model-reason (plist-get selection :reason)
                                                 :owner-approved (and owner-approved t))))
      (fleet-core-publish-brief store id brief :note "initial brief")
      (fleet-store-transaction store
        (fleet-store-update store "tasks" id (fleet-store-touch (list :lifecycle "ready"))))
      (append (fleet-store-get store "tasks" id) (list :model-source (plist-get selection :source)
                                                         :delivery-source delivery-source)))))

;;;; Brief revisions (design §7.3)

(defun fleet-core--brief-text (task text revision note)
  "Render brief TEXT for TASK with a revision header."
  (format "<!-- fleet task %s revision %d%s -->\n%s%s"
          (plist-get task :id) revision (if note (format " — %s" note) "")
          text (if (string-suffix-p "\n" text) "" "\n")))

(cl-defun fleet-core-publish-brief (store task-id text &key note)
  "Publish TEXT as the next immutable brief revision of TASK-ID.
Writes briefs/NNNN.md and brief.md atomically under an operation record,
then commits revision/hash in one transaction.  Returns the new revision."
  (let* ((task (fleet-core-task store task-id))
         (dir (fleet-core-task-dir store task))
         (rev (1+ (plist-get task :brief-revision)))
         (rel (format "briefs/%04d.md" rev))
         (file (expand-file-name rel dir))
         (body (fleet-core--brief-text task text rev note))
         (hash (fleet-paths-sha256-string body))
         (op (fleet-core-operation-begin store "brief-publish" :fleet-id (plist-get task :fleet-id) :task-id task-id
                                         :intent (list :revision rev :rel-path rel :hash hash))))
    (fleet-paths-write-atomically file body)
    (fleet-paths-write-atomically (expand-file-name "brief.md" dir) body)
    (fleet-core--commit-brief store task-id rev rel hash op)
    rev))

(defun fleet-core--commit-brief (store task-id rev rel hash op)
  "Record published brief REV (REL, HASH) for TASK-ID and finish OP."
  (fleet-store-transaction store
    (let ((task (fleet-store-get store "tasks" task-id)))
      (unless (= (plist-get task :brief-revision) (1- rev))
        (fleet-fail 'brief-revision-mismatch "Brief revision advanced concurrently" :expected (1- rev) :actual (plist-get task :brief-revision)))
      (fleet-store-update store "tasks" task-id (fleet-store-touch (list :brief-revision rev :brief-hash hash :brief-path (concat "tasks/" task-id "/" rel))))
      (fleet-store-bump-revision store "tasks" task-id)
      (fleet-store-append-event store :fleet-id (plist-get task :fleet-id) :task-id task-id :kind "brief-revised"
                                :payload (list :revision rev :hash hash) :operation-id op)
      (fleet-core-operation-finish store op :state "done"))))

(defun fleet-core-brief-runnable-p (store task)
  "Non-nil when TASK's recorded brief revision exists on disk.
The file must carry the recorded hash."
  (let* ((fleet (fleet-store-get store "fleets" (plist-get task :fleet-id)))
         (path (and (plist-get task :brief-path) (fleet-core-fleet-file fleet (plist-get task :brief-path)))))
    (and path (> (plist-get task :brief-revision) 0)
         (equal (fleet-paths-sha256-file path) (plist-get task :brief-hash)))))

(defun fleet-core-brief-file (store task)
  "Absolute path of TASK's current immutable brief revision, or nil."
  (when (plist-get task :brief-path)
    (fleet-core-fleet-file (fleet-store-get store "fleets" (plist-get task :fleet-id)) (plist-get task :brief-path))))

(defun fleet-core-recover-brief-operation (store op)
  "Resolve an interrupted brief-publish OP by inspecting the files."
  (let* ((intent (fleet-store-unjson (plist-get op :intent)))
         (task (fleet-store-get store "tasks" (plist-get op :task-id)))
         (file (expand-file-name (plist-get intent :rel-path) (fleet-core-task-dir store task))))
    (if (and (file-exists-p file) (equal (fleet-paths-sha256-file file) (plist-get intent :hash))
             (= (plist-get task :brief-revision) (1- (plist-get intent :revision))))
        (progn (fleet-paths-write-atomically (expand-file-name "brief.md" (fleet-core-task-dir store task)) (fleet-paths-read-file file))
               (fleet-core--commit-brief store (plist-get task :id) (plist-get intent :revision) (plist-get intent :rel-path) (plist-get intent :hash) (plist-get op :id))
               'committed)
      (fleet-store-transaction store
        (fleet-core-operation-finish store (plist-get op :id) :state "failed" :error "brief file missing or hash mismatch; revision not runnable"))
      'failed)))

(defun fleet-core--retask-selection (store model variant &optional owner-approved)
  "Task column updates for a retask's MODEL and VARIANT requests.
Nil leaves a column unchanged; \"default\" returns it to the operator
default (`fleet-core-operator-default': the policy default, else the
defcustoms); any other model must be in the catalog and, when the owner's
policy lists it under ask_first, needs OWNER-APPROVED.  Returns a plist for
`fleet-store-update' (possibly empty)."
  (let* ((policy (fleet-core-model-policy))
         (default (fleet-core-operator-default store policy)))
    (append (when model
              (list :model (if (equal model "default") (car default)
                             (fleet-core-assert-approved policy (fleet-core-assert-model store model) owner-approved
                                                         :variant variant :source "explicit"))))
            (when variant
              (list :variant (if (equal variant "default") (cdr default) variant))))))

(cl-defun fleet-core-retask (store task-id text &key expected-revision note actor model variant owner-approved callback)
  "Give TASK-ID new durable scope TEXT; the result is a ready task at a new
revision.  A done task requires non-empty TEXT.

MODEL and VARIANT, when given, change what the next operator of this task
runs on (see `fleet-core--retask-selection'; OWNER-APPROVED as for task
creation); the workspace, brief history and progress notes carry over, so
a struggling operator can be replaced by a stronger model or reasoning
effort in place.  Blank TEXT with only a selection change is allowed unless
the task is done.

When the task's current runtime is already stopped the retask is immediate
and the task row is returned.  When the runtime is still live but idle (the
operator reported failed/blocked/done and its turn ended), the retask runs
as a `task-retask' operation: the runtime is stopped with full proof, then
the brief is published and the task committed ready; an actionable
`task-retasked' event announces completion.  Returns (:operation-id ..) in
that case.  A runtime mid-turn is refused (`runtime-busy'); an unproven
stop (`stop-unknown', `stopping', `launching') stays refused."
  (let* ((task (fleet-core-task store task-id))
         (rt (and (plist-get task :current-runtime-id) (fleet-store-get store "runtimes" (plist-get task :current-runtime-id))))
         (live (and rt (not (member (plist-get rt :lifecycle) '("stopped" "never-launched")))))
         (selection nil))
    (fleet-store-check-revision store "tasks" task-id expected-revision)
    (when (member (plist-get task :lifecycle) '("closing" "archived"))
      (fleet-fail 'task-closed "Task is closing or archived" :lifecycle (plist-get task :lifecycle)))
    (when (and (equal (plist-get task :phase) "done") (string-blank-p (or text "")))
      (fleet-fail 'invalid-task "A done task requires non-empty new scope"))
    ;; Validate the selection before anything is stopped or written.
    (setq selection (fleet-core--retask-selection store model variant owner-approved))
    (cond
     ((not live)
      (fleet-core--retask-commit store task-id text note actor nil selection)
      (fleet-store-get store "tasks" task-id))
     (t
      (unless (member (plist-get rt :lifecycle) '("ready" "lost"))
        (fleet-fail 'runtime-not-stopped "Current runtime must be proven stopped before retasking"
                    :runtime-id (plist-get rt :id) :lifecycle (plist-get rt :lifecycle)))
      (when (fleet-core-task-operation-running-p store task-id)
        (fleet-fail 'operation-in-progress "Another lifecycle operation is running"))
      (let ((conn (fleet-eca-conn (plist-get rt :id))))
        (when (and conn (fleet-eca-conn-turn conn))
          (fleet-fail 'runtime-busy "Operator is still responding; retask after its turn ends (you are woken by its status event)"
                      :runtime-id (plist-get rt :id))))
      (let ((op (fleet-core-operation-begin store "task-retask" :fleet-id (plist-get task :fleet-id) :task-id task-id
                                            :runtime-id (plist-get rt :id) :expected-revision (plist-get task :entity-revision)
                                            :intent (append (list :note note :text-chars (length (or text ""))) selection))))
        (fleet-core-operation-step store op "stopping-runtime")
        (fleet-core-stop-runtime store (plist-get rt :id) :reason "retask"
                                 :callback
                                 (lambda (r)
                                   (if (equal (plist-get r :lifecycle) "stopped")
                                       (condition-case err
                                           (progn
                                             (fleet-core-operation-step store op "runtime-stopped")
                                             (fleet-core--retask-commit store task-id text note actor op selection)
                                             (fleet-core-operation-finish store op :state "done" :evidence (list :brief-revision (plist-get (fleet-store-get store "tasks" task-id) :brief-revision))))
                                         (error (fleet-core-operation-finish store op :state "failed" :error (fleet-error-string err))))
                                     (fleet-core-operation-finish store op :state "failed" :error "runtime stop not proven; task unchanged"
                                                                  :evidence (list :verdict (plist-get r :verdict))))
                                   (when callback (funcall callback (fleet-store-get store "operations" op)))))
        (list :operation-id op :task-id task-id))))))

(defun fleet-core--retask-commit (store task-id text note actor op &optional selection)
  "Publish TEXT (unless blank) and commit TASK-ID ready at the new revision.
SELECTION is the model/variant column update plist (may be empty).
OP, when non-nil, is the `task-retask' operation; its completion event is
actionable so the commander learns the task can be started."
  (let ((task (fleet-core-task store task-id)))
    (unless (string-blank-p (or text ""))
      (fleet-core-publish-brief store task-id text :note (or note "retask")))
    (fleet-store-transaction store
      (fleet-store-update store "tasks" task-id (fleet-store-touch (append (list :lifecycle "ready" :phase nil :detail (or note "retasked") :detail-at (fleet-paths-now)
                                                                              :wait-reason nil :wait-deadline nil :wait-job-id nil)
                                                                        selection)))
      (fleet-store-exec store "UPDATE artifacts SET verified = 0 WHERE task_id = ?" task-id)
      (let ((now (fleet-store-get store "tasks" task-id)))
        (fleet-store-append-event store :fleet-id (plist-get task :fleet-id) :task-id task-id :kind "task-retasked" :actor actor :operation-id op
                                  :payload (list :note note :brief-revision (plist-get now :brief-revision)
                                                 :model (plist-get now :model) :variant (plist-get now :variant)
                                                 :selection-changed (and selection t))
                                  :actionable (and op t))))))

(defun fleet-core-pick-remote (remotes)
  "The remote a task pushes to among REMOTES: the only one, else origin, else the first."
  (cond ((null remotes) nil) ((= 1 (length remotes)) (car remotes)) ((member "origin" remotes) "origin") (t (car remotes))))

(cl-defun fleet-core-set-delivery (store task-id delivery &key note actor owner-approved expected-revision)
  "Change TASK-ID's delivery contract to DELIVERY on the owner's word.

Live run 2026-09-17: the owner switched from review-by-PR to merging
locally while a task was in flight; only the brief text could follow, the
row kept `remote-review', and teardown of the finished task refused until
the commander pushed a branch nobody wanted.  Delivery is the owner's
contract with the repository, so OWNER-APPROVED is required, the task may
be in any lifecycle short of closing/archived, and no runtime is stopped:
the operator's prompt named the old mode, so the commander tells it.

A local mode clears the task's remote so cleanup evidence judges the tip
against the local target branch; `remote-review' needs a remote now, as at
creation, and records it.  Returns the updated task row."
  (let* ((task (fleet-core-task store task-id))
         (from (plist-get task :delivery-mode)))
    (fleet-store-check-revision store "tasks" task-id expected-revision)
    (unless (equal (plist-get task :kind) "change")
      (fleet-fail 'invalid-task "Only change tasks have a delivery contract" :kind (plist-get task :kind)))
    (unless (member delivery fleet-core-delivery-modes)
      (fleet-fail 'invalid-task "Unknown delivery mode" :delivery delivery))
    (when (member (plist-get task :lifecycle) '("closing" "archived"))
      (fleet-fail 'task-closed "Task is closing or archived" :lifecycle (plist-get task :lifecycle)))
    (unless owner-approved
      (fleet-fail 'delivery-needs-approval "Delivery is the owner's contract; change it only on the user's explicit word (owner_approved)"
                  :task-id task-id :from from :to delivery))
    (let ((remote (and (equal delivery "remote-review")
                       (or (fleet-core-pick-remote (fleet-git-remotes-now (plist-get task :repo-path)))
                           (fleet-fail 'delivery-needs-remote "remote-review delivery needs a remote to push to; this repository has none (use local-ready or integrated)"
                                       :repo (plist-get task :repo-path) :delivery delivery)))))
      (fleet-store-transaction store
        (fleet-store-update store "tasks" task-id (fleet-store-touch (list :delivery-mode delivery :remote remote)))
        (fleet-store-append-event store :fleet-id (plist-get task :fleet-id) :task-id task-id :kind "task-delivery-changed" :actor actor
                                  :payload (list :from from :to delivery :delivery-source "explicit" :remote remote
                                                 :note note :owner-approved t)))
      (fleet-store-get store "tasks" task-id))))

;;;; Operator status, decisions, waits, artifacts, external jobs

(defun fleet-core-runtime-authorized (store runtime-id &optional task-id)
  "Runtime row for RUNTIME-ID if it is the live current runtime of its task/fleet.
Signals `stale-runtime' otherwise.  TASK-ID, when given, must match."
  (let ((rt (fleet-store-get store "runtimes" runtime-id)))
    (unless rt (fleet-fail 'stale-runtime "Unknown runtime" :runtime-id runtime-id))
    (when (eql 1 (plist-get rt :credential-revoked)) (fleet-fail 'stale-runtime "Runtime credential revoked" :runtime-id runtime-id))
    (when (member (plist-get rt :lifecycle) '("stopped" "stop-unknown" "never-launched" "lost"))
      (fleet-fail 'stale-runtime "Runtime is not live" :runtime-id runtime-id :lifecycle (plist-get rt :lifecycle)))
    (if (equal (plist-get rt :role) "operator")
        (let ((task (fleet-store-get store "tasks" (plist-get rt :task-id))))
          (unless (equal (plist-get task :current-runtime-id) runtime-id)
            (fleet-fail 'stale-runtime "Runtime is not the task's current runtime" :runtime-id runtime-id))
          (when (and task-id (not (equal task-id (plist-get task :id))))
            (fleet-fail 'forbidden "Operators may only act on their own task" :task-id task-id)))
      (let ((fleet (fleet-store-get store "fleets" (plist-get rt :fleet-id))))
        (unless (equal (plist-get fleet :commander-runtime-id) runtime-id)
          (fleet-fail 'stale-runtime "Runtime is not the fleet's current commander" :runtime-id runtime-id))))
    rt))

(cl-defun fleet-core-task-status (store &key runtime-id phase detail decision wait artifacts)
  "Accept an operator status from RUNTIME-ID: PHASE, DETAIL, optional DECISION,
WAIT (:reason :deadline :job-id) and ARTIFACTS (list of plists).  Terminal
phases cannot revert; done requires registered artifacts.  Returns a plist."
  (let* ((rt (fleet-core-runtime-authorized store runtime-id))
         (task (fleet-store-get store "tasks" (plist-get rt :task-id)))
         (tid (plist-get task :id)) (fid (plist-get task :fleet-id))
         (now (fleet-paths-now)))
    (unless (member phase fleet-core-operator-phases) (fleet-fail 'invalid-status "Unknown phase" :phase phase))
    (when (and (member (plist-get task :phase) fleet-core-terminal-phases) (not (equal phase (plist-get task :phase))))
      (fleet-fail 'terminal-phase "Terminal scope cannot change except through retask" :current (plist-get task :phase) :requested phase))
    (when (and (equal phase "needs-decision") (not (plist-get decision :question)))
      (fleet-fail 'invalid-status "needs-decision requires a decision question"))
    (when (and (equal phase "paused") (not (and (plist-get wait :reason) (plist-get wait :deadline))))
      (fleet-fail 'invalid-status "paused requires a wait reason and deadline"))
    (fleet-store-transaction store
      (dolist (a artifacts) (fleet-core--register-artifact store tid a))
      (when (equal phase "done")
        (unless (> (fleet-store-scalar store "SELECT COUNT(*) FROM artifacts WHERE task_id = ?" tid) 0)
          (fleet-fail 'invalid-status "done requires at least one registered artifact (report or deliverable)")))
      (fleet-store-update store "tasks" tid
                          (fleet-store-touch (list :phase phase :detail (fleet-eca--clip (or detail "") 300) :detail-at now
                                                   :wait-reason (and (equal phase "paused") (plist-get wait :reason))
                                                   :wait-deadline (and (equal phase "paused") (plist-get wait :deadline))
                                                   :wait-job-id (and (equal phase "paused") (plist-get wait :job-id)))))
      (fleet-store-bump-revision store "tasks" tid)
      (let ((decision-id (when (equal phase "needs-decision")
                           (let ((did (fleet-paths-uuid)))
                             (fleet-store-insert store "decisions"
                                                 (list :id did :fleet-id fid :task-id tid :brief-revision (plist-get task :brief-revision)
                                                       :question (plist-get decision :question)
                                                       :options (and (plist-get decision :options) (fleet-store-json (vconcat (plist-get decision :options))))
                                                       :recommendation (plist-get decision :recommendation)
                                                       :authority (or (plist-get decision :authority) "commander")
                                                       :state "open" :created-at now :updated-at now))
                             did))))
        (let ((event-id (fleet-store-append-event
                         store :fleet-id fid :task-id tid :runtime-id runtime-id
                         :kind (pcase phase ("done" "task-done") ("failed" "task-failed") ("blocked" "task-blocked")
                                      ("needs-decision" "decision-requested") ("paused" "task-paused") (_ "task-working"))
                         :actor (fleet-core-actor-operator tid)
                         :payload (list :phase phase :detail detail :decision-id decision-id :wait wait
                                        :brief-revision (plist-get task :brief-revision))
                         :actionable (member phase '("done" "failed" "blocked" "needs-decision")))))
          (list :ok t :task-id tid :phase phase :decision-id decision-id :event-id event-id))))))

;;;; Artifact paths
;;
;; An artifact `rel_path' is relative to the task directory
;; (tasks/<id>/).  The `workspace/' prefix denotes the task's workspace
;; wherever it lives: tasks/<id>/workspace for study and ops tasks, the
;; Git worktree for change tasks.  Registration resolves the path, refuses
;; what does not exist, and stores the canonical form, so verification and
;; teardown look exactly where the operator wrote (openclaw, 2026-09-10:
;; seven deliverables registered as bare names while written under
;; workspace/ were `artifact-missing' at the task root).

(defconst fleet-core-workspace-prefix "workspace/"
  "Artifact path prefix that denotes the task's workspace directory.")

(defun fleet-core-task-workspace-dir (store task)
  "Directory the `workspace/' artifact prefix denotes for TASK.
The recorded workspace when the task has started (a change task's worktree),
else tasks/<id>/workspace."
  (or (plist-get task :workspace-path)
      (expand-file-name "workspace" (fleet-core-task-dir store task))))

(defun fleet-core-artifact-candidates (store task rel-path)
  "Where REL-PATH may live for TASK, as (CANONICAL-REL . ABSOLUTE) pairs.
A `workspace/' path has one home.  A bare path is looked for in the task
directory first, then in the workspace under its canonical `workspace/' name."
  (let ((dir (fleet-core-task-dir store task)) (ws (fleet-core-task-workspace-dir store task)) (prefix fleet-core-workspace-prefix))
    (if (string-prefix-p prefix rel-path)
        (list (cons rel-path (expand-file-name (substring rel-path (length prefix)) ws)))
      (list (cons rel-path (expand-file-name rel-path dir))
            (cons (concat prefix rel-path) (expand-file-name rel-path ws))))))

(defun fleet-core-artifact-locate (store task rel-path)
  "Resolve REL-PATH for TASK to (:rel CANONICAL :file ABSOLUTE), or nil when
it exists nowhere it may."
  (cl-loop for (rel . file) in (fleet-core-artifact-candidates store task rel-path)
           when (file-exists-p file) return (list :rel rel :file file)))

(defun fleet-core-artifact-file (store task rel-path)
  "Absolute path of TASK's artifact REL-PATH, or nil when it does not exist."
  (plist-get (fleet-core-artifact-locate store task rel-path) :file))

(defun fleet-core--register-artifact (store task-id a)
  "Insert artifact plist A for TASK-ID (inside a transaction).
A `:rel-path' may name a file or a directory (verified by tree digest) and
must exist: it is resolved (see `fleet-core-artifact-locate') and stored in
canonical form.  What verification could never process — a missing path, a
special file, an empty directory — is refused here, where the operator can
still fix it, rather than at teardown."
  (let* ((now (fleet-paths-now))
         (rel (plist-get a :rel-path))
         (task (and rel (fleet-store-get store "tasks" task-id))))
    (when rel (fleet-paths-assert-safe-relative rel))
    (when task
      (let ((loc (fleet-core-artifact-locate store task rel)))
        (unless loc
          (fleet-fail 'artifact-missing "Artifact path does not exist; write the deliverable first, then register it"
                      :rel-path rel :looked-at (mapcar #'cdr (fleet-core-artifact-candidates store task rel))))
        (fleet-paths-sha256-path (plist-get loc :file))
        (setq rel (plist-get loc :rel))
        (setq a (plist-put (copy-sequence a) :rel-path rel))))
    ;; Operators tend to register the same deliverable twice (once with
    ;; fleet_artifact_register, again in fleet_status :artifacts).  Two rows
    ;; for one file mean two verifications for one fact; keep one row per
    ;; (task, kind, location) and refresh its description instead.
    (let* ((kind (or (plist-get a :kind) "file"))
           (existing (fleet-store-query1 store "SELECT * FROM artifacts WHERE task_id = ? AND kind = ? AND COALESCE(rel_path, '') = ? AND COALESCE(external_ref, '') = ?"
                                        task-id kind (or rel "") (or (plist-get a :external-ref) ""))))
      (if existing
          (progn
            (fleet-store-update store "artifacts" (plist-get existing :id)
                                (fleet-store-touch (list :description (or (plist-get a :description) (plist-get existing :description))
                                                         :expected-identity (or (plist-get a :expected-identity) (plist-get existing :expected-identity)))))
            (plist-get existing :id))
        (let ((id (fleet-paths-uuid)))
          (fleet-store-insert store "artifacts"
                              (list :id id :task-id task-id :kind kind
                                    :rel-path (plist-get a :rel-path) :external-ref (plist-get a :external-ref)
                                    :description (plist-get a :description) :expected-identity (plist-get a :expected-identity)
                                    :created-at now :updated-at now))
          id)))))

(cl-defun fleet-core-artifact-register (store &key runtime-id task-id kind rel-path external-ref description expected-identity)
  "Register a named artifact for TASK-ID from RUNTIME-ID (operator: own task only)."
  (let* ((rt (fleet-core-runtime-authorized store runtime-id (and (equal (plist-get (fleet-store-get store "runtimes" runtime-id) :role) "operator") task-id)))
         (tid (or task-id (plist-get rt :task-id))))
    (let (aid)
      (fleet-store-transaction store
        (setq aid (fleet-core--register-artifact store tid (list :kind kind :rel-path rel-path :external-ref external-ref
                                                                 :description description :expected-identity expected-identity)))
        (fleet-store-append-event store :fleet-id (plist-get rt :fleet-id) :task-id tid :runtime-id runtime-id
                                  :kind "artifact-registered"
                                  :payload (list :artifact-id aid :kind kind :rel-path (plist-get (fleet-store-get store "artifacts" aid) :rel-path)
                                                 :external-ref external-ref)))
      (list :ok t :task-id tid :artifact-id aid :rel-path (plist-get (fleet-store-get store "artifacts" aid) :rel-path)))))

(cl-defun fleet-core-artifact-verify (store &key artifact-id actor criteria evidence accepted limitations)
  "Record verification of ARTIFACT-ID by ACTOR (commander/human).
The verification is bound to the current brief and content digest: a file's
bytes, or the tree digest of a directory (`fleet-paths-sha256-path')."
  (let* ((art (or (fleet-store-get store "artifacts" artifact-id) (fleet-fail 'no-such-artifact "Unknown artifact" :id artifact-id)))
         (task (fleet-store-get store "tasks" (plist-get art :task-id)))
         (rel (plist-get art :rel-path))
         (file (and rel (fleet-core-artifact-file store task rel)))
         (hash (and file (fleet-paths-sha256-path file))))
    (when (and rel (not hash))
      (fleet-fail 'artifact-missing "Artifact path does not exist; verification refused"
                  :rel-path rel :looked-at (mapcar #'cdr (fleet-core-artifact-candidates store task rel))))
    (fleet-store-transaction store
      (fleet-store-update store "artifacts" artifact-id
                          (fleet-store-touch (list :verified (if accepted 1 0) :verified-brief-revision (plist-get task :brief-revision)
                                                   :verified-hash (or hash (plist-get art :expected-identity)) :verified-by actor
                                                   :verification-evidence (fleet-store-json (list :criteria criteria :evidence evidence :limitations limitations)))))
      (fleet-store-append-event store :fleet-id (plist-get task :fleet-id) :task-id (plist-get task :id)
                                :kind (if accepted "artifact-verified" "artifact-rejected") :actor actor
                                :payload (list :artifact-id artifact-id :hash hash :brief-revision (plist-get task :brief-revision))))
    (list :ok t :verified (and accepted t) :hash hash)))

(defun fleet-core-task-verified-p (store task)
  "Non-nil when TASK is done and every artifact is verified.
Verification must be at the current brief revision and content digest; a
path that became unreadable or empty since verification counts as changed."
  (and (equal (plist-get task :phase) "done")
       (let ((arts (fleet-store-query store "SELECT * FROM artifacts WHERE task_id = ?" (plist-get task :id))))
         (and arts
              (cl-every (lambda (a)
                          (and (eql 1 (plist-get a :verified))
                               (eql (plist-get a :verified-brief-revision) (plist-get task :brief-revision))
                               (or (null (plist-get a :rel-path))
                                   (equal (plist-get a :verified-hash)
                                          (condition-case nil
                                              (when-let* ((file (fleet-core-artifact-file store task (plist-get a :rel-path))))
                                                (fleet-paths-sha256-path file))
                                            (fleet-error nil))))))
                        arts)))))

(cl-defun fleet-core-decision-resolve (store &key decision-id answer actor authority expected-revision evidence)
  "Resolve DECISION-ID with ANSWER by ACTOR holding AUTHORITY (commander/human)."
  (let* ((d (or (fleet-store-get store "decisions" decision-id) (fleet-fail 'no-such-decision "Unknown decision" :id decision-id)))
         (task (fleet-store-get store "tasks" (plist-get d :task-id))))
    (unless (equal (plist-get d :state) "open") (fleet-fail 'decision-closed "Decision already resolved" :state (plist-get d :state)))
    (when (and (equal (plist-get d :authority) "human") (not (equal authority "human")))
      (fleet-fail 'forbidden "This decision requires human authority" :decision-id decision-id))
    (fleet-store-check-revision store "tasks" (plist-get task :id) expected-revision)
    (fleet-store-transaction store
      (fleet-store-update store "decisions" decision-id (fleet-store-touch (list :state "resolved" :answer answer :resolved-by actor :evidence (and evidence (fleet-store-json evidence)))))
      (fleet-store-append-event store :fleet-id (plist-get d :fleet-id) :task-id (plist-get d :task-id) :kind "decision-resolved" :actor actor
                                :payload (list :decision-id decision-id :answer answer :authority authority)))
    (list :ok t :decision-id decision-id :task-id (plist-get d :task-id))))

(cl-defun fleet-core-external-job (store &key runtime-id job-id system job-ref state completion-source deadline cancel-policy disposition)
  "Register or update an external job for RUNTIME-ID's task.
An existing JOB-ID is updated only when the row belongs to the caller's task
and fleet; any other job is refused with `forbidden' before any mutation, so
one operator cannot rewrite another task's record by supplying its id."
  (let* ((rt (fleet-core-runtime-authorized store runtime-id))
         (tid (plist-get rt :task-id)) (now (fleet-paths-now))
         (existing (and job-id (fleet-store-get store "external_jobs" job-id)))
         (id (or job-id (fleet-paths-uuid))))
    (unless (member state '("running" "completed" "failed" "cancelled" "unknown")) (fleet-fail 'invalid-job "Unknown job state" :state state))
    (when (and existing
               (not (and (equal (plist-get existing :task-id) tid)
                         (equal (plist-get existing :fleet-id) (plist-get rt :fleet-id)))))
      (fleet-fail 'forbidden "External job belongs to another task" :job-id job-id :task-id tid))
    (fleet-store-transaction store
      (if existing
          (fleet-store-update store "external_jobs" id (fleet-store-touch (list :state state :disposition disposition :deadline (or deadline (plist-get existing :deadline)))))
        (unless (and system job-ref) (fleet-fail 'invalid-job "New jobs need :system and :job-ref"))
        (fleet-store-insert store "external_jobs"
                            (list :id id :fleet-id (plist-get rt :fleet-id) :task-id tid :runtime-id runtime-id :system system :job-ref job-ref
                                  :state state :completion-source completion-source :deadline deadline :cancel-policy cancel-policy
                                  :disposition disposition :created-at now :updated-at now)))
      (fleet-store-append-event store :fleet-id (plist-get rt :fleet-id) :task-id tid :runtime-id runtime-id :kind "external-job"
                                :payload (list :job-id id :state state :system system)))
    (list :ok t :job-id id)))

(defun fleet-core-expire-waits (store)
  "Emit one wait-deadline-expired event per paused task whose deadline passed.
Return the count of emitted events."
  (let ((now (fleet-paths-now)) (n 0))
    (dolist (task (fleet-store-query store "SELECT * FROM tasks WHERE phase = 'paused' AND wait_deadline IS NOT NULL AND wait_deadline <= ? AND lifecycle = 'active'" now))
      (fleet-store-transaction store
        (fleet-store-update store "tasks" (plist-get task :id)
                            (fleet-store-touch (list :detail (format "wait expired: %s" (plist-get task :wait-reason)) :detail-at now :wait-deadline nil)))
        (fleet-store-append-event store :fleet-id (plist-get task :fleet-id) :task-id (plist-get task :id) :kind "wait-deadline-expired"
                                  :payload (list :reason (plist-get task :wait-reason) :job-id (plist-get task :wait-job-id)) :actionable t))
      (cl-incf n))
    n))

;;;; Operations journal

(cl-defun fleet-core-operation-begin (store kind &key fleet-id task-id runtime-id intent expected-revision)
  "Insert a running operation of KIND at step \"admitted\"; return its id."
  (let ((id (fleet-paths-uuid)) (now (fleet-paths-now)))
    (fleet-store-transaction store
      (fleet-store-insert store "operations"
                          (list :id id :kind kind :fleet-id fleet-id :task-id task-id :runtime-id runtime-id
                                :expected-revision expected-revision :step "admitted" :state "running"
                                :intent (and intent (fleet-store-json intent)) :owner-epoch (ignore-errors (fleet-core-owner-epoch))
                                :created-at now :updated-at now)))
    id))

(defun fleet-core-operation-step (store op-id step &optional evidence)
  "Persist STEP (and merged EVIDENCE plist) for OP-ID."
  (fleet-store-transaction store
    (let* ((op (fleet-store-get store "operations" op-id))
           (old (fleet-store-unjson (plist-get op :evidence))))
      (fleet-store-update store "operations" op-id
                          (fleet-store-touch (list :step step :evidence (fleet-store-json (fleet-core--merge-plist old evidence))))))))

(cl-defun fleet-core-operation-finish (store op-id &key state error evidence)
  "Finish OP-ID with STATE (done/failed/blocked), ERROR text and EVIDENCE."
  (fleet-store-transaction store
    (let* ((op (fleet-store-get store "operations" op-id))
           (old (fleet-store-unjson (plist-get op :evidence))))
      (fleet-store-update store "operations" op-id
                          (fleet-store-touch (list :state state :error error :step (if (equal state "done") "done" (plist-get op :step))
                                                   :evidence (fleet-store-json (fleet-core--merge-plist old evidence)))))
      (unless (equal state "done")
        (fleet-store-append-event store :fleet-id (plist-get op :fleet-id) :task-id (plist-get op :task-id) :runtime-id (plist-get op :runtime-id)
                                  :kind "operation-failed" :operation-id op-id
                                  :payload (list :kind (plist-get op :kind) :step (plist-get op :step) :error error) :actionable t)))))

(defun fleet-core--merge-plist (old new)
  "Return OLD plist with NEW's keys replacing or appended."
  (let ((out (copy-sequence old)))
    (cl-loop for (k v) on new by #'cddr do (setq out (plist-put out k v)))
    out))

(defun fleet-core-operation (store op-id) "Operation row OP-ID or nil." (fleet-store-get store "operations" op-id))

(defun fleet-core-task-operation-running-p (store task-id)
  "Non-nil when TASK-ID has a running lifecycle operation."
  (> (fleet-store-scalar store "SELECT COUNT(*) FROM operations WHERE task_id = ? AND state = 'running' AND kind <> 'brief-publish'" task-id) 0))

(defconst fleet-core--open-failed-operations-sql
  "SELECT o.* FROM operations o
     LEFT JOIN tasks t ON t.id = o.task_id
     LEFT JOIN fleets f ON f.id = o.fleet_id
    WHERE o.state = 'failed'
      AND COALESCE(t.lifecycle, '') <> 'archived'
      AND COALESCE(f.lifecycle, '') <> 'archived'
      AND NOT EXISTS (SELECT 1 FROM operations o2
                       WHERE o2.kind = o.kind AND o2.state = 'done'
                         AND o2.created_at > o.created_at
                         AND COALESCE(o2.task_id, '') = COALESCE(o.task_id, '')
                         AND COALESCE(o2.fleet_id, '') = COALESCE(o.fleet_id, ''))
    ORDER BY o.updated_at DESC"
  "Failed operations that still describe something unresolved.")

(defun fleet-core-open-failed-operations (store)
  "Failed operations of STORE that are still worth a human's attention.
A failure is superseded, and so omitted, once a later operation of the
same kind on the same task (or fleet) reached `done', or the task or fleet
it belonged to is archived.  The rows stay in the journal as history; this
only decides what doctor and dashboards should keep raising."
  (fleet-store-query store fleet-core--open-failed-operations-sql))

;;;; Runtimes: launch and stop primitives

(defun fleet-core--credential (runtime-id)
  "Write a fresh credential file for RUNTIME-ID; return (FILE . HASH)."
  (let* ((token (concat (fleet-paths-uuid) (fleet-paths-uuid)))
         (file (fleet-paths-credential-file runtime-id)))
    (fleet-paths-ensure-dir (fleet-paths-credentials-dir) #o700)
    (fleet-paths-write-atomically file (fleet-store-json (list :runtimeId runtime-id :token token)) #o600)
    (cons file (fleet-paths-sha256-string token))))

(defun fleet-core-revoke-credential (store runtime-id)
  "Revoke RUNTIME-ID's credential durably and remove its file."
  (fleet-store-transaction store
    (fleet-store-update store "runtimes" runtime-id (fleet-store-touch (list :credential-revoked 1))))
  (ignore-errors (delete-file (fleet-paths-credential-file runtime-id))))

(cl-defun fleet-core--new-runtime (store &key role fleet-id task-id model agent variant)
  "Insert a launching runtime row; return it."
  (let* ((id (fleet-paths-uuid)) (now (fleet-paths-now)) (cred (fleet-core--credential id)))
    (fleet-store-transaction store
      (fleet-store-insert store "runtimes"
                          (list :id id :owner-epoch (fleet-core-owner-epoch) :role role :fleet-id fleet-id :task-id task-id
                                :unit (fleet-runtime-unit-name id) :boot-id (fleet-paths-boot-id)
                                :model model :agent agent :variant variant :lifecycle "launching"
                                :credential-hash (cdr cred) :connection-state "connecting" :created-at now :updated-at now)))
    (fleet-store-get store "runtimes" id)))

(defun fleet-core-runtime-display-name (store rt)
  "Presentation name for runtime RT."
  (let ((fleet (fleet-store-get store "fleets" (plist-get rt :fleet-id))))
    (if (equal (plist-get rt :role) "commander")
        (format "*eca:%s:%s*" (fleet-core-effective-role store rt) (fleet-core-fleet-selector store fleet))
      (format "*eca:operator:%s:%s*" (fleet-core-fleet-selector store fleet)
              (plist-get (fleet-store-get store "tasks" (plist-get rt :task-id)) :name)))))

(defun fleet-core--run-dir (store rt)
  "Run directory for runtime RT."
  (let ((fleet (fleet-store-get store "fleets" (plist-get rt :fleet-id))))
    (fleet-paths-run-dir (if (equal (plist-get rt :role) "commander")
                             (expand-file-name "commander" (plist-get fleet :artifact-root))
                           (expand-file-name (concat "tasks/" (plist-get rt :task-id)) (plist-get fleet :artifact-root)))
                         (plist-get rt :id))))

(defun fleet-core-role-disabled-tools (role)
  "Native ECA tools disabled for runtimes of effective ROLE.
Every runtime loses `eca__spawn_agent': a subagent would inherit the runtime
credential (design §5.3).  Operators and lieutenants also lose
`eca__ask_user': that tool parks the turn on a human-only `chat/askQuestion'
that the supervising runtime cannot answer, so messages queue behind it
unseen.  The operator channel for questions is `fleet_status' phase
`needs-decision'; the lieutenant channel is `fleet_report' kind `question';
both end the turn and wake the supervisor (implementation note 12).  The
commander keeps `eca__ask_user' because its questions are for the human."
  (if (equal role "commander")
      (vector "eca__spawn_agent")
    (vector "eca__spawn_agent" "eca__ask_user")))

(defun fleet-core--role-config-overlay (role)
  "ECA_CONFIG overlay for ROLE, deep-merged over the user's ordinary config.
Carries the Fleet MCP entry (so ordinary sessions never see the bridge) and
the role's disabled native tools; see `fleet-core-role-disabled-tools'."
  (fleet-store-json
   (list :mcpServers (list :fleet (list :command fleet-python-executable
                                        :args (vector (fleet-paths-bridge-executable) "mcp")))
         :disabledTools (fleet-core-role-disabled-tools role))))

(cl-defun fleet-core-launch-runtime (store rt &key roots cwd callback)
  "Launch runtime row RT as a systemd user service running native ECA.
CALLBACK gets (:ok t :conn) or (:ok nil :error).
Records launch.json and the exact unit before calling systemd."
  (let* ((id (plist-get rt :id))
         (unit (plist-get rt :unit))
         (run-dir (fleet-paths-ensure-dir (fleet-core--run-dir store rt)))
         (cache (fleet-paths-ensure-dir (fleet-paths-eca-cache-dir id)))
         (server (or (fleet-eca-server-command) (fleet-fail 'unsupported-eca-contract "No native ECA executable")))
         (env (list (cons "FLEET_SOCKET" (fleet-paths-socket))
                    (cons "FLEET_CREDENTIAL_FILE" (fleet-paths-credential-file id))
                    (cons "FLEET_RUNTIME_ID" id)
                    (cons "XDG_CACHE_HOME" cache)
                    (cons "ECA_CONFIG" (fleet-core--role-config-overlay (fleet-core-effective-role store rt)))))
         (setenv (append (mapcar #'car env) (fleet-runtime-selected-variables)))
         (command (fleet-runtime-wrapper-argv unit server :cwd cwd :setenv (cl-remove-duplicates setenv :test #'string=))))
    (fleet-paths-write-atomically (expand-file-name "launch.json" run-dir)
                                  (fleet-store-json (fleet-runtime-launch-record id unit command cwd setenv)))
    (fleet-store-transaction store
      (fleet-store-update store "runtimes" id (fleet-store-touch (list :launch-evidence (fleet-store-json (list :unit unit :cwd cwd :roots (vconcat roots) :launched-at (fleet-paths-now)))))))
    (fleet-eca-start
     :runtime-id id :owner-epoch (plist-get rt :owner-epoch) :role (plist-get rt :role)
     :fleet-id (plist-get rt :fleet-id) :task-id (plist-get rt :task-id)
     :display-name (fleet-core-runtime-display-name store rt)
     :command command :roots roots :cwd cwd :environment env
     :model (plist-get rt :model) :agent (plist-get rt :agent) :variant (plist-get rt :variant)
     :transcript-file (expand-file-name "transcript.jsonl" run-dir)
     :sink #'fleet-core--emit
     :callback
     (lambda (r)
       (if (plist-get r :ok)
           (let ((conn (plist-get r :conn)))
             (fleet-store-transaction store
               (fleet-store-update store "runtimes" id (fleet-store-touch (list :lifecycle "ready" :connection-state "ready" :turn-state "idle"
                                                                              :chat-id (fleet-eca-conn-chat-id conn)
                                                                              ;; Effective values: a nil request resolved to the server default.
                                                                              :model (fleet-eca-conn-model conn)
                                                                              :variant (fleet-eca-conn-variant conn)
                                                                              :main-pid (and (fleet-eca-conn-process conn) (process-id (fleet-eca-conn-process conn)))))))
             ;; Capture the unit's identity once systemd has it; asynchronous and non-blocking.
             (fleet-runtime-inspect unit nil
                                    (lambda (insp)
                                      (when (plist-get insp :query-ok)
                                        (ignore-errors
                                          (fleet-store-transaction store
                                            (fleet-store-update store "runtimes" id
                                                                (fleet-store-touch (list :control-group (plist-get insp :control-group)
                                                                                         :invocation-id (plist-get insp :invocation-id)))))))))
             (funcall callback r))
         (fleet-store-transaction store
           (fleet-store-update store "runtimes" id (fleet-store-touch (list :lifecycle "lost" :connection-state "lost"
                                                                          :stop-evidence (fleet-store-json (list :error (plist-get r :error)))))))
         (funcall callback r))))))

(cl-defun fleet-core-stop-runtime (store runtime-id &key reason callback)
  "Stop RUNTIME-ID's service with the full evidence sequence.
CALLBACK gets (:verdict SYM :inspection PLIST).
Persists stop intent, revokes the credential, requests graceful cancel,
stops the exact unit, inspects until terminal, and commits the verdict.
Never marks stopped without proof."
  (let* ((rt (fleet-store-get store "runtimes" runtime-id))
         (conn (fleet-eca-conn runtime-id))
         (op (fleet-core-operation-begin store "runtime-stop" :fleet-id (plist-get rt :fleet-id) :task-id (plist-get rt :task-id)
                                         :runtime-id runtime-id :intent (list :reason reason))))
    (fleet-store-transaction store
      (fleet-store-update store "runtimes" runtime-id (fleet-store-touch (list :lifecycle "stopping"))))
    (fleet-core-revoke-credential store runtime-id)
    (when conn (ignore-errors (fleet-eca-request-cancel conn)))
    (fleet-core-operation-step store op "service-stop-requested")
    (fleet-runtime-stop
     (plist-get rt :unit) (plist-get rt :control-group) (plist-get rt :boot-id)
     (lambda (r)
       (let* ((verdict (plist-get r :verdict))
              (lifecycle (pcase verdict ((or 'stopped 'never-launched 'previous-boot) "stopped") (_ "stop-unknown"))))
         (fleet-store-transaction store
           (fleet-store-update store "runtimes" runtime-id
                               (fleet-store-touch (list :lifecycle lifecycle :connection-state "lost"
                                                        :stop-evidence (fleet-store-json (list :verdict verdict :inspection (plist-get r :inspection)
                                                                                               :stop-exit (plist-get r :stop-exit) :reason reason)))))
           (if (equal lifecycle "stopped")
               (fleet-core-operation-finish store op :state "done" :evidence (list :verdict verdict))
             (fleet-core-operation-finish store op :state "failed" :error (format "runtime stop verdict: %s" verdict)
                                          :evidence (list :verdict verdict :inspection (plist-get r :inspection)))))
         (when conn (fleet-eca-detach conn))
         (funcall callback (list :verdict verdict :lifecycle lifecycle :inspection (plist-get r :inspection) :operation-id op)))))))

;;;; Boot payloads

(defun fleet-core--prompt (name) "Canonical prompt NAME text." (or (fleet-paths-read-file (fleet-paths-prompt-file name)) (fleet-fail 'prompt-missing "Prompt file missing" :name name)))

(defun fleet-core--lieutenants-section (store fleet)
  "Boot-message section listing FLEET's lieutenants with charters, or nil."
  (when-let* ((lts (fleet-core-lieutenants store (plist-get fleet :id))))
    (concat "\n## Lieutenants\n"
            "Each owns a domain of this project with its own operators and context. Route work to the lieutenant whose charter it falls under with `fleet_delegate` (a complete brief, as for an operator); it reports back through `lieutenant-report` events (`question`, `progress`, `settled`). Verify a settled request's evidence before telling the user. Do not create operators for work a charter covers, and do not manage a lieutenant's operators yourself.\n"
            (mapconcat (lambda (lt)
                         (let* ((rt (and (plist-get lt :commander-runtime-id) (fleet-store-get store "runtimes" (plist-get lt :commander-runtime-id))))
                                (open (fleet-store-scalar store "SELECT COUNT(*) FROM requests WHERE child_fleet_id = ? AND state = 'open'" (plist-get lt :id))))
                           (format "- `%s` (fleet id `%s`): %s\n  runtime %s · %d open request(s)\n"
                                   (plist-get lt :name) (plist-get lt :id) (plist-get lt :charter)
                                   (if rt (plist-get rt :lifecycle) "none") open)))
                       lts ""))))

(defun fleet-core-commander-boot-payload (store fleet rt &optional recovery-summary)
  "Self-contained boot message for a commander runtime RT of FLEET.
A lieutenant (FLEET has a parent) gets the commander doctrine plus the
lieutenant overlay and its charter; a root gets its lieutenants listed."
  (let* ((root (plist-get fleet :artifact-root))
         (parent (and (plist-get fleet :parent-id) (fleet-store-get store "fleets" (plist-get fleet :parent-id))))
         (snap (fleet-store-snapshot store (plist-get fleet :id))))
    (concat (fleet-core--prompt "commander")
            (when parent (concat "\n\n" (fleet-core--prompt "lieutenant")))
            "\n\n## Your fleet\n"
            (format "- Fleet: `%s` (id `%s`)\n- Runtime: `%s`\n- Artifact root: `%s`\n- Project context: `%s`\n- Handoff note: `%s`\n"
                    (fleet-core-fleet-selector store fleet) (plist-get fleet :id) (plist-get rt :id) root
                    (expand-file-name "about.md" root) (expand-file-name "commander/context.md" root))
            "- Fleet tools are available as MCP tools named `fleet_*`; they are scoped to this fleet.\n"
            (when parent
              (format "- You are the lieutenant `%s` of fleet `%s` (id `%s`); its commander is your user.\n\n## Your charter\n%s\n"
                      (plist-get fleet :name) (plist-get parent :name) (plist-get parent :id) (plist-get fleet :charter)))
            (unless parent (fleet-core--lieutenants-section store fleet))
            (fleet-core--models-section store rt)
            (when recovery-summary (concat "\n## Recovery summary\n" recovery-summary "\n"))
            "\n## Current snapshot\n```json\n" (fleet-store-json (fleet-core--compact-snapshot snap)) "\n```\n"
            (let ((about (fleet-paths-read-file (expand-file-name "about.md" root))))
              (when about (concat "\n## about.md\n" about)))
            (let ((ctx (fleet-paths-read-file (expand-file-name "commander/context.md" root))))
              (when ctx (concat "\n## commander/context.md\n" ctx))))))

(defun fleet-core--models-section (store rt)
  "Boot-message section listing the ECA model catalog, for commander RT.
The catalog is what any runtime last announced (durable in the store); the
commander needs it to turn casual model names into exact ids."
  (let* ((cat (fleet-store-eca-catalog store))
         (models (plist-get cat :models))
         ;; Re-read: the row carries the effective model once the connection is ready.
         (rt (or (fleet-store-get store "runtimes" (plist-get rt :id)) rt))
         ;; A broken policy file must not stop the commander from booting; it
         ;; is reported here and refuses task creation until fixed.
         (policy-error nil)
         (policy (condition-case err (fleet-core-model-policy)
                   (fleet-error (setq policy-error (fleet-error-string err)) nil)))
         (default (if policy-error (cons fleet-operator-model fleet-operator-variant)
                    (fleet-core-operator-default store policy))))
    (concat "\n## Models\n"
            (format "- You run on `%s`%s.\n" (or (plist-get rt :model) "the ECA default")
                    (if (plist-get rt :variant) (format " (variant `%s`)" (plist-get rt :variant)) ""))
            (format "- Operator default: `%s`%s (used when neither the user nor a policy rule chooses).\n"
                    (or (car default) (plist-get cat :default-model) "the ECA default")
                    (if (cdr default) (format " variant `%s`" (cdr default)) ""))
            (when (plist-get cat :variants)
              (format "- Variants announced for the default model: %s.\n" (string-join (plist-get cat :variants) ", ")))
            (if models
                (format "- Catalog (%d exact ids; `fleet_task_create` accepts only these):\n  %s\n"
                        (length models) (string-join models ", "))
              "- Catalog not announced yet; `model` overrides are passed to ECA unchecked.\n")
            "\n### Operator model policy\n"
            (cond
             (policy-error (format "- The owner's policy file could not be loaded; task creation is refused until it is fixed: %s\n" policy-error))
             (policy
              (concat (fleet-policy-describe policy)
                      (when-let* ((missing (and models (cl-set-difference (fleet-policy-models policy) models :test #'equal))))
                        (format "- Policy ids the catalog does not offer (Fleet will refuse them; use the next in the chain and tell the user, they may be typos): %s.\n"
                                (mapconcat (lambda (m) (format "`%s`" m)) missing ", ")))))
             (t (format "- No owner policy file (`%s`); every task without an explicit `model` gets the operator default.\n"
                        (fleet-config-file)))))))

(defun fleet-core--compact-snapshot (snap)
  "Reduce SNAP to the fields a model needs."
  (list :revision (plist-get snap :revision)
        :fleets (mapcar (lambda (f)
                          (list :name (plist-get f :name) :lifecycle (plist-get f :lifecycle) :supervision (plist-get f :supervision)
                                :pending-events (plist-get f :pending-events)
                                :open-requests (mapcar (lambda (r) (list :id (plist-get r :id) :subject (plist-get r :subject)
                                                                         :parent-fleet-id (plist-get r :parent-fleet-id) :child-fleet-id (plist-get r :child-fleet-id)
                                                                         :created-at (plist-get r :created-at)))
                                                       (plist-get f :open-requests))
                                :tasks (mapcar (lambda (task)
                                                 (list :id (plist-get task :id) :name (plist-get task :name) :kind (plist-get task :kind)
                                                       :lifecycle (plist-get task :lifecycle) :phase (plist-get task :phase) :detail (plist-get task :detail)
                                                       :brief-revision (plist-get task :brief-revision) :entity-revision (plist-get task :entity-revision)
                                                       :workspace (plist-get task :workspace-path) :branch (plist-get task :branch)
                                                       :delivery (plist-get task :delivery-mode)
                                                       :runtime (and (plist-get task :runtime) (plist-get (plist-get task :runtime) :lifecycle))
                                                       :open-decisions (mapcar (lambda (d) (list :id (plist-get d :id) :question (plist-get d :question))) (plist-get task :decisions))
                                                       :artifacts (mapcar (lambda (a) (list :id (plist-get a :id) :kind (plist-get a :kind) :path (plist-get a :rel-path) :verified (plist-get a :verified))) (plist-get task :artifacts))))
                                               (plist-get f :tasks))))
                        (plist-get snap :fleets))))

(defun fleet-core-operator-boot-payload (store task rt)
  "Self-contained boot message for operator runtime RT of TASK."
  (let* ((dir (fleet-core-task-dir store task))
         (brief (fleet-paths-read-file (fleet-core-brief-file store task)))
         (progress (fleet-paths-read-file (expand-file-name "progress.md" dir))))
    (concat (fleet-core--prompt "operator")
            "\n\n" (fleet-core--prompt (plist-get task :kind))
            "\n\n## Your task\n"
            (format "- Task: `%s` (id `%s`), kind `%s`, brief revision %d\n- Runtime: `%s`\n- Workspace: `%s`\n- Progress file: `%s`\n- Report file: `%s`\n- Artifacts dir: `%s`\n"
                    (plist-get task :name) (plist-get task :id) (plist-get task :kind) (plist-get task :brief-revision) (plist-get rt :id)
                    (or (plist-get task :workspace-path) dir) (expand-file-name "progress.md" dir) (expand-file-name "report.md" dir)
                    (expand-file-name "artifacts" dir))
            (when (equal (plist-get task :kind) "change")
              (format "- Repository: `%s`\n- Branch: `%s` (ownership %s)\n- Base: `%s` = `%s`\n- Remote/target: `%s`/`%s`\n- Delivery mode: `%s`\n"
                      (plist-get task :repo-path) (plist-get task :branch) (plist-get task :branch-ownership)
                      (plist-get task :base-ref) (plist-get task :base-oid) (plist-get task :remote) (plist-get task :target-ref) (plist-get task :delivery-mode)))
            "\n## Brief (immutable revision)\n" (or brief "(brief missing — stop and report blocked)")
            "\n\n## Prior progress\n" (or progress "(none)") "\n")))

;;;; Operation: task-start

(cl-defun fleet-core-start-task (store task-id &key expected-revision actor action-id callback)
  "Admit and run the task-start operation for TASK-ID; return its operation id.
CALLBACK, when given, receives the finished operation row."
  (fleet-store-with-action store (or actor fleet-core-actor-human) action-id (list :op "task-start" :task-id task-id :expected-revision expected-revision)
    (let* ((task (fleet-core-task store task-id))
           (fleet (fleet-store-get store "fleets" (plist-get task :fleet-id))))
      (fleet-store-check-revision store "tasks" task-id expected-revision)
      (unless (equal (plist-get fleet :lifecycle) "active")
        (fleet-fail 'fleet-not-active "Fleet is not active; resume it first" :lifecycle (plist-get fleet :lifecycle)))
      (unless (member (plist-get task :lifecycle) '("ready" "suspended"))
        (fleet-fail 'task-not-startable "Task is not ready or suspended" :lifecycle (plist-get task :lifecycle)))
      (when (fleet-core-task-operation-running-p store task-id)
        (fleet-fail 'operation-in-progress "Another lifecycle operation is running for this task"))
      (unless (fleet-core-brief-runnable-p store task)
        (fleet-fail 'brief-not-runnable "Brief revision file missing or hash mismatch"))
      (when-let* ((rt (and (plist-get task :current-runtime-id) (fleet-store-get store "runtimes" (plist-get task :current-runtime-id)))))
        (unless (member (plist-get rt :lifecycle) '("stopped" "never-launched"))
          (fleet-fail 'runtime-not-stopped "Predecessor runtime is not proven stopped" :runtime-id (plist-get rt :id) :lifecycle (plist-get rt :lifecycle))))
      (dolist (dep (fleet-store-query store "SELECT d.depends_on_id, t.phase, t.brief_revision, t.name FROM task_dependencies d JOIN tasks t ON t.id = d.depends_on_id WHERE d.task_id = ?" task-id))
        (let ((dep-task (fleet-store-get store "tasks" (plist-get dep :depends-on-id))))
          (unless (fleet-core-task-verified-p store dep-task)
            (fleet-fail 'dependency-unsatisfied "Prerequisite is not verified done at its recorded brief revision"
                        :dependency (plist-get dep :name) :phase (plist-get dep :phase)))))
      (fleet-core-owner-epoch)
      (fleet-eca-assert-supported)
      (let ((op (fleet-core-operation-begin store "task-start" :fleet-id (plist-get fleet :id) :task-id task-id
                                            :expected-revision (plist-get task :entity-revision)
                                            :intent (list :brief-revision (plist-get task :brief-revision)))))
        (fleet-store-transaction store
          (fleet-store-update store "tasks" task-id (fleet-store-touch (list :detail "starting" :detail-at (fleet-paths-now)))))
        (fleet-core--task-start-workspace store op task callback)
        (list :operation-id op :task-id task-id)))))

(defun fleet-core--task-start-workspace (store op task callback)
  "Step: ensure the workspace exists for TASK, then launch.
The workspace is created or adopted as a worktree."
  (let ((tid (plist-get task :id)))
    (cl-flet* ((fail (code msg &rest ev)
                 (fleet-store-transaction store
                   (fleet-store-update store "tasks" tid (fleet-store-touch (list :detail (format "start failed: %s" msg) :detail-at (fleet-paths-now))))
                   (fleet-core-operation-finish store op :state "failed" :error (format "%s: %s" code msg) :evidence ev))
                 (when callback (funcall callback (fleet-store-get store "operations" op))))
               (proceed (workspace)
                 ;; Claims and launch may refuse; a refusal inside an async callback
                 ;; must land in the operation journal, not in a lost signal.
                 (condition-case err
                     (progn
                       (fleet-core--claim-workspace store (fleet-store-get store "tasks" tid) workspace op)
                       (fleet-core-operation-step store op "workspace-ready" (list :workspace workspace))
                       (fleet-core--task-start-launch store op (fleet-store-get store "tasks" tid) workspace callback))
                   (fleet-error (fail (fleet-error-code err) (fleet-error-message err) :evidence (fleet-error-evidence err)))
                   (error (fail 'error (error-message-string err))))))
      (pcase (plist-get task :kind)
        ("change"
         (let ((repo (plist-get task :repo-path)))
           (fleet-git-repo-identity
            repo
            (lambda (rid)
              (cond
               ((plist-get rid :error) (fail 'workspace-uninspectable (plist-get rid :error)))
               ((and (plist-get task :workspace-path) (equal (plist-get task :workspace-ownership) "adopted"))
                (fleet-git-adopt-worktree
                 :repo repo :path (plist-get task :workspace-path)
                 :callback (lambda (r)
                             (if (not (plist-get r :ok)) (fail (plist-get r :code) (plist-get r :error))
                               (fleet-core--record-workspace store tid rid (plist-get r :identity) (plist-get (plist-get r :entry) :branch) "adopted" "adopted")
                               (proceed (plist-get (plist-get r :identity) :toplevel))))))
               ((and (plist-get task :workspace-path) (file-directory-p (plist-get task :workspace-path)))
                ;; Fleet-owned worktree from a previous incarnation: revalidate identity, reuse.
                (fleet-git-repo-identity (plist-get task :workspace-path)
                                         (lambda (wid)
                                           (if (or (plist-get wid :error) (not (equal (plist-get wid :common-dir) (plist-get rid :common-dir))))
                                               (fail 'workspace-changed "Recorded worktree no longer belongs to the repository")
                                             (proceed (plist-get wid :toplevel))))))
               (t (fleet-core--create-change-workspace store task rid #'fail #'proceed)))))))
        (_
         (let ((dir (fleet-paths-ensure-dir (expand-file-name "workspace" (fleet-core-task-dir store task)))))
           (fleet-store-transaction store
             (fleet-store-update store "tasks" tid (fleet-store-touch (list :workspace-path (fleet-paths-canonical dir) :workspace-ownership "fleet"))))
           (proceed (fleet-paths-canonical dir))))))))

(defun fleet-core--create-change-workspace (store task rid fail proceed)
  "Resolve base/remote/branch for TASK against repository identity RID.
Then create or adopt the worktree."
  (let* ((tid (plist-get task :id)) (repo (plist-get task :repo-path))
         (fleet (fleet-store-get store "fleets" (plist-get task :fleet-id))))
    (fleet-git-remotes
     repo
     (lambda (remotes)
       (let ((remote (fleet-core-pick-remote remotes)))
         (fleet-git-default-branch
          repo remote
          (lambda (default)
            (let ((base-ref (or (plist-get task :base-ref) (and default remote (format "%s/%s" remote default)) default)))
              (if (null base-ref)
                  (funcall fail 'base-unresolved "Cannot determine a base ref: specify base_ref explicitly" :remotes (vconcat remotes))
                (fleet-git-resolve-commit
                 repo base-ref
                 (lambda (base-oid)
                   (if (null base-oid)
                       (funcall fail 'base-unresolved (format "Base ref %s does not resolve to a commit" base-ref))
                     (let* ((branch (or (plist-get task :branch) (format "fleet/%s/%s" (plist-get fleet :name) (plist-get task :name))))
                            (path (fleet-paths-worktree-dir (file-name-nondirectory (plist-get rid :toplevel)) (plist-get fleet :name) (plist-get task :name) tid))
                            (finish (lambda (r ownership)
                                      (if (not (plist-get r :ok))
                                          (funcall fail (plist-get r :code) (plist-get r :error))
                                        (fleet-store-transaction store
                                          (fleet-store-update store "tasks" tid (fleet-store-touch (list :base-ref base-ref :base-oid base-oid :remote remote :target-ref default :branch branch))))
                                        (fleet-core--record-workspace store tid rid (plist-get r :identity) branch "fleet" ownership)
                                        (funcall proceed (plist-get (plist-get r :identity) :toplevel))))))
                       (if (equal (plist-get task :branch-ownership) "adopted")
                           (fleet-git-adopt-branch :repo repo :path path :branch branch :callback (lambda (r) (funcall finish r "adopted")))
                         (fleet-git-create-worktree :repo repo :path path :branch branch :base-oid base-oid
                                                    :callback (lambda (r) (funcall finish r "fleet")))))))))))))))))

(defun fleet-core--record-workspace (store tid rid wid branch ws-ownership br-ownership)
  "Persist workspace identity for task TID."
  (fleet-store-transaction store
    (fleet-store-update store "tasks" tid
                        (fleet-store-touch (list :repo-common-dir (plist-get rid :common-dir) :workspace-path (plist-get wid :toplevel)
                                                 :workspace-ownership ws-ownership :branch (or branch (plist-get wid :branch)) :branch-ownership br-ownership)))))

(defun fleet-core--claim-workspace (store task path op)
  "Take the exclusive canonical workspace claim for TASK at PATH.
Signal `resource-claimed' when another task holds it."
  (fleet-store-transaction store
    (let ((existing (fleet-store-query1 store "SELECT * FROM resource_claims WHERE key = ?" path)))
      (cond
       ((null existing)
        (fleet-store-insert store "resource_claims" (list :id (fleet-paths-uuid) :fleet-id (plist-get task :fleet-id) :kind "workspace" :key path
                                                          :task-id (plist-get task :id) :operation-id op :created-at (fleet-paths-now))))
       ((not (equal (plist-get existing :task-id) (plist-get task :id)))
        (fleet-fail 'resource-claimed "Workspace is claimed by another task" :path path :task-id (plist-get existing :task-id)))))))

(defun fleet-core-operator-roots (store task workspace)
  "ECA workspace roots for an operator of TASK working in WORKSPACE.
ECA's native file and shell tools force a manual approval for any path
outside the session's workspace roots, above every `allow' rule (rehearsal
1).  The roots therefore cover everything the brief entitles the operator
to touch without a human: the task directory (progress, report, artifacts
and the Fleet-owned workspace beneath it) and, for study and ops tasks,
the repository they inspect.  A change task's worktree is outside the task
directory and is added as its own root.  Roots also give ECA the
repository's AGENTS.md and @-contexts.  Duplicates and nested paths are
collapsed; order is stable (task dir first) for reproducible launch
evidence."
  (let* ((task-dir (fleet-paths-canonical (fleet-core-task-dir store task)))
         (candidates (delq nil (list task-dir
                                     (and workspace (fleet-paths-canonical workspace))
                                     (and (member (plist-get task :kind) '("study" "ops"))
                                          (plist-get task :repo-path)
                                          (file-directory-p (plist-get task :repo-path))
                                          (fleet-paths-canonical (plist-get task :repo-path))))))
         (roots nil))
    (dolist (c candidates)
      (unless (cl-some (lambda (r) (fleet-paths-contains-p r c)) roots)
        (push c roots)))
    (nreverse roots)))

(defun fleet-core--task-start-launch (store op task workspace callback)
  "Step: create the runtime incarnation, launch it, and submit the boot payload."
  (let* ((tid (plist-get task :id))
         (rt (fleet-core--new-runtime store :role "operator" :fleet-id (plist-get task :fleet-id) :task-id tid
                                      :model (plist-get task :model) :agent fleet-agent :variant (plist-get task :variant))))
    (fleet-store-transaction store
      (fleet-store-update store "tasks" tid (fleet-store-touch (list :current-runtime-id (plist-get rt :id) :lifecycle "active"))))
    (fleet-core-operation-step store op "runtime-launched" (list :runtime-id (plist-get rt :id) :unit (plist-get rt :unit)))
    (condition-case err
        (fleet-core-launch-runtime
         store rt :roots (fleet-core-operator-roots store task workspace) :cwd workspace
         :callback
         (lambda (r)
           (if (not (plist-get r :ok))
               (fleet-core--task-start-fail store op tid rt (plist-get r :error) callback)
             (fleet-core-operation-step store op "connected")
             (fleet-core--boot store op (plist-get r :conn) (fleet-core-operator-boot-payload store (fleet-store-get store "tasks" tid) rt)
                               (lambda (outcome)
                                 (if (memq outcome '(accepted observed-unacknowledged))
                                     (progn
                                       (fleet-store-transaction store
                                         (fleet-store-update store "tasks" tid (fleet-store-touch (list :phase "working" :detail "booted" :detail-at (fleet-paths-now))))
                                         (fleet-store-append-event store :fleet-id (plist-get task :fleet-id) :task-id tid :runtime-id (plist-get rt :id)
                                                                   :kind "task-started" :operation-id op :payload (list :outcome outcome)))
                                       (fleet-core-operation-finish store op :state "done" :evidence (list :boot-outcome outcome))
                                       (when callback (funcall callback (fleet-store-get store "operations" op))))
                                   (fleet-core--task-start-fail store op tid rt (format "boot payload %s" outcome) callback)))))))
      (fleet-error (fleet-core--task-start-fail store op tid rt (fleet-error-string err) callback))
      (error (fleet-core--task-start-fail store op tid rt (error-message-string err) callback)))))

(defun fleet-core--boot (store op conn text callback)
  "Submit boot TEXT on CONN as a durable boot message.
CALLBACK gets the outcome symbol."
  (let ((mid (fleet-paths-uuid)) (now (fleet-paths-now)))
    (fleet-store-transaction store
      (fleet-store-insert store "messages"
                          (list :id mid :sender "fleet" :fleet-id (fleet-eca-conn-fleet-id conn) :task-id (fleet-eca-conn-task-id conn)
                                :target-runtime-id (fleet-eca-conn-runtime-id conn) :origin "boot" :text text :state "dispatching"
                                :created-at now :updated-at now)))
    (fleet-core-operation-step store op "booting" (list :message-id mid))
    (fleet-eca-submit conn :message-id mid :text text
                      :callback (lambda (r)
                                  (fleet-store-transaction store
                                    (fleet-store-update store "messages" mid
                                                        (fleet-store-touch (list :state (pcase (plist-get r :outcome)
                                                                                          ('accepted "accepted") ('observed-unacknowledged "turn-observed")
                                                                                          ('rejected "rejected") (_ "delivery-unknown"))
                                                                                 :evidence (fleet-store-json (plist-get r :evidence))))))
                                  (funcall callback (plist-get r :outcome))))))

(defun fleet-core--task-start-fail (store op tid rt error callback)
  "Record a failed start of task TID with runtime RT; keep brief/worktree.
The operation finishes only after the runtime's stop verdict is in, so a
finished operation always means the failure has settled."
  (fleet-store-transaction store
    (fleet-store-update store "tasks" tid (fleet-store-touch (list :detail (format "start failed: %s" error) :detail-at (fleet-paths-now)))))
  (fleet-core-operation-step store op "stopping-failed-runtime" (list :error error :runtime-id (plist-get rt :id)))
  (fleet-core-stop-runtime store (plist-get rt :id) :reason "start failed"
                           :callback (lambda (r)
                                       (fleet-store-transaction store
                                         (when (equal (plist-get r :lifecycle) "stopped")
                                           (fleet-store-update store "tasks" tid (fleet-store-touch (list :lifecycle "suspended"))))
                                         (fleet-core-operation-finish store op :state "failed" :error error
                                                                      :evidence (list :runtime-id (plist-get rt :id) :stop-verdict (plist-get r :verdict))))
                                       (when callback (funcall callback (fleet-store-get store "operations" op))))))

;;;; Operation: commander start / stop / replace

(cl-defun fleet-core-start-commander (store fleet-id &key recovery-summary callback)
  "Launch a commander for FLEET-ID (no live predecessor allowed).
Return the operation id."
  (let ((fleet (fleet-core-fleet store fleet-id)))
    (when-let* ((rt (and (plist-get fleet :commander-runtime-id) (fleet-store-get store "runtimes" (plist-get fleet :commander-runtime-id)))))
      (unless (member (plist-get rt :lifecycle) '("stopped" "never-launched"))
        (fleet-fail 'runtime-not-stopped "Current commander is not proven stopped" :runtime-id (plist-get rt :id) :lifecycle (plist-get rt :lifecycle))))
    (when (> (fleet-store-scalar store "SELECT COUNT(*) FROM operations WHERE fleet_id = ? AND kind = 'commander-start' AND state = 'running'" fleet-id) 0)
      (fleet-fail 'operation-in-progress "A commander start is already running"))
    (fleet-core-owner-epoch)
    (fleet-eca-assert-supported)
    (let* ((op (fleet-core-operation-begin store "commander-start" :fleet-id fleet-id))
           (effective (fleet-core-commander-model fleet))
           (rt (fleet-core--new-runtime store :role "commander" :fleet-id fleet-id :model (car effective)
                                        :agent (plist-get fleet :commander-agent) :variant (cdr effective)))
           (cwd (fleet-paths-ensure-dir (expand-file-name "commander" (plist-get fleet :artifact-root)))))
      (fleet-store-transaction store
        (fleet-store-update store "fleets" fleet-id (fleet-store-touch (list :commander-runtime-id (plist-get rt :id)))))
      (fleet-core-operation-step store op "runtime-launched" (list :runtime-id (plist-get rt :id)))
      (fleet-core-launch-runtime
       ;; The whole fleet directory: the commander reads task reports and
       ;; progress files under tasks/ (rehearsal 1 needed approvals for it).
       store rt :roots (list (fleet-paths-canonical (plist-get fleet :artifact-root))) :cwd cwd
       :callback
       (lambda (r)
         (if (not (plist-get r :ok))
             (progn (fleet-core-operation-finish store op :state "failed" :error (plist-get r :error))
                    (fleet-core-stop-runtime store (plist-get rt :id) :reason "commander start failed" :callback (lambda (_) (when callback (funcall callback (fleet-store-get store "operations" op))))))
           (fleet-core-operation-step store op "connected")
           (fleet-core--boot store op (plist-get r :conn) (fleet-core-commander-boot-payload store (fleet-store-get store "fleets" fleet-id) rt recovery-summary)
                             (lambda (outcome)
                               (if (memq outcome '(accepted observed-unacknowledged))
                                   (progn
                                     (fleet-store-transaction store
                                       (fleet-store-append-event store :fleet-id fleet-id :runtime-id (plist-get rt :id) :kind "commander-started" :operation-id op))
                                     (fleet-core-operation-finish store op :state "done" :evidence (list :boot-outcome outcome)))
                                 (fleet-core-operation-finish store op :state "failed" :error (format "boot payload %s" outcome)))
                               (when callback (funcall callback (fleet-store-get store "operations" op))))))))
      op)))

(defun fleet-core-recovery-summary (store fleet)
  "Deterministic recovery summary text a replacement commander of FLEET boots with."
  (let ((tasks (fleet-store-tasks store (plist-get fleet :id))))
    (concat (format "Fleet `%s` is %s. Tasks:\n" (fleet-core-fleet-selector store fleet) (plist-get fleet :lifecycle))
            (mapconcat (lambda (task)
                         (format "- `%s` (%s): lifecycle %s, phase %s, brief rev %d — %s" (plist-get task :name) (plist-get task :kind)
                                 (plist-get task :lifecycle) (or (plist-get task :phase) "none") (plist-get task :brief-revision) (or (plist-get task :detail) "")))
                       tasks "\n")
            (format "\nDone tasks are verified/finalized, not rerun. Unfinished suspended tasks may be started again under their existing scope with fleet_task_start once the fleet is active. Held messages: %d. Read commander/context.md for the previous handoff."
                    (fleet-store-scalar store "SELECT COUNT(*) FROM messages WHERE fleet_id = ? AND state = 'held'" (plist-get fleet :id))))))

(cl-defun fleet-core-stop-commander (store fleet-id &key callback)
  "Stop FLEET-ID's commander with verified service evidence.
Operators are untouched."
  (let* ((fleet (fleet-core-fleet store fleet-id))
         (rt-id (or (plist-get fleet :commander-runtime-id) (fleet-fail 'no-commander "Fleet has no commander runtime"))))
    (fleet-core-stop-runtime store rt-id :reason "commander stop"
                             :callback (lambda (r)
                                         (fleet-store-transaction store
                                           (fleet-store-append-event store :fleet-id fleet-id :runtime-id rt-id :kind "commander-stopped"
                                                                     :payload (list :verdict (plist-get r :verdict))))
                                         (when callback (funcall callback r))))))

;;;; Operation: fleet park

(cl-defun fleet-core-park-fleet (store fleet-id &key callback)
  "Park FLEET-ID and, for a root, every lieutenant of it (docs/lieutenants.md §5).
Each fleet is its own `fleet-park' operation; CALLBACK gets the root's
operation row, with `:state' \"failed\" and an `:error' naming the
lieutenants whose park did not finish, and `:lieutenants' listing their
operation rows.  Returns the root's operation id.  There is deliberately
no per-lieutenant park: a parked root with an active lieutenant could
still start operators."
  (let* ((fleet (fleet-core-fleet store fleet-id))
         (children (cl-remove-if-not (lambda (c) (member (plist-get c :lifecycle) '("active" "parking")))
                                     (fleet-core-lieutenants store fleet-id)))
         (pending (1+ (length children)))
         (child-ops nil) (root-op nil))
    (unless (member (plist-get fleet :lifecycle) '("active" "parking"))
      (fleet-fail 'fleet-not-active "Fleet cannot be parked from this state" :lifecycle (plist-get fleet :lifecycle)))
    (cl-flet ((finish ()
                (when (and (<= (cl-decf pending) 0) callback)
                  (let ((failed (cl-remove-if (lambda (op) (equal (plist-get op :state) "done")) child-ops)))
                    (funcall callback
                             (append (if (and failed (equal (plist-get root-op :state) "done"))
                                         (plist-put (copy-sequence root-op) :state "failed")
                                       root-op)
                                     (list :lieutenants child-ops
                                           :error (or (plist-get root-op :error)
                                                      (and failed (format "lieutenant park not finished: %s"
                                                                          (mapconcat (lambda (op) (format "%s (%s)" (plist-get (fleet-store-get store "fleets" (plist-get op :fleet-id)) :name)
                                                                                                          (or (plist-get op :error) (plist-get op :state))))
                                                                                     failed ", ")))))))))))
      (dolist (c children)
        (fleet-core--park-one store (plist-get c :id) :callback (lambda (op) (push op child-ops) (finish))))
      (fleet-core--park-one store fleet-id :callback (lambda (op) (setq root-op op) (finish))))))

(cl-defun fleet-core--park-one (store fleet-id &key callback)
  "Park the single fleet FLEET-ID: stop operators, retain commander and durable work.
Returns the operation id."
  (let ((fleet (fleet-core-fleet store fleet-id)))
    (unless (member (plist-get fleet :lifecycle) '("active" "parking"))
      (fleet-fail 'fleet-not-active "Fleet cannot be parked from this state" :lifecycle (plist-get fleet :lifecycle)))
    (let ((op (fleet-core-operation-begin store "fleet-park" :fleet-id fleet-id)))
      (fleet-store-transaction store
        (fleet-store-update store "fleets" fleet-id (fleet-store-touch (list :lifecycle "parking")))
        ;; Never-attempted messages to operators are held, not lost.
        (fleet-store-exec store "UPDATE messages SET state = 'held', updated_at = ? WHERE fleet_id = ? AND state = 'queued' AND target_runtime_id IN (SELECT id FROM runtimes WHERE role = 'operator')" (fleet-paths-now) fleet-id)
        (fleet-store-append-event store :fleet-id fleet-id :kind "fleet-parking" :operation-id op))
      (fleet-core--park-continue store op fleet-id callback)
      op)))

(defun fleet-core--park-continue (store op fleet-id callback)
  "Advance park OP: stop every live operator runtime.
Then wait for the launch barrier."
  (let ((live (fleet-store-query store "SELECT * FROM runtimes WHERE fleet_id = ? AND role = 'operator' AND lifecycle IN ('launching','starting','ready','stopping','stop-unknown','lost')" fleet-id)))
    (fleet-core-operation-step store op "operators-stopping" (list :remaining (length live)))
    (if (null live)
        (fleet-core--park-commit store op fleet-id callback)
      (let ((pending (length live)) (unknown nil))
        (dolist (rt live)
          (if (equal (plist-get rt :lifecycle) "launching")
              ;; Launch barrier: a launch request in flight is not settled; re-check shortly.
              (progn (cl-decf pending)
                     (run-with-timer 1 nil #'fleet-core--park-continue store op fleet-id callback))
            (fleet-core-stop-runtime
             store (plist-get rt :id) :reason "fleet park"
             :callback (lambda (r)
                         (unless (equal (plist-get r :lifecycle) "stopped") (push (plist-get rt :id) unknown))
                         (when-let* ((task-id (plist-get rt :task-id)))
                           (fleet-store-transaction store
                             (let ((task (fleet-store-get store "tasks" task-id)))
                               (when (and (equal (plist-get task :lifecycle) "active") (equal (plist-get r :lifecycle) "stopped"))
                                 (fleet-store-update store "tasks" task-id
                                                     (fleet-store-touch (list :lifecycle "suspended"
                                                                              :detail (if (member (plist-get task :phase) fleet-core-terminal-phases)
                                                                                          (plist-get task :detail)
                                                                                        "paused by you; workspace retained")
                                                                              :detail-at (fleet-paths-now))))))))
                         (cl-decf pending)
                         (when (<= pending 0)
                           (if unknown
                               (fleet-core-operation-finish store op :state "failed" :error "some operator services could not be proven stopped"
                                                            :evidence (list :unknown (vconcat unknown)))
                             (fleet-core--park-continue store op fleet-id callback))
                           (when (and unknown callback) (funcall callback (fleet-store-get store "operations" op))))))))))))

(defun fleet-core--park-commit (store op fleet-id callback)
  "Commit `parked' once no operator execution or unsettled launch remains."
  (fleet-store-transaction store
    (let ((fleet (fleet-store-get store "fleets" fleet-id)))
      (when (equal (plist-get fleet :lifecycle) "parking")
        (fleet-store-update store "fleets" fleet-id (fleet-store-touch (list :lifecycle "parked")))
        (fleet-store-append-event store :fleet-id fleet-id :kind "fleet-parked" :operation-id op
                                  :payload (list :external-jobs (vconcat (mapcar (lambda (j) (plist-get j :id))
                                                                                (fleet-store-query store "SELECT id FROM external_jobs WHERE fleet_id = ? AND state IN ('running','unknown')" fleet-id)))))
        (fleet-core-operation-finish store op :state "done"))))
  (when callback (funcall callback (fleet-store-get store "operations" op))))

(defun fleet-core-resume-fleet (store fleet-id)
  "Mark a parked FLEET-ID active again (explicit human resume), lieutenants included.
Operators start only on request.  Returns the ids of the fleets resumed."
  (let ((fleet (fleet-core-fleet store fleet-id)))
    (when (plist-get fleet :parent-id)
      (fleet-fail 'fleet-not-root "Lieutenants park and resume with their root fleet" :root (plist-get (fleet-core-root-fleet store fleet) :name)))
    (unless (equal (plist-get fleet :lifecycle) "parked")
      (fleet-fail 'fleet-not-parked "Only a parked fleet can be resumed" :lifecycle (plist-get fleet :lifecycle)))
    (let ((ids (cons fleet-id (mapcar (lambda (c) (plist-get c :id))
                                      (cl-remove-if-not (lambda (c) (equal (plist-get c :lifecycle) "parked")) (fleet-core-lieutenants store fleet-id))))))
      (fleet-store-transaction store
        (dolist (id ids)
          (fleet-store-update store "fleets" id (fleet-store-touch (list :lifecycle "active")))
          (fleet-store-exec store "UPDATE messages SET state = 'queued', updated_at = ? WHERE fleet_id = ? AND state = 'held'" (fleet-paths-now) id)
          (fleet-store-append-event store :fleet-id id :kind "fleet-resumed" :actor fleet-core-actor-human)))
      ids)))

;;;; Operation: task teardown (design §10.5)

(cl-defun fleet-core-teardown-task (store task-id &key expected-revision actor action-id callback)
  "Admit normal teardown of TASK-ID; returns (:operation-id ...).
No force/discard parameter exists."
  (fleet-store-with-action store (or actor fleet-core-actor-human) action-id (list :op "task-teardown" :task-id task-id :expected-revision expected-revision)
    (let* ((task (fleet-core-task store task-id)))
      (fleet-store-check-revision store "tasks" task-id expected-revision)
      (when (member (plist-get task :lifecycle) '("archived" "draft")) (fleet-fail 'task-closed "Task cannot be torn down" :lifecycle (plist-get task :lifecycle)))
      (when (fleet-core-task-operation-running-p store task-id) (fleet-fail 'operation-in-progress "Another lifecycle operation is running"))
      (unless (fleet-core-task-verified-p store task)
        (fleet-fail 'deliverable-unverified "Teardown requires done + verified deliverables at the current brief revision"
                    :phase (plist-get task :phase)))
      (let ((op (fleet-core-operation-begin store "task-teardown" :fleet-id (plist-get task :fleet-id) :task-id task-id
                                            :expected-revision (plist-get task :entity-revision))))
        (fleet-store-transaction store
          (fleet-store-update store "tasks" task-id (fleet-store-touch (list :lifecycle "closing"))))
        (fleet-core--teardown-stop store op (fleet-store-get store "tasks" task-id) callback)
        (list :operation-id op :task-id task-id)))))

(defun fleet-core--teardown-stop (store op task callback)
  "Teardown step: prove the runtime stopped.
Waits for an observed turn end first."
  (let* ((rt-id (plist-get task :current-runtime-id))
         (rt (and rt-id (fleet-store-get store "runtimes" rt-id)))
         (conn (and rt-id (fleet-eca-conn rt-id))))
    (cond
     ((or (null rt) (member (plist-get rt :lifecycle) '("stopped" "never-launched")))
      (fleet-core--teardown-evidence store op task callback))
     ((and conn (fleet-eca-conn-turn conn))
      ;; Task reported done but its final response is still streaming: wait for the observed turn end.
      (fleet-core-operation-step store op "waiting-for-runtime-idle")
      (run-with-timer 2 nil #'fleet-core--teardown-stop store op task callback))
     (t
      (fleet-core-operation-step store op "stopping-runtime")
      (fleet-core-stop-runtime store rt-id :reason "task teardown"
                               :callback (lambda (r)
                                           (if (equal (plist-get r :lifecycle) "stopped")
                                               (fleet-core--teardown-evidence store op (fleet-store-get store "tasks" (plist-get task :id)) callback)
                                             (fleet-core--teardown-refuse store op task "runtime stop not proven" (list :verdict (plist-get r :verdict)) callback))))))))

(defun fleet-core--teardown-refuse (store op task reason evidence callback)
  "Refuse teardown of TASK with REASON and EVIDENCE, leaving everything in place."
  (fleet-store-transaction store
    (fleet-store-update store "tasks" (plist-get task :id) (fleet-store-touch (list :lifecycle "active" :detail (format "teardown refused: %s" reason) :detail-at (fleet-paths-now))))
    (fleet-core-operation-finish store op :state "failed" :error reason :evidence evidence))
  (when callback (funcall callback (fleet-store-get store "operations" op))))

(defun fleet-core--teardown-evidence (store op task callback)
  "Teardown step: collect Git evidence (change tasks) and decide removals.
Non-change tasks archive directly."
  (fleet-core-operation-step store op "runtime-stopped")
  (unless (fleet-core-task-verified-p store task)
    (fleet-core--teardown-refuse store op task "deliverables changed after verification" nil callback)
    (cl-return-from fleet-core--teardown-evidence nil))
  (if (not (and (equal (plist-get task :kind) "change") (plist-get task :workspace-path)))
      (fleet-core--teardown-archive store op task nil callback)
    (fleet-git-collect-evidence
     :workspace (plist-get task :workspace-path) :repo (plist-get task :repo-path) :branch (plist-get task :branch)
     :remote (plist-get task :remote) :target (plist-get task :target-ref) :base-oid (plist-get task :base-oid) :task-id (plist-get task :id)
     :callback
     (lambda (ev)
       (let ((decision (fleet-git-removal-decision :ev ev :workspace-ownership (plist-get task :workspace-ownership)
                                                   :branch-ownership (plist-get task :branch-ownership)
                                                   :delivery-mode (plist-get task :delivery-mode) :verified t)))
         (fleet-core-operation-step store op "evidence" (list :evidence (fleet-core--evidence-summary ev) :decision decision))
         (cond
          ((plist-get decision :retain-required)
           (fleet-git-retain (plist-get task :repo-path) (plist-get task :id) (plist-get ev :tip)
                             (lambda (r)
                               (if (plist-get r :ok)
                                   (fleet-core--teardown-evidence store op task callback) ; re-collect with the ref in place
                                 (fleet-core--teardown-refuse store op task (format "retention failed: %s" (plist-get r :error)) (list :retention r) callback)))))
          ((plist-get decision :refusals)
           (fleet-core--teardown-refuse store op task (string-join (plist-get decision :refusals) "; ")
                                        (list :evidence (fleet-core--evidence-summary ev) :decision decision) callback))
          (t (fleet-core--teardown-remove store op task ev decision callback))))))))

(defun fleet-core--evidence-summary (ev)
  "Serializable subset of Git evidence EV.
Used for the operation journal and refusal output."
  (list :tip (plist-get ev :tip) :branch (plist-get ev :branch) :dirty (plist-get ev :dirty-p)
        :status (let ((s (plist-get ev :status)))
                  (and s (list :tracked (plist-get s :tracked) :untracked (plist-get s :untracked) :ignored (plist-get s :ignored)
                               :paths (vconcat (fleet-git-dirty-paths s)))))
        :remote-preserved (plist-get ev :remote-preserved) :target-oid (plist-get ev :target-oid)
        :integrated-ancestry (plist-get ev :integrated-ancestry) :integrated-equivalence (plist-get ev :integrated-equivalence)
        :equivalence-detail (plist-get ev :equivalence-detail) :retention-ref (plist-get ev :retention-ref) :retention-oid (plist-get ev :retention-oid)
        :remote-error (plist-get ev :remote-error) :collected-at (plist-get ev :collected-at)))

(defun fleet-core--teardown-remove (store op task ev decision callback)
  "Teardown step: remove the owned worktree (native), then optionally `branch -d'."
  (let ((repo (plist-get task :repo-path)))
    (cl-flet ((then-branch ()
                (if (plist-get decision :delete-branch)
                    (fleet-git-delete-branch repo (plist-get task :branch)
                                             (lambda (r)
                                               (fleet-core-operation-step store op "branch-handled" (list :branch-delete r))
                                               (fleet-core--teardown-archive store op task
                                                                             (append (list :worktree-removed (plist-get decision :remove-worktree) :branch-deleted (plist-get r :ok)
                                                                                           :branch-warning (and (not (plist-get r :ok)) (plist-get r :error)))
                                                                                     (fleet-core--evidence-summary ev))
                                                                             callback)))
                  (fleet-core--teardown-archive store op task (append (list :worktree-removed (plist-get decision :remove-worktree) :branch-retained (plist-get task :branch))
                                                                      (fleet-core--evidence-summary ev))
                                                callback))))
      (if (plist-get decision :remove-worktree)
          (fleet-git-remove-worktree repo (plist-get task :workspace-path)
                                     (lambda (r)
                                       (if (plist-get r :ok)
                                           (progn (fleet-core-operation-step store op "worktree-removed") (then-branch))
                                         (fleet-core--teardown-refuse store op task (format "git worktree remove refused: %s" (plist-get r :error)) (list :remove r) callback))))
        ;; Adopted worktree: nothing removed, dirty content reported as left in place.
        (fleet-core-operation-step store op "worktree-retained" (list :adopted t))
        (then-branch)))))

(defun fleet-core--teardown-archive (store op task summary callback)
  "Final teardown step: archive the task, release claims, revoke credentials."
  (let ((tid (plist-get task :id)))
    (fleet-store-transaction store
      (fleet-store-update store "tasks" tid (fleet-store-touch (list :lifecycle "archived" :detail "archived" :detail-at (fleet-paths-now))))
      (fleet-store-exec store "DELETE FROM resource_claims WHERE task_id = ?" tid)
      (fleet-store-exec store "UPDATE runtimes SET credential_revoked = 1 WHERE task_id = ?" tid)
      (fleet-store-append-event store :fleet-id (plist-get task :fleet-id) :task-id tid :kind "task-archived" :operation-id op :payload summary)
      (fleet-core-operation-finish store op :state "done" :evidence summary))
    (when callback (funcall callback (fleet-store-get store "operations" op)))))

;;;; Operation: human close (design §10.5, implementation note 18)

(cl-defun fleet-core-close-task (store task-id &key reason expected-revision action-id)
  "Archive TASK-ID on human authority without the teardown evidence gate.
For work that teardown will never admit: failed or abandoned tasks, and done
tasks whose deliverables can no longer be verified.  Nothing is deleted or
stopped: the task's runtime must already be stopped and, for a change task,
its worktree must already be gone (a present worktree goes through teardown,
which is the only path that proves the branch preserved before removal).
REASON is required and recorded.  Returns (:operation-id ... :task-id ...)."
  (unless (and (stringp reason) (not (string-blank-p reason)))
    (fleet-fail 'invalid-request "A close reason is required"))
  (fleet-store-with-action store fleet-core-actor-human action-id (list :op "task-close" :task-id task-id :reason reason :expected-revision expected-revision)
    (let* ((task (fleet-core-task store task-id))
           (rt-id (plist-get task :current-runtime-id))
           (rt (and rt-id (fleet-store-get store "runtimes" rt-id)))
           (ws (plist-get task :workspace-path)))
      (fleet-store-check-revision store "tasks" task-id expected-revision)
      (when (member (plist-get task :lifecycle) '("archived" "draft" "closing"))
        (fleet-fail 'task-closed "Task cannot be closed" :lifecycle (plist-get task :lifecycle)))
      (when (fleet-core-task-operation-running-p store task-id)
        (fleet-fail 'operation-in-progress "Another lifecycle operation is running"))
      (when (and rt (not (member (plist-get rt :lifecycle) '("stopped" "never-launched"))))
        (fleet-fail 'runtime-not-stopped "Close needs a stopped operator; park the fleet or tear the task down"
                    :runtime-id rt-id :lifecycle (plist-get rt :lifecycle)))
      (when (and (equal (plist-get task :kind) "change") ws (file-directory-p ws))
        (fleet-fail 'worktree-present "Close never removes a worktree; use teardown, or remove it yourself once its work is preserved"
                    :workspace ws))
      (let* ((summary (list :closed-by fleet-core-actor-human :reason reason
                            :lifecycle (plist-get task :lifecycle) :phase (plist-get task :phase)
                            :verified (and (fleet-core-task-verified-p store task) t)
                            :workspace-missing (and ws (not (file-directory-p ws)) t)
                            :branch-retained (and (equal (plist-get task :kind) "change") (plist-get task :branch))))
             (op (fleet-core-operation-begin store "task-close" :fleet-id (plist-get task :fleet-id) :task-id task-id
                                             :expected-revision (plist-get task :entity-revision) :intent summary)))
        (fleet-store-transaction store
          (fleet-store-append-event store :fleet-id (plist-get task :fleet-id) :task-id task-id :kind "task-closed" :operation-id op :payload summary)
          (fleet-store-update store "tasks" task-id (fleet-store-touch (list :lifecycle "archived" :detail (format "closed: %s" reason) :detail-at (fleet-paths-now))))
          (fleet-store-exec store "DELETE FROM resource_claims WHERE task_id = ?" task-id)
          (fleet-store-exec store "UPDATE runtimes SET credential_revoked = 1 WHERE task_id = ?" task-id)
          (fleet-store-append-event store :fleet-id (plist-get task :fleet-id) :task-id task-id :kind "task-archived" :operation-id op :payload summary)
          (fleet-core-operation-finish store op :state "done" :evidence summary))
        (list :operation-id op :task-id task-id)))))

;;;; Operation: fleet retire (design §10.6)

(cl-defun fleet-core-retire-fleet (store fleet-id &key callback)
  "Retire an empty FLEET-ID: archive-move its artifact tree and release the name."
  (let ((fleet (fleet-core-fleet store fleet-id)))
    (when (> (fleet-store-scalar store "SELECT COUNT(*) FROM tasks WHERE fleet_id = ? AND lifecycle <> 'archived'" fleet-id) 0)
      (fleet-fail 'fleet-not-empty "Fleet still has unarchived tasks"))
    ;; Retirement is never recursive: lieutenants are retired one by one first.
    (when-let* ((lts (fleet-core-lieutenants store fleet-id)))
      (fleet-fail 'fleet-not-empty "Fleet still has lieutenants; retire them first (fleet-destroy root/child)"
                  :lieutenants (mapcar (lambda (lt) (plist-get lt :name)) lts)))
    (when (> (fleet-store-scalar store "SELECT COUNT(*) FROM requests WHERE (child_fleet_id = ? OR parent_fleet_id = ?) AND state = 'open'" fleet-id fleet-id) 0)
      (fleet-fail 'fleet-not-empty "Fleet has open requests; settle them first"))
    (when (> (fleet-store-scalar store "SELECT COUNT(*) FROM operations WHERE fleet_id = ? AND state = 'running'" fleet-id) 0)
      (fleet-fail 'operation-in-progress "Fleet has running operations"))
    (when (> (fleet-store-scalar store "SELECT COUNT(*) FROM runtimes WHERE fleet_id = ? AND role = 'operator' AND lifecycle NOT IN ('stopped','never-launched')" fleet-id) 0)
      (fleet-fail 'runtime-not-stopped "Operator services remain"))
    (let ((op (fleet-core-operation-begin store "fleet-retire" :fleet-id fleet-id
                                          :intent (list :old-root (plist-get fleet :artifact-root) :new-root (fleet-paths-fleet-archive-dir fleet-id)))))
      (fleet-store-transaction store
        (fleet-store-update store "fleets" fleet-id (fleet-store-touch (list :lifecycle "retiring")))
        (fleet-store-append-event store :fleet-id fleet-id :kind "fleet-retiring" :operation-id op))
      (let ((cmd-rt (and (plist-get fleet :commander-runtime-id) (fleet-store-get store "runtimes" (plist-get fleet :commander-runtime-id)))))
        (if (and cmd-rt (not (member (plist-get cmd-rt :lifecycle) '("stopped" "never-launched"))))
            (fleet-core-stop-runtime store (plist-get cmd-rt :id) :reason "fleet retire"
                                     :callback (lambda (r)
                                                 (if (equal (plist-get r :lifecycle) "stopped")
                                                     (fleet-core--retire-rename store op fleet-id callback)
                                                   (fleet-core-operation-finish store op :state "failed" :error "commander stop not proven")
                                                   (when callback (funcall callback (fleet-store-get store "operations" op))))))
          (fleet-core--retire-rename store op fleet-id callback)))
      op)))

(defun fleet-core--retire-rename (store op fleet-id callback)
  "Retire step: archive-rename the artifact tree then commit archived.
Both happen in one transaction."
  (let* ((intent (fleet-store-unjson (plist-get (fleet-store-get store "operations" op) :intent)))
         (old (plist-get intent :old-root)) (new (plist-get intent :new-root)))
    (fleet-core-operation-step store op "renaming")
    (condition-case err
        (progn
          (fleet-paths-ensure-dir (file-name-directory (directory-file-name new)))
          (cond ((file-directory-p new) nil) ; rename already happened before a crash
                ((file-directory-p old) (rename-file old new))
                (t (fleet-fail 'artifact-root-missing "Neither old nor new artifact root exists" :old old :new new)))
          (fleet-store-transaction store
            (fleet-store-update store "fleets" fleet-id (fleet-store-touch (list :lifecycle "archived" :artifact-root new)))
            (fleet-store-append-event store :fleet-id fleet-id :kind "fleet-archived" :operation-id op :payload (list :old-root old :new-root new))
            (fleet-core-operation-finish store op :state "done"))
          (when callback (funcall callback (fleet-store-get store "operations" op))))
      (error
       (fleet-core-operation-finish store op :state "failed" :error (error-message-string err))
       (when callback (funcall callback (fleet-store-get store "operations" op)))))))

;;;; Recovery after restart (design §6.4)

(defun fleet-core-reconcile-runtimes (store callback)
  "Reconcile every nonterminal runtime against its exact unit.
Runs after an Emacs restart.
Stops surviving services, records evidence, marks affected tasks suspended.
CALLBACK gets a summary plist when done."
  (let* ((rows (fleet-store-query store "SELECT * FROM runtimes WHERE lifecycle NOT IN ('stopped','never-launched')"))
         (pending (length rows)) (summary nil))
    (if (null rows)
        (funcall callback (list :reconciled 0))
      (dolist (rt rows)
        (fleet-core-stop-runtime
         store (plist-get rt :id) :reason "owner restart reconciliation"
         :callback (lambda (r)
                     (push (list :runtime-id (plist-get rt :id) :verdict (plist-get r :verdict)) summary)
                     (fleet-store-transaction store
                       (when-let* ((tid (plist-get rt :task-id)))
                         (let ((task (fleet-store-get store "tasks" tid)))
                           (when (equal (plist-get task :lifecycle) "active")
                             (fleet-store-update store "tasks" tid (fleet-store-touch (list :lifecycle "suspended" :detail "suspended after Emacs restart" :detail-at (fleet-paths-now)))))))
                       (fleet-store-append-event store :fleet-id (plist-get rt :fleet-id) :task-id (plist-get rt :task-id) :runtime-id (plist-get rt :id)
                                                 :kind "runtime-reconciled" :payload (list :verdict (plist-get r :verdict))
                                                 :actionable (not (equal (plist-get r :lifecycle) "stopped"))))
                     (cl-decf pending)
                     (when (<= pending 0)
                       (fleet-core-resume-operations store)
                       (funcall callback (list :reconciled (length summary) :runtimes summary)))))))))

(defun fleet-core-resume-operations (store)
  "Resolve operations left running by a previous owner from their journal."
  (dolist (op (fleet-store-query store "SELECT * FROM operations WHERE state = 'running'"))
    (pcase (plist-get op :kind)
      ("brief-publish" (fleet-core-recover-brief-operation store op))
      ("fleet-retire" (when (equal (plist-get op :step) "renaming") (fleet-core--retire-rename store (plist-get op :id) (plist-get op :fleet-id) nil)))
      ((or "task-start" "commander-start" "runtime-stop")
       ;; Their runtimes were just reconciled; the operation itself cannot continue without the old connection.
       (fleet-core-operation-finish store (plist-get op :id) :state "failed" :error "interrupted by owner restart; runtime reconciled"))
      ("fleet-park"
       (fleet-core--park-continue store (plist-get op :id) (plist-get op :fleet-id) nil))
      ("task-teardown"
       (let ((task (fleet-store-get store "tasks" (plist-get op :task-id))))
         (when (equal (plist-get task :lifecycle) "closing")
           (fleet-core--teardown-refuse store (plist-get op :id) task "interrupted by owner restart; rerun teardown" nil nil))))
      (_ nil))))

(provide 'fleet-core)
;;; fleet-core.el ends here
