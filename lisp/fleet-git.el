;;; fleet-git.el --- Worktrees, ownership, and preservation evidence -*- lexical-binding: t; -*-

;;; Commentary:

;; Sole authority for workspace creation and cleanup.  All Git runs
;; asynchronously with argument vectors.  Evidence is collected into an
;; alist and judged by pure functions so refusals are reproducible.
;;
;; Three separate questions (design §11): preserved? integrated? owned and
;; safe to remove?  Only native `git worktree remove' and `git branch -d'
;; ever delete anything; there is no rm -rf or -D fallback.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'fleet-paths)

(defvar fleet-git-executable "git" "Git executable.")

(defconst fleet-git-remote-timeout-sec 20
  "Bound for remote advertisement queries.")

;;;; Runner

(defun fleet-git-run (dir args callback)
  "Run git ARGS in DIR asynchronously; CALLBACK gets (:exit N :stdout S :stderr S :args ARGS)."
  (let* ((out (generate-new-buffer " *fleet-git-out*" t))
         (err (generate-new-buffer " *fleet-git-err*" t))
         (default-directory (file-name-as-directory (or dir default-directory))))
    (condition-case e
        (make-process
         :name "fleet-git" :command (cons fleet-git-executable args)
         :buffer out :stderr err :noquery t :connection-type 'pipe :coding 'utf-8-unix
         :sentinel
         (lambda (proc _event)
           (unless (process-live-p proc)
             (let ((r (list :exit (process-exit-status proc)
                            :stdout (with-current-buffer out (buffer-string))
                            :stderr (with-current-buffer err (buffer-string))
                            :args args)))
               (kill-buffer out) (kill-buffer err)
               (funcall callback r)))))
      (error
       (kill-buffer out) (kill-buffer err)
       (funcall callback (list :exit -1 :stdout "" :stderr (error-message-string e) :args args))))))

(defun fleet-git-ok-p (r) "Non-nil when git result R exited zero." (and r (eql 0 (plist-get r :exit))))
(defun fleet-git-out (r) "Trimmed stdout of R." (string-trim (or (plist-get r :stdout) "")))

(defun fleet-git-batch (dir specs callback)
  "Run SPECS ((KEY . ARGS)...) sequentially in DIR; CALLBACK gets alist (KEY . RESULT).
Never stops early: every fact is collected for a single evidence pass."
  (let ((results nil))
    (cl-labels ((next (rest)
                  (if (null rest)
                      (funcall callback (nreverse results))
                    (fleet-git-run dir (cdr (car rest))
                                   (lambda (r)
                                     (push (cons (car (car rest)) r) results)
                                     (next (cdr rest)))))))
      (next specs))))

(defun fleet-git-fact (alist key)
  "Result for KEY in evidence ALIST."
  (cdr (assq key alist)))

;;;; Identity

