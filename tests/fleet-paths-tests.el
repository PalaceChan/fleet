;;; fleet-paths-tests.el --- Tests for fleet-paths -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)
(require 'fleet-paths)
(require 'fleet-test-helpers)

(ert-deftest fleet-paths-name-grammar ()
  (should (fleet-paths-valid-name-p "compiler"))
  (should (fleet-paths-valid-name-p "a.b-c_d9"))
  (should-not (fleet-paths-valid-name-p "-leading"))
  (should-not (fleet-paths-valid-name-p ".hidden"))
  (should-not (fleet-paths-valid-name-p "has space"))
  (should-not (fleet-paths-valid-name-p "slash/x"))
  (should-not (fleet-paths-valid-name-p ""))
  (should-not (fleet-paths-valid-name-p (make-string 65 ?a)))
  (should-not (fleet-paths-valid-name-p "ünicode")))

(ert-deftest fleet-paths-containment-uses-directory-boundary ()
  (fleet-test-with-roots
    (let ((root (expand-file-name "foo" fleet-test--roots)))
      (make-directory root)
      (make-directory (expand-file-name "foobar" fleet-test--roots))
      (should (fleet-paths-contains-p root root))
      (should (fleet-paths-contains-p root (expand-file-name "x/y" root)))
      (should-not (fleet-paths-contains-p root (expand-file-name "foobar" fleet-test--roots)))
      (should-not (fleet-paths-contains-p root (expand-file-name "../foobar" root))))))

(ert-deftest fleet-paths-containment-resolves-symlinks ()
  (fleet-test-with-roots
    (let ((real (expand-file-name "real" fleet-test--roots))
          (link (expand-file-name "link" fleet-test--roots)))
      (make-directory real)
      (make-symbolic-link real link)
      (should (fleet-paths-contains-p real (expand-file-name "sub" link)))
      (should (string= (fleet-paths-canonical (expand-file-name "sub/deeper" link))
                       (expand-file-name "sub/deeper" (file-truename real)))))))

(ert-deftest fleet-paths-join-managed-rejects-escapes ()
  (fleet-test-with-roots
    (fleet-test-should-fail 'invalid-path (fleet-paths-join-managed fleet-data-root "../x"))
    (fleet-test-should-fail 'invalid-path (fleet-paths-join-managed fleet-data-root "/abs"))
    (fleet-test-should-fail 'invalid-path (fleet-paths-join-managed fleet-data-root "a/../../b"))
    (fleet-test-should-fail 'invalid-path (fleet-paths-join-managed fleet-data-root "a\0b"))
    (should (string-suffix-p "/fleets/abc" (fleet-paths-fleet-dir "abc")))))

(ert-deftest fleet-paths-uuid-shape-and-uniqueness ()
  (let ((ids (cl-loop repeat 200 collect (fleet-paths-uuid))))
    (dolist (id ids)
      (should (string-match-p "\\`[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-4[0-9a-f]\\{3\\}-[89ab][0-9a-f]\\{3\\}-[0-9a-f]\\{12\\}\\'" id)))
    (should (= (length ids) (length (delete-dups (copy-sequence ids)))))))

(ert-deftest fleet-paths-atomic-write-and-hash ()
  (fleet-test-with-roots
    (let ((f (expand-file-name "sub/dir/file.md" fleet-data-root)))
      (fleet-paths-write-atomically f "héllo\n" #o600)
      (should (string= (fleet-paths-read-file f) "héllo\n"))
      (should (string= (fleet-paths-sha256-file f) (fleet-paths-sha256-string "héllo\n")))
      (should (= (file-modes f) #o600))
      ;; no temp leftovers
      (should-not (directory-files (file-name-directory f) nil "\\`\\.fleet-tmp-")))))

(ert-deftest fleet-paths-tree-digest-is-deterministic-and-content-bound ()
  (fleet-test-with-roots
    (let ((dir (expand-file-name "bundle" fleet-data-root)))
      (fleet-paths-write-atomically (expand-file-name "live/a.py" dir) "print(1)\n")
      (fleet-paths-write-atomically (expand-file-name "manifest.sha256" dir) "abc\n")
      (make-directory (expand-file-name "empty-sub" dir))
      (make-symbolic-link "live/a.py" (expand-file-name "link" dir))
      (let ((h1 (fleet-paths-sha256-path dir)))
        (should (= 64 (length h1)))
        (should (string= h1 (fleet-paths-sha256-tree dir)))
        ;; The same tree elsewhere digests identically (relative paths, not absolute).
        (let ((copy (expand-file-name "bundle-copy" fleet-data-root)))
          (copy-directory dir copy nil nil t)
          (should (string= h1 (fleet-paths-sha256-path copy))))
        ;; Content change, new file, and retargeted link all change the digest.
        (fleet-paths-write-atomically (expand-file-name "live/a.py" dir) "print(2)\n")
        (let ((h2 (fleet-paths-sha256-path dir)))
          (should-not (string= h1 h2))
          (fleet-paths-write-atomically (expand-file-name "live/b.py" dir) "")
          (let ((h3 (fleet-paths-sha256-path dir)))
            (should-not (string= h2 h3))
            (delete-file (expand-file-name "link" dir))
            (make-symbolic-link "manifest.sha256" (expand-file-name "link" dir))
            (should-not (string= h3 (fleet-paths-sha256-path dir))))))
      ;; Files still digest as before; missing paths are nil.
      (should (string= (fleet-paths-sha256-path (expand-file-name "manifest.sha256" dir)) (fleet-paths-sha256-string "abc\n")))
      (should-not (fleet-paths-sha256-path (expand-file-name "nope" dir)))
      ;; An empty directory is not a deliverable.
      (fleet-test-should-fail 'artifact-empty (fleet-paths-sha256-path (expand-file-name "empty-sub" dir)))
      ;; Special files are refused, inside a tree and directly.
      (let ((fifo (expand-file-name "pipe" dir)))
        (when (zerop (call-process "mkfifo" nil nil nil fifo))
          (fleet-test-should-fail 'artifact-unreadable (fleet-paths-sha256-path fifo))
          (fleet-test-should-fail 'artifact-unreadable (fleet-paths-sha256-path dir)))))))

(ert-deftest fleet-paths-runtime-root-validation ()
  (fleet-test-with-roots
    (should (string= (fleet-paths-runtime-root) (expand-file-name fleet-runtime-root)))
    (let ((fleet-runtime-root nil))
      (with-environment-variables (("XDG_RUNTIME_DIR" ""))
        (fleet-test-should-fail 'runtime-root-unsafe (fleet-paths-runtime-root))))
    (let ((fleet-runtime-root "/nonexistent-parent-xyz/fleet"))
      (fleet-test-should-fail 'runtime-root-unsafe (fleet-paths-runtime-root)))))

(ert-deftest fleet-paths-worktree-dir-is-bounded ()
  (fleet-test-with-roots
    (let ((d (fleet-paths-worktree-dir (make-string 80 ?r) (make-string 80 ?f) (make-string 80 ?t)
                                       "0123456789abcdef-0000")))
      (should (fleet-paths-contains-p (fleet-paths-worktree-root) d))
      (should (< (length (file-name-nondirectory d)) 90))
      (should (string-suffix-p "-01234567" d)))))

(provide 'fleet-paths-tests)
;;; fleet-paths-tests.el ends here
