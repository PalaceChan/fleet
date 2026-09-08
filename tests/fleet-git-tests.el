;;; fleet-git-tests.el --- Tests for fleet-git -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)
(require 'fleet-git)
(require 'fleet-test-helpers)

(defun fleet-git-test-git (dir &rest args)
  "Run git ARGS synchronously in DIR for fixture setup; return trimmed stdout."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (eql 0 (apply #'call-process "git" nil t nil args))
        (error "fixture git %S failed: %s" args (buffer-string)))
      (string-trim (buffer-string)))))

(defun fleet-git-test-repo (name &optional default-branch)
  "Create a repo NAME under the dev root with one commit; return its path."
  (let ((dir (expand-file-name name fleet-development-root)))
    (make-directory dir t)
    (fleet-git-test-git dir "init" "-q" "-b" (or default-branch "main"))
    (fleet-git-test-git dir "config" "user.email" "t@example.com")
    (fleet-git-test-git dir "config" "user.name" "T")
    (fleet-test-write (expand-file-name "README" dir) "hello\n")
    (fleet-git-test-git dir "add" "README")
    (fleet-git-test-git dir "commit" "-q" "-m" "init")
    dir))

(defun fleet-git-test-commit (dir file content msg)
  "Commit CONTENT to FILE in DIR with MSG; return the OID."
  (fleet-test-write (expand-file-name file dir) content)
  (fleet-git-test-git dir "add" file)
  (fleet-git-test-git dir "commit" "-q" "-m" msg)
  (fleet-git-test-git dir "rev-parse" "HEAD"))

(defmacro fleet-git-test-sync (fn &rest args)
  "Call async FN with ARGS plus a callback; return the callback value."
  `(let (result done)
     (,fn ,@args (lambda (r) (setq result r done t)))
     (unless (fleet-test-wait-for (lambda () done) 20) (error "timeout waiting for %s" ',fn))
     result))

(defmacro fleet-git-test-sync-kw (fn &rest args)
  "Like `fleet-git-test-sync' for keyword-callback functions."
  `(let (result done)
     (,fn ,@args :callback (lambda (r) (setq result r done t)))
     (unless (fleet-test-wait-for (lambda () done) 20) (error "timeout waiting for %s" ',fn))
     result))

(defun fleet-git-test-evidence (ws repo &rest kw)
  "Collect judged evidence for WS with keyword args KW (repo/branch/remote/target/base-oid/task-id)."
  (let (result done)
    (apply #'fleet-git-collect-evidence :workspace ws :repo repo
           :callback (lambda (r) (setq result r done t)) kw)
    (unless (fleet-test-wait-for (lambda () done) 30) (error "timeout evidence"))
    result))

(ert-deftest fleet-git-identity-and-worktree-list ()
  (fleet-test-with-roots
    (let* ((repo (fleet-git-test-repo "r1"))
           (id (fleet-git-test-sync fleet-git-repo-identity repo)))
      (should (equal (plist-get id :toplevel) (fleet-paths-canonical repo)))
      (should (equal (plist-get id :branch) "main"))
      (should (string-suffix-p "/.git" (plist-get id :common-dir)))
      (should (equal (plist-get id :main-worktree) (fleet-paths-canonical repo)))
      (should (plist-get (fleet-git-test-sync fleet-git-repo-identity fleet-test--roots) :error)))))

(ert-deftest fleet-git-create-worktree-fresh-branch-and-refusals ()
  (fleet-test-with-roots
    (let* ((repo (fleet-git-test-repo "r2"))
           (base (fleet-git-test-git repo "rev-parse" "HEAD"))
           (wt (fleet-paths-worktree-dir "r2" "f" "t" "0123456789abcdef"))
           (r (fleet-git-test-sync-kw fleet-git-create-worktree :repo repo :path wt :branch "fleet/f/t" :base-oid base)))
      (should (plist-get r :ok))
      (should (equal (plist-get (plist-get r :identity) :branch) "fleet/f/t"))
      (should (equal (plist-get (plist-get r :identity) :head) base))
      ;; primary clone untouched
      (should (equal (fleet-git-test-git repo "symbolic-ref" "--short" "HEAD") "main"))
      ;; same branch again is refused
      (let ((r2 (fleet-git-test-sync-kw fleet-git-create-worktree :repo repo :path (concat wt "-2") :branch "fleet/f/t" :base-oid base)))
        (should-not (plist-get r2 :ok))
        (should (eq (plist-get r2 :code) 'branch-exists)))
      ;; existing path is refused
      (let ((r3 (fleet-git-test-sync-kw fleet-git-create-worktree :repo repo :path wt :branch "other" :base-oid base)))
        (should (eq (plist-get r3 :code) 'workspace-exists))))))

(ert-deftest fleet-git-adopt-branch-refuses-checked-out ()
  (fleet-test-with-roots
    (let* ((repo (fleet-git-test-repo "r3"))
           (wt (expand-file-name "wt" fleet-test--roots)))
      ;; main is checked out in the primary clone
      (let ((r (fleet-git-test-sync-kw fleet-git-adopt-branch :repo repo :path wt :branch "main")))
        (should-not (plist-get r :ok))
        (should (eq (plist-get r :code) 'branch-checked-out)))
      (fleet-git-test-git repo "branch" "feature")
      (let ((r (fleet-git-test-sync-kw fleet-git-adopt-branch :repo repo :path wt :branch "feature")))
        (should (plist-get r :ok))
        (should (equal (plist-get (plist-get r :identity) :branch) "feature")))
      (let ((r (fleet-git-test-sync-kw fleet-git-adopt-branch :repo repo :path (concat wt "2") :branch "nope")))
        (should (eq (plist-get r :code) 'branch-missing))))))

(ert-deftest fleet-git-adopt-worktree-validates-identity ()
  (fleet-test-with-roots
    (let* ((repo (fleet-git-test-repo "r4"))
           (wt (expand-file-name "wt with space/ü" fleet-test--roots)))
      (make-directory (file-name-directory wt) t)
      (fleet-git-test-git repo "worktree" "add" "-q" "-b" "adopted" wt)
      (let ((r (fleet-git-test-sync-kw fleet-git-adopt-worktree :repo repo :path wt)))
        (should (plist-get r :ok))
        (should (equal (plist-get (plist-get r :entry) :branch) "adopted")))
      ;; primary clone refused
      (should (eq (plist-get (fleet-git-test-sync-kw fleet-git-adopt-worktree :repo repo :path repo) :code) 'primary-clone))
      ;; symlink alias of the worktree resolves to the same identity
      (let ((link (expand-file-name "wtlink" fleet-test--roots)))
        (make-symbolic-link wt link)
        (should (plist-get (fleet-git-test-sync-kw fleet-git-adopt-worktree :repo repo :path link) :ok)))
      ;; random directory refused
      (should (eq (plist-get (fleet-git-test-sync-kw fleet-git-adopt-worktree :repo repo :path fleet-test--roots) :code) 'not-a-worktree)))))

(ert-deftest fleet-git-status-z-parse ()
  (let ((p (fleet-git-parse-status-z " M a.txt\0?? new file.txt\0!! build/\0R  new\0old\0")))
    (should (= 2 (plist-get p :tracked)))
    (should (= 1 (plist-get p :untracked)))
    (should (= 1 (plist-get p :ignored)))
    (should (equal '("??" "new file.txt") (nth 1 (plist-get p :entries)))))
  (should (equal (fleet-git-parse-status-z "") '(:tracked 0 :untracked 0 :ignored 0 :entries nil))))

(ert-deftest fleet-git-evidence-remote-preserved-nonorigin-remote ()
  (fleet-test-with-roots
    (let* ((upstream (fleet-git-test-repo "up"))
           (repo (expand-file-name "clone" fleet-development-root)))
      (fleet-git-test-git fleet-development-root "clone" "-q" "-o" "hub" upstream repo)
      (fleet-git-test-git repo "config" "user.email" "t@example.com")
      (fleet-git-test-git repo "config" "user.name" "T")
      (let* ((base (fleet-git-test-git repo "rev-parse" "HEAD"))
             (wt (expand-file-name "wt" fleet-test--roots)))
        (fleet-git-test-git repo "worktree" "add" "-q" "-b" "fleet/x" wt base)
        (fleet-git-test-git wt "config" "user.email" "t@example.com")
        (fleet-git-test-git wt "config" "user.name" "T")
        (let ((tip (fleet-git-test-commit wt "f.txt" "x\n" "work")))
          ;; before push: not preserved, dirty=nil
          (let ((ev (fleet-git-test-evidence wt repo :branch "fleet/x" :remote "hub" :target "main" :base-oid base :task-id "task1")))
            (should (plist-get ev :ok))
            (should-not (plist-get ev :dirty-p))
            (should-not (plist-get ev :remote-preserved))
            (should-not (plist-get ev :integrated-ancestry))
            (let ((d (fleet-git-removal-decision :ev ev :workspace-ownership "fleet" :branch-ownership "fleet" :delivery-mode "remote-review" :verified t)))
              (should-not (plist-get d :remove-worktree))
              (should (cl-some (lambda (s) (string-match-p "delivery contract" s)) (plist-get d :refusals)))))
          ;; push under an arbitrary branch name to the non-origin remote
          (fleet-git-test-git wt "push" "-q" "hub" "fleet/x:review/anything")
          (let ((ev (fleet-git-test-evidence wt repo :branch "fleet/x" :remote "hub" :target "main" :base-oid base :task-id "task1")))
            (should (equal (plist-get ev :remote-preserved) "refs/heads/review/anything"))
            (should (equal (plist-get ev :tip) tip))
            (should-not (plist-get ev :integrated-ancestry))
            (let ((d (fleet-git-removal-decision :ev ev :workspace-ownership "fleet" :branch-ownership "fleet" :delivery-mode "remote-review" :verified t)))
              (should (plist-get d :remove-worktree))
              (should (plist-get d :delete-branch))
              (should (null (plist-get d :refusals)))))
          ;; not verified => refused regardless
          (let* ((ev (fleet-git-test-evidence wt repo :branch "fleet/x" :remote "hub" :target "main" :base-oid base :task-id "task1"))
                 (d (fleet-git-removal-decision :ev ev :workspace-ownership "fleet" :branch-ownership "fleet" :delivery-mode "remote-review" :verified nil)))
            (should-not (plist-get d :remove-worktree))))))))

(ert-deftest fleet-git-evidence-dirty-ignored-refuses ()
  (fleet-test-with-roots
    (let* ((repo (fleet-git-test-repo "r5"))
           (base (fleet-git-test-git repo "rev-parse" "HEAD"))
           (wt (expand-file-name "wt" fleet-test--roots)))
      (fleet-git-test-git repo "worktree" "add" "-q" "-b" "b" wt base)
      (fleet-test-write (expand-file-name ".gitignore" wt) "notes.txt\n")
      (fleet-git-test-git wt "add" ".gitignore")
      (fleet-git-test-git wt "-c" "user.email=t@e" "-c" "user.name=T" "commit" "-q" "-m" "ignore")
      (fleet-test-write (expand-file-name "notes.txt" wt) "human notes\n")
      (let* ((ev (fleet-git-test-evidence wt repo :branch "b" :base-oid base :task-id "t"))
             (d (fleet-git-removal-decision :ev ev :workspace-ownership "fleet" :branch-ownership "fleet" :delivery-mode "local-ready" :verified t)))
        (should (plist-get ev :dirty-p))
        (should (= 1 (plist-get (plist-get ev :status) :ignored)))
        (should-not (plist-get d :remove-worktree))
        (should (cl-some (lambda (s) (string-match-p "ignored" s)) (plist-get d :refusals)))
        ;; Native git would happily remove a worktree holding only ignored
        ;; files, which is why Fleet's gate refuses first.  With untracked
        ;; content native git refuses too, and nothing is deleted.
        (fleet-test-write (expand-file-name "scratch.txt" wt) "untracked\n")
        (let ((r (fleet-git-test-sync fleet-git-remove-worktree repo wt)))
          (should-not (plist-get r :ok))
          (should (eq (plist-get r :code) 'worktree-remove-refused))
          (should (file-exists-p (expand-file-name "notes.txt" wt))))))))

(ert-deftest fleet-git-evidence-ancestry-and-squash-equivalence ()
  (fleet-test-with-roots
    (let* ((repo (fleet-git-test-repo "r6"))
           (base (fleet-git-test-git repo "rev-parse" "HEAD"))
           (wt (expand-file-name "wt" fleet-test--roots)))
      (fleet-git-test-git repo "worktree" "add" "-q" "-b" "feat" wt base)
      (fleet-git-test-git wt "config" "user.email" "t@e") (fleet-git-test-git wt "config" "user.name" "T")
      (fleet-git-test-commit wt "a.txt" "a\n" "one")
      (let ((tip (fleet-git-test-commit wt "b.txt" "b\n" "two")))
        ;; Squash-merge into main: equivalence, not ancestry.
        (fleet-git-test-git repo "merge" "-q" "--squash" "feat")
        (fleet-git-test-git repo "commit" "-q" "-m" "squashed feat")
        (let ((ev (fleet-git-test-evidence wt repo :branch "feat" :target "main" :base-oid base :task-id "t6")))
          (should-not (plist-get ev :integrated-ancestry))
          (should (plist-get ev :integrated-equivalence))
          (should (string-match-p "cumulative" (plist-get ev :equivalence-detail)))
          (let ((d (fleet-git-removal-decision :ev ev :workspace-ownership "fleet" :branch-ownership "fleet" :delivery-mode "integrated" :verified t)))
            ;; equivalence proves integration but not identity retention: retention required first
            (should (plist-get d :retain-required))
            (should-not (plist-get d :remove-worktree))))
        ;; Retain the tip, then removal is permitted.
        (let ((r (fleet-git-test-sync fleet-git-retain repo "t6" tip)))
          (should (plist-get r :ok))
          (should (equal (plist-get r :ref) "refs/fleet/retained/t6")))
        ;; CAS: same oid ok, different oid refused
        (should (plist-get (fleet-git-test-sync fleet-git-retain repo "t6" tip) :existing))
        (should (eq (plist-get (fleet-git-test-sync fleet-git-retain repo "t6" base) :code) 'retention-conflict))
        (let* ((ev (fleet-git-test-evidence wt repo :branch "feat" :target "main" :base-oid base :task-id "t6"))
               (d (fleet-git-removal-decision :ev ev :workspace-ownership "fleet" :branch-ownership "fleet" :delivery-mode "integrated" :verified t)))
          (should (plist-get ev :tip-retained-p))
          (should (plist-get d :remove-worktree))
          (should (null (plist-get d :refusals))))
        ;; Edited squash (extra change) => no equivalence proof
        (fleet-git-test-commit repo "a.txt" "edited\n" "edit after squash")
        (fleet-git-test-git repo "reset" "-q" "--soft" "HEAD~2")
        (fleet-git-test-git repo "commit" "-q" "-m" "edited squash")
        (let ((ev (fleet-git-test-evidence wt repo :branch "feat" :target "main" :base-oid base :task-id "t6")))
          (should-not (plist-get ev :integrated-equivalence))
          (should-not (plist-get ev :integrated-ancestry)))))))

(ert-deftest fleet-git-evidence-ancestry-after-real-merge ()
  (fleet-test-with-roots
    (let* ((repo (fleet-git-test-repo "r6b"))
           (base (fleet-git-test-git repo "rev-parse" "HEAD"))
           (wt (expand-file-name "wt" fleet-test--roots)))
      (fleet-git-test-git repo "worktree" "add" "-q" "-b" "feat" wt base)
      (fleet-git-test-git wt "config" "user.email" "t@e") (fleet-git-test-git wt "config" "user.name" "T")
      (fleet-git-test-commit wt "a.txt" "a\n" "one")
      ;; diverge main so the merge is a true merge commit, then merge feat in
      (fleet-git-test-commit repo "m.txt" "m\n" "main moves")
      (fleet-git-test-git repo "merge" "-q" "--no-edit" "feat")
      (let* ((ev (fleet-git-test-evidence wt repo :branch "feat" :target "main" :base-oid base :task-id "t6b"))
             (d (fleet-git-removal-decision :ev ev :workspace-ownership "fleet" :branch-ownership "fleet" :delivery-mode "integrated" :verified t)))
        (should (plist-get ev :integrated-ancestry))
        ;; the branch ref survives until branch -d, and the tip is reachable from main: no retention needed
        (should-not (plist-get d :retain-required))
        (should (plist-get d :remove-worktree))
        (should (plist-get d :delete-branch))
        (should (plist-get (fleet-git-test-sync fleet-git-remove-worktree repo wt) :ok))
        (should (plist-get (fleet-git-test-sync fleet-git-delete-branch repo "feat") :ok))))))

(ert-deftest fleet-git-local-ready-retention-and-branch-kept ()
  (fleet-test-with-roots
    (let* ((repo (fleet-git-test-repo "r7" "trunk"))
           (base (fleet-git-test-git repo "rev-parse" "HEAD"))
           (wt (expand-file-name "wt" fleet-test--roots)))
      ;; single local branch, no remote: it is the default; nothing is assumed
      (should (equal (fleet-git-test-sync fleet-git-default-branch repo nil) "trunk"))
      (should (null (fleet-git-test-sync fleet-git-remotes repo)))
      (fleet-git-test-git repo "worktree" "add" "-q" "-b" "ready" wt base)
      (fleet-git-test-git wt "config" "user.email" "t@e") (fleet-git-test-git wt "config" "user.name" "T")
      (let ((tip (fleet-git-test-commit wt "c.txt" "c\n" "ready work")))
        ;; two unrelated branch names: ambiguous, so nil rather than a guess
        (should (null (fleet-git-test-sync fleet-git-default-branch repo nil)))
        (let* ((ev (fleet-git-test-evidence wt repo :branch "ready" :base-oid base :task-id "t7"))
               (d (fleet-git-removal-decision :ev ev :workspace-ownership "fleet" :branch-ownership "fleet" :delivery-mode "local-ready" :verified t)))
          (should-not (plist-get d :remove-worktree)))
        (should (plist-get (fleet-git-test-sync fleet-git-retain repo "t7" tip) :ok))
        (let* ((ev (fleet-git-test-evidence wt repo :branch "ready" :base-oid base :task-id "t7"))
               (d (fleet-git-removal-decision :ev ev :workspace-ownership "fleet" :branch-ownership "fleet" :delivery-mode "local-ready" :verified t)))
          (should (plist-get d :remove-worktree))
          ;; local-ready never deletes the branch
          (should-not (plist-get d :delete-branch))
          (should (plist-get (fleet-git-test-sync fleet-git-remove-worktree repo wt) :ok))
          (should-not (file-exists-p wt))
          (should (equal tip (fleet-git-test-git repo "rev-parse" "ready"))))))))

(ert-deftest fleet-git-adopted-resources-never-removed ()
  (let* ((ev '(:ok t :tip "abc" :branch "adopted" :dirty-p nil :remote-preserved "refs/heads/x" :retention-oid nil :refs-at-tip ("refs/heads/adopted")))
         (d (fleet-git-removal-decision :ev (fleet-git-judge ev) :workspace-ownership "adopted" :branch-ownership "adopted"
                                        :delivery-mode "remote-review" :verified t)))
    (should-not (plist-get d :remove-worktree))
    (should-not (plist-get d :delete-branch))
    (should (plist-get d :adopted-worktree))
    (should (plist-get d :adopted-branch))))

(ert-deftest fleet-git-detached-tip-requires-retention ()
  (let* ((ev (fleet-git-judge '(:ok t :tip "deadbeef" :branch nil :status (:tracked 0 :untracked 0 :ignored 0 :entries nil)
                                    :remote-preserved "refs/heads/r" :refs-at-tip nil :retention-oid nil)))
         (d (fleet-git-removal-decision :ev ev :workspace-ownership "fleet" :branch-ownership "fleet" :delivery-mode "remote-review" :verified t)))
    (should (plist-get d :retain-required))
    (should-not (plist-get d :remove-worktree))))

(ert-deftest fleet-git-branch-delete-refusal-visible ()
  (fleet-test-with-roots
    (let* ((repo (fleet-git-test-repo "r8"))
           (base (fleet-git-test-git repo "rev-parse" "HEAD")))
      (fleet-git-test-git repo "branch" "unmerged" base)
      (fleet-git-test-git repo "checkout" "-q" "unmerged")
      (fleet-git-test-commit repo "z.txt" "z\n" "z")
      (fleet-git-test-git repo "checkout" "-q" "main")
      (let ((r (fleet-git-test-sync fleet-git-delete-branch repo "unmerged")))
        (should-not (plist-get r :ok))
        (should (eq (plist-get r :code) 'branch-delete-refused))
        (should (fleet-git-test-git repo "rev-parse" "--verify" "unmerged"))))))

(provide 'fleet-git-tests)
;;; fleet-git-tests.el ends here