(defun fleet-git-repo-identity (dir callback)
  "Inspect DIR; CALLBACK gets a plist or (:error ...).
Keys: :common-dir :toplevel :git-dir :head :branch (nil when detached)
:main-worktree (toplevel of the primary checkout) :worktrees (porcelain list)."
  (fleet-git-batch
   dir
   '((common . ("rev-parse" "--git-common-dir"))
     (top . ("rev-parse" "--show-toplevel"))
     (gitdir . ("rev-parse" "--git-dir"))
     (head . ("rev-parse" "--verify" "-q" "HEAD"))
     (branch . ("symbolic-ref" "-q" "--short" "HEAD"))
     (list . ("worktree" "list" "--porcelain")))
   (lambda (a)
     (if (not (and (fleet-git-ok-p (fleet-git-fact a 'common)) (fleet-git-ok-p (fleet-git-fact a 'top))))
         (funcall callback (list :error "not a git repository" :dir dir
                                 :stderr (plist-get (fleet-git-fact a 'common) :stderr)))
       (let* ((top (fleet-paths-canonical (fleet-git-out (fleet-git-fact a 'top))))
              (common (fleet-paths-canonical (expand-file-name (fleet-git-out (fleet-git-fact a 'common)) top)))
              (wts (fleet-git-parse-worktree-list (plist-get (fleet-git-fact a 'list) :stdout))))
         (funcall callback
                  (list :dir (fleet-paths-canonical dir) :toplevel top :common-dir common
                        :git-dir (fleet-paths-canonical (expand-file-name (fleet-git-out (fleet-git-fact a 'gitdir)) top))
                        :head (and (fleet-git-ok-p (fleet-git-fact a 'head)) (fleet-git-out (fleet-git-fact a 'head)))
                        :branch (and (fleet-git-ok-p (fleet-git-fact a 'branch)) (fleet-git-out (fleet-git-fact a 'branch)))
                        :main-worktree (plist-get (car wts) :path)
                        :worktrees wts)))))))

(defun fleet-git-parse-worktree-list (text)
  "Parse `git worktree list --porcelain' TEXT into plists (:path :head :branch :bare :detached :locked)."
  (let (entries current)
    (dolist (line (split-string (or text "") "\n"))
      (cond
       ((string-empty-p line)
        (when current (push (nreverse current) entries) (setq current nil)))
       ((string-prefix-p "worktree " line)
        (setq current (list (fleet-paths-canonical (substring line 9)) :path)))
       ((string-prefix-p "HEAD " line) (setq current (append (list (substring line 5) :head) current)))
       ((string-prefix-p "branch " line) (setq current (append (list (string-remove-prefix "refs/heads/" (substring line 7)) :branch) current)))
       ((string= line "bare") (setq current (append (list t :bare) current)))
       ((string= line "detached") (setq current (append (list t :detached) current)))
       ((string-prefix-p "locked" line) (setq current (append (list t :locked) current)))))
    (when current (push (nreverse current) entries))
    (nreverse entries)))

(defun fleet-git-worktree-entry (identity path)
  "Registered worktree plist for canonical PATH in IDENTITY, or nil."
  (let ((c (fleet-paths-canonical path)))
    (cl-find-if (lambda (w) (string= (plist-get w :path) c)) (plist-get identity :worktrees))))

(defun fleet-git-branch-checkout (identity branch)
  "Worktree plist where BRANCH is checked out, or nil."
  (cl-find-if (lambda (w) (equal (plist-get w :branch) branch)) (plist-get identity :worktrees)))

;;;; Base/branch resolution

(defun fleet-git-resolve-commit (repo ref callback)
  "Resolve REF to a commit OID in REPO; CALLBACK gets OID or nil."
  (fleet-git-run repo (list "rev-parse" "--verify" "-q" (concat ref "^{commit}"))
                 (lambda (r) (funcall callback (and (fleet-git-ok-p r) (fleet-git-out r))))))

(defun fleet-git-default-branch (repo remote callback)
  "Find the default branch of REPO; CALLBACK gets a name like \"main\" or nil.
Order: REMOTE's advertised HEAD; an existing local branch named by
init.defaultBranch; existing `main'; existing `master'; the only local
branch when there is exactly one.  Never assumes master over main."
  (fleet-git-batch
   repo
   (append (when remote (list (cons 'rhead (list "symbolic-ref" "-q" "--short" (format "refs/remotes/%s/HEAD" remote)))))
           '((cfg . ("config" "--get" "init.defaultBranch"))
             (heads . ("for-each-ref" "--format=%(refname:short)" "refs/heads/"))))
   (lambda (a)
     (let* ((heads (split-string (fleet-git-out (fleet-git-fact a 'heads)) "\n" t))
            (cfg (and (fleet-git-ok-p (fleet-git-fact a 'cfg)) (fleet-git-out (fleet-git-fact a 'cfg)))))
       (funcall callback
                (cond
                 ((fleet-git-ok-p (fleet-git-fact a 'rhead))
                  (string-remove-prefix (concat remote "/") (fleet-git-out (fleet-git-fact a 'rhead))))
                 ((and cfg (member cfg heads)) cfg)
                 ((member "main" heads) "main")
                 ((member "master" heads) "master")
                 ((= 1 (length heads)) (car heads))
                 (t nil)))))))

(defun fleet-git-remotes (repo callback)
  "CALLBACK gets the list of remote names of REPO (possibly empty)."
  (fleet-git-run repo '("remote") (lambda (r) (funcall callback (and (fleet-git-ok-p r) (split-string (fleet-git-out r) "\n" t))))))

;;;; Workspace creation

(cl-defun fleet-git-create-worktree (&key repo path branch base-oid callback)
  "Create Fleet-owned BRANCH at BASE-OID checked out in a new worktree at PATH.
Refuses if BRANCH already exists or PATH exists.  CALLBACK gets a plist with
:ok, :identity, or :error/:code."
  (cond
   ((file-exists-p path)
    (funcall callback (list :ok nil :code 'workspace-exists :error "Worktree path already exists" :path path)))
   (t
    (fleet-git-run repo (list "rev-parse" "--verify" "-q" (concat "refs/heads/" branch))
                   (lambda (r)
                     (if (fleet-git-ok-p r)
                         (funcall callback (list :ok nil :code 'branch-exists :error "Branch already exists" :branch branch))
                       (fleet-paths-ensure-dir (file-name-directory (directory-file-name path)))
                       (fleet-git-run repo (list "worktree" "add" "-b" branch path base-oid)
                                      (lambda (add)
                                        (if (not (fleet-git-ok-p add))
                                            (funcall callback (list :ok nil :code 'worktree-add-failed :error (plist-get add :stderr)))
                                          (fleet-git-repo-identity path (lambda (id) (funcall callback (list :ok t :identity id)))))))))))))

(cl-defun fleet-git-adopt-branch (&key repo path branch callback)
  "Check out existing BRANCH (local or remote-tracking) into a new Fleet-owned worktree at PATH.
The branch remains adopted (never deleted).  Refuses when Git says the branch
is already checked out elsewhere."
  (fleet-git-repo-identity
   repo
   (lambda (id)
     (cond
      ((plist-get id :error) (funcall callback (list :ok nil :code 'not-a-repo :error (plist-get id :error))))
      ((fleet-git-branch-checkout id branch)
       (funcall callback (list :ok nil :code 'branch-checked-out :error "Branch is checked out in another worktree"
                               :where (plist-get (fleet-git-branch-checkout id branch) :path))))
      ((file-exists-p path) (funcall callback (list :ok nil :code 'workspace-exists :error "Worktree path already exists")))
      (t
       (fleet-git-batch
        repo
        (list (cons 'local (list "rev-parse" "--verify" "-q" (concat "refs/heads/" branch)))
              (cons 'remote (list "for-each-ref" "--format=%(refname)" (concat "refs/remotes/*/" branch))))
        (lambda (a)
          (let ((remote-ref (car (split-string (fleet-git-out (fleet-git-fact a 'remote)) "\n" t))))
            (cond
             ((fleet-git-ok-p (fleet-git-fact a 'local))
              (fleet-paths-ensure-dir (file-name-directory (directory-file-name path)))
              (fleet-git-run repo (list "worktree" "add" path branch)
                             (lambda (add) (fleet-git--finish-adopt add path callback))))
             (remote-ref
              (fleet-paths-ensure-dir (file-name-directory (directory-file-name path)))
              (fleet-git-run repo (list "worktree" "add" "--track" "-b" branch path (string-remove-prefix "refs/remotes/" remote-ref))
                             (lambda (add) (fleet-git--finish-adopt add path callback))))
             (t (funcall callback (list :ok nil :code 'branch-missing :error "No such local or remote branch" :branch branch))))))))))))

(defun fleet-git--finish-adopt (add path callback)
  "Complete an adoption after `worktree add' result ADD at PATH."
  (if (not (fleet-git-ok-p add))
      (funcall callback (list :ok nil :code 'worktree-add-failed :error (plist-get add :stderr)))
    (fleet-git-repo-identity path (lambda (id) (funcall callback (list :ok t :identity id))))))

(cl-defun fleet-git-adopt-worktree (&key repo path callback)
  "Validate PATH as an existing registered worktree of REPO for adoption.
Fleet owns neither directory nor branch.  Refuses the primary checkout."
  (fleet-git-repo-identity
   repo
   (lambda (rid)
     (if (plist-get rid :error)
         (funcall callback (list :ok nil :code 'not-a-repo :error (plist-get rid :error)))
       (let ((entry (fleet-git-worktree-entry rid path)))
         (cond
          ((null entry) (funcall callback (list :ok nil :code 'not-a-worktree :error "Path is not a registered worktree of this repository" :path path)))
          ((string= (plist-get entry :path) (plist-get rid :main-worktree))
           (funcall callback (list :ok nil :code 'primary-clone :error "Primary clone is not a Fleet execution workspace" :path path)))
          (t (fleet-git-repo-identity path (lambda (id) (funcall callback (list :ok t :identity id :entry entry)))))))))))

;;;; Status

(defun fleet-git-parse-status-z (text)
  "Parse `status --porcelain=v1 -z' TEXT into (:tracked N :untracked N :ignored N :entries LIST)."
  (let ((fields (split-string (or text "") "\0" t)) entries tracked untracked ignored)
    (while fields
      (let* ((f (pop fields)) (code (substring f 0 (min 2 (length f)))) (path (and (> (length f) 3) (substring f 3))))
        ;; Renames/copies carry the original path as the next NUL field.
        (when (and (>= (length code) 1) (memq (aref code 0) '(?R ?C))) (pop fields))
        (push (list code path) entries)
        (cond ((string= code "!!") (setq ignored (1+ (or ignored 0))))
              ((string= code "??") (setq untracked (1+ (or untracked 0))))
              (t (setq tracked (1+ (or tracked 0)))))))
    (list :tracked (or tracked 0) :untracked (or untracked 0) :ignored (or ignored 0) :entries (nreverse entries))))

(defconst fleet-git-status-args
  '("status" "--porcelain=v1" "-z" "--untracked-files=all" "--ignored=matching" "--ignore-submodules=none"))

;;;; Evidence collection (design §11.2)

(cl-defun fleet-git-collect-evidence (&key workspace repo branch remote target base-oid task-id callback)
  "Collect a single evidence pass for WORKSPACE of REPO and hand a plist to CALLBACK.
BRANCH is the recorded task branch; REMOTE/TARGET describe the delivery target
\(TARGET is a ref such as \"main\"); BASE-OID the recorded base; TASK-ID names
the retention ref.  The result contains raw facts plus derived verdicts."
  (ignore repo) ; the workspace itself answers every question; REPO is accepted for call symmetry
  (fleet-git-repo-identity
   workspace
   (lambda (id)
     (if (plist-get id :error)
         (funcall callback (list :ok nil :code 'workspace-uninspectable :error (plist-get id :error) :identity id))
       (let* ((tip (plist-get id :head))
              (retention (format "refs/fleet/retained/%s" task-id))
              (specs (append
                      (list (cons 'status fleet-git-status-args)
                            (cons 'submodules '("submodule" "status" "--recursive"))
                            (cons 'retention (list "rev-parse" "--verify" "-q" retention))
                            (cons 'branch-oid (list "rev-parse" "--verify" "-q" (concat "refs/heads/" (or branch ""))))
                            (cons 'refs-at-tip (list "for-each-ref" "--points-at" (or tip "HEAD") "--format=%(refname)")))
                      (when (and remote target)
                        (list (cons 'ls-remote (list "-c" (format "http.lowSpeedTime=%d" fleet-git-remote-timeout-sec)
                                                     "ls-remote" "--heads" remote))))
                      (when target
                        (list (cons 'target-oid (list "rev-parse" "--verify" "-q"
                                                      (concat (if remote (format "refs/remotes/%s/%s" remote target)
                                                                (concat "refs/heads/" target))
                                                              "^{commit}")))))
                      (when (and tip base-oid) (list (cons 'cumulative (list "diff" (concat base-oid ".." tip))))))))
         (fleet-git-batch
          workspace specs
          (lambda (a)
            (let* ((target-oid (and (fleet-git-ok-p (fleet-git-fact a 'target-oid)) (fleet-git-out (fleet-git-fact a 'target-oid))))
                   (ls (fleet-git-fact a 'ls-remote)))
              (fleet-git--evidence-stage2
               workspace a id tip target-oid remote target base-oid retention ls callback)))))))))

(defun fleet-git--evidence-stage2 (workspace a id tip target-oid remote target base-oid retention ls callback)
  "Second evidence stage needing TARGET-OID: ancestry, merge-base, patch ids.
WORKSPACE, A (stage-1 facts), ID, TIP, REMOTE, TARGET, BASE-OID, RETENTION
and LS are threaded through to the final judgement handed to CALLBACK."
  (fleet-git-batch
   workspace
   (append
    (when (and tip target-oid)
      (list (cons 'ancestor (list "merge-base" "--is-ancestor" tip target-oid))
            (cons 'merge-base (list "merge-base" tip target-oid))))
    (when (and tip target-oid)
      (list (cons 'cherry (list "cherry" target-oid tip)))))
   (lambda (b)
     (let* ((mb (and (fleet-git-ok-p (fleet-git-fact b 'merge-base)) (fleet-git-out (fleet-git-fact b 'merge-base)))))
       (fleet-git--evidence-stage3 workspace a b id tip target-oid remote target base-oid mb retention ls callback)))))

(defun fleet-git--evidence-stage3 (workspace a b id tip target-oid remote target base-oid mb retention ls callback)
  "Third stage: cumulative patch-id against target commits since merge-base MB."
  (fleet-git-batch
   workspace
   (when (and tip target-oid mb)
     (list (cons 'branch-commits (list "rev-list" "--no-merges" (concat mb ".." tip)))
           (cons 'branch-all-commits (list "rev-list" (concat mb ".." tip)))
           (cons 'target-commits (list "rev-list" "--no-merges" (concat mb ".." target-oid)))
           (cons 'cumulative (list "diff" (concat mb ".." tip)))))
   (lambda (c)
     (fleet-git--patch-ids
      workspace
      (and (fleet-git-ok-p (fleet-git-fact c 'target-commits)) (split-string (fleet-git-out (fleet-git-fact c 'target-commits)) "\n" t))
      (and (fleet-git-ok-p (fleet-git-fact c 'cumulative)) (plist-get (fleet-git-fact c 'cumulative) :stdout))
      (lambda (target-ids cumulative-id)
        (funcall callback
                 (fleet-git-judge
                  (list :ok t :identity id :tip tip :branch (plist-get id :branch)
                        :recorded-branch-oid (and (fleet-git-ok-p (fleet-git-fact a 'branch-oid)) (fleet-git-out (fleet-git-fact a 'branch-oid)))
                        :status (and (fleet-git-ok-p (fleet-git-fact a 'status)) (fleet-git-parse-status-z (plist-get (fleet-git-fact a 'status) :stdout)))
                        :status-error (and (not (fleet-git-ok-p (fleet-git-fact a 'status))) (plist-get (fleet-git-fact a 'status) :stderr))
                        :submodules (and (fleet-git-ok-p (fleet-git-fact a 'submodules)) (fleet-git-out (fleet-git-fact a 'submodules)))
                        :refs-at-tip (and (fleet-git-ok-p (fleet-git-fact a 'refs-at-tip)) (split-string (fleet-git-out (fleet-git-fact a 'refs-at-tip)) "\n" t))
                        :retention-ref retention
                        :retention-oid (and (fleet-git-ok-p (fleet-git-fact a 'retention)) (fleet-git-out (fleet-git-fact a 'retention)))
                        :remote remote :target target :target-oid target-oid :base-oid base-oid :merge-base mb
                        :remote-heads (and ls (fleet-git-ok-p ls) (fleet-git-parse-ls-remote (plist-get ls :stdout)))
                        :remote-error (and ls (not (fleet-git-ok-p ls)) (plist-get ls :stderr))
                        :ancestor (and (fleet-git-fact b 'ancestor) (fleet-git-ok-p (fleet-git-fact b 'ancestor)))
                        :cherry (and (fleet-git-ok-p (fleet-git-fact b 'cherry)) (split-string (fleet-git-out (fleet-git-fact b 'cherry)) "\n" t))
                        :branch-commits (and (fleet-git-ok-p (fleet-git-fact c 'branch-commits)) (split-string (fleet-git-out (fleet-git-fact c 'branch-commits)) "\n" t))
                        :branch-all-commits (and (fleet-git-ok-p (fleet-git-fact c 'branch-all-commits)) (split-string (fleet-git-out (fleet-git-fact c 'branch-all-commits)) "\n" t))
                        :target-patch-ids target-ids
                        :cumulative-patch-id cumulative-id
                        :collected-at (fleet-paths-now)))))))))

(defun fleet-git--patch-ids (workspace target-commits cumulative-diff callback)
  "Compute stable patch ids for TARGET-COMMITS and CUMULATIVE-DIFF text; CALLBACK gets (IDS . CUMULATIVE-ID)."
  (let ((ids nil))
    (cl-labels
        ((finish ()
           (if (and cumulative-diff (not (string-empty-p cumulative-diff)))
               (fleet-git--patch-id-of-text workspace cumulative-diff
                                            (lambda (pid) (funcall callback (nreverse ids) pid)))
             (funcall callback (nreverse ids) nil)))
         (next (rest)
           (if (null rest) (finish)
             (fleet-git-run workspace (list "diff-tree" "-p" (car rest))
                            (lambda (r)
                              (if (not (fleet-git-ok-p r))
                                  (progn (push (cons (car rest) nil) ids) (next (cdr rest)))
                                (fleet-git--patch-id-of-text
                                 workspace (plist-get r :stdout)
                                 (lambda (pid) (push (cons (car rest) pid) ids) (next (cdr rest))))))))))
      (next target-commits))))

(defun fleet-git--patch-id-of-text (workspace diff-text callback)
  "Pipe DIFF-TEXT through `git patch-id --stable'; CALLBACK gets the id or nil."
  (let* ((out (generate-new-buffer " *fleet-patch-id*" t))
         (default-directory (file-name-as-directory workspace))
         (proc (make-process :name "fleet-patch-id" :command (list fleet-git-executable "patch-id" "--stable")
                             :buffer out :noquery t :connection-type 'pipe :coding 'utf-8-unix
                             :sentinel (lambda (p _e)
                                         (unless (process-live-p p)
                                           (let ((text (with-current-buffer out (buffer-string))))
                                             (kill-buffer out)
                                             (funcall callback (and (eql 0 (process-exit-status p))
                                                                    (car (split-string text nil t))))))))))
    (process-send-string proc diff-text)
    (process-send-eof proc)))

(defun fleet-git-parse-ls-remote (text)
  "Parse `ls-remote --heads' TEXT into alist (REFNAME . OID)."
  (cl-loop for line in (split-string (or text "") "\n" t)
           for parts = (split-string line "[ \t]+" t)
           when (= 2 (length parts)) collect (cons (cadr parts) (car parts))))

;;;; Judgement (pure; design §11.2–11.3)

(defun fleet-git-judge (ev)
  "Derive :dirty-p :remote-preserved :integrated-ancestry :integrated-equivalence
:equivalence-detail :tip-retained-p from raw evidence EV.  Returns EV extended."
  (let* ((status (plist-get ev :status))
         (dirty (or (plist-get ev :status-error)
                    (null status)
                    (> (+ (plist-get status :tracked) (plist-get status :untracked) (plist-get status :ignored)) 0)))
         (tip (plist-get ev :tip))
         (remote-heads (plist-get ev :remote-heads))
         (remote-preserved (and tip remote-heads (cl-some (lambda (h) (string= (cdr h) tip)) remote-heads)
                                (car (cl-find-if (lambda (h) (string= (cdr h) tip)) remote-heads))))
         (ancestry (and (plist-get ev :target-oid) (plist-get ev :ancestor) t))
         (equiv (fleet-git--equivalence ev))
         (surviving-refs (cl-remove-if (lambda (r) (or (string= r (concat "refs/heads/" (or (plist-get ev :branch) "")))
                                                       (string-prefix-p "refs/remotes/" r)))
                                       (plist-get ev :refs-at-tip))))
    (append ev
            (list :dirty-p (and dirty t)
                  :remote-preserved remote-preserved
                  :integrated-ancestry ancestry
                  :integrated-equivalence (car equiv)
                  :equivalence-detail (cdr equiv)
                  :tip-retained-p (and tip (equal (plist-get ev :retention-oid) tip))
                  :tip-other-refs surviving-refs))))

(defun fleet-git--equivalence (ev)
  "Return (PROVED . DETAIL) for patch equivalence of the branch against the target."
  (let* ((branch-commits (plist-get ev :branch-commits))
         (all-commits (plist-get ev :branch-all-commits))
         (target-ids (mapcar #'cdr (plist-get ev :target-patch-ids)))
         (cum (plist-get ev :cumulative-patch-id))
         (cherry (plist-get ev :cherry)))
    (cond
     ((not (plist-get ev :target-oid)) (cons nil "no verified target"))
     ((not (plist-get ev :merge-base)) (cons nil "no merge base"))
     ((null all-commits) (cons nil "branch has no commits beyond merge base"))
     ((/= (length all-commits) (length branch-commits)) (cons nil "branch contains merge commits; equivalence not attempted"))
     ((cl-some #'null target-ids) (cons nil "could not compute a target patch id"))
     ((and cum (member cum target-ids)) (cons t "cumulative branch change matches a target commit patch-id"))
     ((and cherry (= (length cherry) (length branch-commits))
           (cl-every (lambda (l) (string-prefix-p "- " l)) cherry))
      (cons t "every branch commit has an equivalent patch in the target (git cherry)"))
     (t (cons nil "no patch equivalence proof; ancestry or retention required")))))

(cl-defun fleet-git-removal-decision (&key ev workspace-ownership branch-ownership delivery-mode verified)
  "Decide cleanup from judged evidence EV and task facts (design §11.3 table).
Returns (:remove-worktree BOOL :delete-branch BOOL :retain-required BOOL :refusals LIST :reasons LIST)."
  (let* ((refusals nil) (reasons nil)
         (owned-wt (equal workspace-ownership "fleet"))
         (owned-branch (equal branch-ownership "fleet"))
         (preserved (cond ((equal delivery-mode "local-ready") (plist-get ev :tip-retained-p))
                          ((equal delivery-mode "integrated") (or (plist-get ev :integrated-ancestry) (plist-get ev :integrated-equivalence)))
                          (t (or (plist-get ev :remote-preserved) (plist-get ev :integrated-ancestry)))))
         ;; The tip needs a retention ref when nothing that survives cleanup
         ;; still points at it: detached HEAD, or a Fleet-owned branch slated
         ;; for deletion with no other local ref, no advertised remote head,
         ;; and no ancestry in the target (equivalence does not keep identity).
         (retain-required (and (plist-get ev :tip)
                               (not (plist-get ev :tip-retained-p))
                               (not (plist-get ev :integrated-ancestry))
                               (or (null (plist-get ev :branch))
                                   (and owned-branch (null (plist-get ev :tip-other-refs)) (not (plist-get ev :remote-preserved)))))))
    (unless verified (push "deliverables not verified at current brief revision" refusals))
    (unless (plist-get ev :ok) (push (format "workspace uninspectable: %s" (plist-get ev :error)) refusals))
    (when (plist-get ev :dirty-p)
      (push (format "workspace has tracked/untracked/ignored content (%s)"
                    (let ((s (plist-get ev :status))) (if s (format "%d/%d/%d" (plist-get s :tracked) (plist-get s :untracked) (plist-get s :ignored)) (plist-get ev :status-error))))
            refusals))
    (unless preserved
      (push (format "delivery contract %s not satisfied by evidence" (or delivery-mode "remote-review")) refusals))
    (when (and (plist-get ev :recorded-branch-oid) (plist-get ev :tip)
               (plist-get ev :branch)
               (not (string= (plist-get ev :recorded-branch-oid) (plist-get ev :tip))))
      (push "worktree HEAD does not match its branch" refusals))
    (when retain-required (push "original tip has no surviving ref; retention ref required before removal" refusals))
    (when (plist-get ev :remote-preserved) (push (format "remote-preserved at %s" (plist-get ev :remote-preserved)) reasons))
    (when (plist-get ev :integrated-ancestry) (push "integrated by ancestry" reasons))
    (when (plist-get ev :integrated-equivalence) (push (format "integrated by patch equivalence (%s)" (plist-get ev :equivalence-detail)) reasons))
    (when (plist-get ev :tip-retained-p) (push (format "tip retained at %s" (plist-get ev :retention-ref)) reasons))
    (let ((remove-wt (and owned-wt (null refusals)))
          (delete-branch (and owned-branch (null refusals)
                              (not (equal delivery-mode "local-ready"))
                              (or (plist-get ev :remote-preserved) (plist-get ev :tip-retained-p) (plist-get ev :integrated-ancestry)))))
      (list :remove-worktree remove-wt :delete-branch delete-branch :retain-required retain-required
            :refusals (nreverse refusals) :reasons (nreverse reasons)
            :adopted-worktree (not owned-wt) :adopted-branch (and (plist-get ev :branch) (not owned-branch))))))

;;;; Retention and removal

(defun fleet-git-retain (repo task-id oid callback)
  "Create/verify refs/fleet/retained/TASK-ID at OID with CAS semantics; CALLBACK gets (:ok :ref :oid) or error."
  (let ((ref (format "refs/fleet/retained/%s" task-id)))
    (fleet-git-run repo (list "rev-parse" "--verify" "-q" ref)
                   (lambda (r)
                     (cond
                      ((and (fleet-git-ok-p r) (string= (fleet-git-out r) oid))
                       (funcall callback (list :ok t :ref ref :oid oid :existing t)))
                      ((fleet-git-ok-p r)
                       (funcall callback (list :ok nil :code 'retention-conflict :ref ref :existing (fleet-git-out r) :wanted oid
                                               :error "Retention ref exists at a different commit")))
                      (t
                       (fleet-git-run repo (list "update-ref" ref oid (make-string 40 ?0))
                                      (lambda (u)
                                        (if (fleet-git-ok-p u)
                                            (funcall callback (list :ok t :ref ref :oid oid))
                                          (funcall callback (list :ok nil :code 'retention-failed :error (plist-get u :stderr))))))))))))

(defun fleet-git-remove-worktree (repo path callback)
  "Remove Fleet-owned worktree PATH with native safety; CALLBACK gets result plist."
  (fleet-git-run repo (list "worktree" "remove" path)
                 (lambda (r)
                   (funcall callback (if (fleet-git-ok-p r) (list :ok t)
                                       (list :ok nil :code 'worktree-remove-refused :error (plist-get r :stderr)))))))

(defun fleet-git-delete-branch (repo branch callback)
  "Delete BRANCH with `git branch -d' only; refusal is reported, never forced."
  (fleet-git-run repo (list "branch" "-d" branch)
                 (lambda (r)
                   (funcall callback (if (fleet-git-ok-p r) (list :ok t)
                                       (list :ok nil :code 'branch-delete-refused :error (plist-get r :stderr)))))))

(provide 'fleet-git)
;;; fleet-git.el ends here
