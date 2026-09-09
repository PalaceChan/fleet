;;; fleet-paths.el --- Fleet path/config resolution and identifiers -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Single owner of directory resolution, canonicalization, containment
;; checks, identifiers, and atomic file publication.  No other module
;; reconstructs a root from environment variables.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup fleet nil
  "Emacs-native orchestration of ECA agents."
  :group 'tools
  :prefix "fleet-")

;;;; Errors

(define-error 'fleet-error "Fleet error")

(defun fleet-fail (code message &rest evidence)
  "Signal a structured `fleet-error' with stable CODE, MESSAGE and EVIDENCE plist."
  (signal 'fleet-error (list code message evidence)))

(defun fleet-error-code (err) "Return the stable code of `fleet-error' ERR." (nth 1 err))
(defun fleet-error-message (err) "Return the message of `fleet-error' ERR." (nth 2 err))
(defun fleet-error-evidence (err) "Return the evidence plist of `fleet-error' ERR." (nth 3 err))

(defun fleet-error-string (err)
  "Render `fleet-error' ERR for humans."
  (if (eq (car err) 'fleet-error)
      (format "%s: %s%s" (fleet-error-code err) (fleet-error-message err)
              (if (fleet-error-evidence err)
                  (format " %S" (fleet-error-evidence err))
                ""))
    (error-message-string err)))

;;;; Configuration surface (see design §17)

(defcustom fleet-development-root "~/development"
  "Directory holding primary development clones."
  :type 'directory :group 'fleet)

(defcustom fleet-worktree-root nil
  "Directory for Fleet-created worktrees.
When nil, derived as `.worktrees' under `fleet-development-root'."
  :type '(choice (const nil) directory) :group 'fleet)

(defcustom fleet-data-root nil
  "Authoritative database and artifact root.  Nil means XDG data default."
  :type '(choice (const nil) directory) :group 'fleet)

(defcustom fleet-cache-root nil
  "Disposable cache root.  Nil means XDG cache default."
  :type '(choice (const nil) directory) :group 'fleet)

(defcustom fleet-config-root nil
  "Fleet user configuration root.  Nil means XDG config default."
  :type '(choice (const nil) directory) :group 'fleet)

(defcustom fleet-runtime-root nil
  "Runtime root for the control socket and ephemeral credentials.
Nil means `$XDG_RUNTIME_DIR/fleet'.  Must be local and user-owned."
  :type '(choice (const nil) directory) :group 'fleet)

(defcustom fleet-eca-command nil
  "Native ECA server command as an argument vector, e.g. (\"/path/eca\" \"server\").
Nil discovers the executable the installed ECA package would use."
  :type '(choice (const nil) (repeat string)) :group 'fleet)

(defcustom fleet-python-executable "/usr/bin/python3"
  "Absolute path of the Python 3.11+ interpreter for the bridge."
  :type 'file :group 'fleet)

(defcustom fleet-commander-model nil
  "ECA provider/model id for commanders.  Nil uses the ECA default."
  :type '(choice (const nil) string) :group 'fleet)

(defcustom fleet-operator-model nil
  "ECA provider/model id for operators.  Nil uses the ECA default."
  :type '(choice (const nil) string) :group 'fleet)

(defcustom fleet-commander-variant nil
  "ECA model variant (e.g. \"high\") for commanders.  Nil uses the server default."
  :type '(choice (const nil) string) :group 'fleet)

(defcustom fleet-operator-variant nil
  "ECA model variant for operators.  Nil uses the server default.
Per-task overrides come from the commander via fleet_task_create."
  :type '(choice (const nil) string) :group 'fleet)

(defcustom fleet-agent nil
  "ECA chat agent name used for Fleet runtimes.  Nil uses the server default."
  :type '(choice (const nil) string) :group 'fleet)

;;;; XDG roots

(defun fleet-paths--xdg (var default)
  "Return environment VAR as directory or DEFAULT (relative to HOME)."
  (let ((v (getenv var)))
    (if (and v (not (string-empty-p v)) (file-name-absolute-p v))
        v
      (expand-file-name default "~"))))

(defun fleet-paths-development-root ()
  "Canonical development root."
  (fleet-paths-canonical fleet-development-root))

(defun fleet-paths-worktree-root ()
  "Canonical worktree root (derived unless overridden)."
  (fleet-paths-canonical (or fleet-worktree-root
                             (expand-file-name ".worktrees" (fleet-paths-development-root)))))

(defun fleet-paths-data-root ()
  "Canonical data root."
  (fleet-paths-canonical (or fleet-data-root
                             (expand-file-name "fleet" (fleet-paths--xdg "XDG_DATA_HOME" ".local/share")))))

(defun fleet-paths-cache-root ()
  "Canonical cache root."
  (fleet-paths-canonical (or fleet-cache-root
                             (expand-file-name "fleet" (fleet-paths--xdg "XDG_CACHE_HOME" ".cache")))))

(defun fleet-paths-config-root ()
  "Canonical config root."
  (fleet-paths-canonical (or fleet-config-root
                             (expand-file-name "fleet" (fleet-paths--xdg "XDG_CONFIG_HOME" ".config")))))

(defun fleet-paths-runtime-root ()
  "Canonical runtime root, or signal `runtime-root-unsafe'.
Never falls back to a TCP port or a world-readable directory."
  (let* ((xdg (getenv "XDG_RUNTIME_DIR"))
         (root (or fleet-runtime-root
                   (and xdg (not (string-empty-p xdg)) (expand-file-name "fleet" xdg)))))
    (unless root
      (fleet-fail 'runtime-root-unsafe "XDG_RUNTIME_DIR is not set and `fleet-runtime-root' is nil"))
    (let ((parent (file-name-directory (directory-file-name (expand-file-name root)))))
      (unless (file-directory-p parent)
        (fleet-fail 'runtime-root-unsafe "Runtime parent directory does not exist" :parent parent))
      (when (file-remote-p parent)
        (fleet-fail 'runtime-root-unsafe "Runtime root must be local" :parent parent))
      (let ((attrs (file-attributes parent 'integer)))
        (unless (eql (file-attribute-user-id attrs) (user-uid))
          (fleet-fail 'runtime-root-unsafe "Runtime parent not owned by current user"
                      :parent parent :owner (file-attribute-user-id attrs)))))
    (expand-file-name root)))

(defun fleet-paths-eca-config-root ()
  "ECA's ordinary global configuration directory."
  (expand-file-name "eca" (fleet-paths--xdg "XDG_CONFIG_HOME" ".config")))

;;;; Canonicalization and containment

(defun fleet-paths-canonical (path)
  "Expand PATH; resolve symlinks for the longest existing prefix.
Returns a directory-form-free absolute path (no trailing slash)."
  (let* ((expanded (directory-file-name (expand-file-name path)))
         (existing expanded)
         (rest nil))
    (while (and (not (file-exists-p existing))
                (not (equal existing (directory-file-name (file-name-directory existing)))))
      (push (file-name-nondirectory existing) rest)
      (setq existing (directory-file-name (file-name-directory existing))))
    (let ((base (if (file-exists-p existing) (directory-file-name (file-truename existing)) existing)))
      (if rest
          (directory-file-name (apply #'file-name-concat base rest))
        base))))

(defun fleet-paths-contains-p (parent child)
  "Return non-nil when canonical CHILD is PARENT or lies strictly beneath it.
Uses a directory boundary, never a bare string prefix."
  (let ((p (file-name-as-directory (fleet-paths-canonical parent)))
        (c (fleet-paths-canonical child)))
    (or (string= (directory-file-name p) c)
        (string-prefix-p p (file-name-as-directory c)))))

(defun fleet-paths-assert-safe-relative (rel)
  "Signal unless REL is a safe relative path component sequence."
  (when (or (not (stringp rel))
            (string-empty-p rel)
            (string-match-p "\0" rel)
            (file-name-absolute-p rel)
            (cl-some (lambda (seg) (member seg '("" "." "..")))
                     (split-string rel "/")))
    (fleet-fail 'invalid-path "Unsafe relative path" :path rel))
  rel)

(defun fleet-paths-join-managed (root rel)
  "Join safe relative REL under canonical ROOT, refusing escapes."
  (fleet-paths-assert-safe-relative rel)
  (let ((joined (expand-file-name rel root)))
    (unless (fleet-paths-contains-p root joined)
      (fleet-fail 'invalid-path "Path escapes its root" :root root :path rel))
    joined))

;;;; Names and identifiers

(defconst fleet-paths-name-regexp "\\`[A-Za-z0-9][A-Za-z0-9._-]*\\'"
  "Grammar for human fleet/task names.")

(defconst fleet-paths-name-max-length 64)

(defun fleet-paths-valid-name-p (name)
  "Return non-nil when NAME satisfies the documented name grammar."
  (and (stringp name)
       (<= (length name) fleet-paths-name-max-length)
       (string-match-p fleet-paths-name-regexp name)
       (not (member name '("." "..")))
       t))

(defun fleet-paths-assert-name (name what)
  "Signal `invalid-name' unless NAME is valid; WHAT names the field."
  (unless (fleet-paths-valid-name-p name)
    (fleet-fail 'invalid-name (format "Invalid %s name" what) :name name))
  name)

(defun fleet-paths-uuid ()
  "Return a random v4 UUID string.
Reseeds from system entropy so consecutive ids never repeat."
  (random t)
  (format "%08x-%04x-4%03x-%04x-%012x"
          (random (ash 1 32))
          (random (ash 1 16))
          (random (ash 1 12))
          (logior #x8000 (random (ash 1 14)))
          (random (ash 1 48))))

(defun fleet-paths-short-id (uuid)
  "First 8 characters of UUID (whole string when shorter)."
  (substring uuid 0 (min 8 (length uuid))))

(defun fleet-paths-root-hash ()
  "Short stable hash of the data root, for socket/descriptor disambiguation."
  (substring (secure-hash 'sha256 (fleet-paths-data-root)) 0 10))

(defun fleet-paths-boot-id ()
  "Kernel boot id, or nil when unavailable."
  (when (file-readable-p "/proc/sys/kernel/random/boot_id")
    (with-temp-buffer
      (insert-file-contents "/proc/sys/kernel/random/boot_id")
      (string-trim (buffer-string)))))

(defun fleet-paths-now ()
  "UTC timestamp string with millisecond precision."
  (format-time-string "%Y-%m-%dT%H:%M:%S.%3NZ" nil t))

(defun fleet-paths-time-float (iso)
  "Seconds since the epoch for the `fleet-paths-now' style string ISO, or nil.
`date-to-time' discards fractional seconds, which made every sub-second
latency in the telemetry read as 0ms; the fraction is added back here."
  (when (stringp iso)
    (let ((whole (ignore-errors (float-time (date-to-time iso))))
          (frac (and (string-match "\\.\\([0-9]+\\)Z?\\'" iso)
                     (/ (float (string-to-number (match-string 1 iso)))
                        (expt 10 (length (match-string 1 iso)))))))
      (and whole (+ whole (or frac 0.0))))))

(defun fleet-paths-seconds-between (from to)
  "Float seconds from ISO timestamp FROM to TO, or nil when either is missing."
  (let ((a (fleet-paths-time-float from)) (b (fleet-paths-time-float to)))
    (and a b (- b a))))

;;;; Derived locations

(defun fleet-paths-db-file () "Authoritative database path." (expand-file-name "fleet.sqlite3" (fleet-paths-data-root)))
(defun fleet-paths-owner-lock () "Stable owner lock path." (expand-file-name "owner.lock" (fleet-paths-data-root)))
(defun fleet-paths-owner-descriptor () "Owner descriptor path." (expand-file-name "owner.json" (fleet-paths-data-root)))

(defun fleet-paths-fleets-root () "Directory of all fleet artifact trees." (expand-file-name "fleets" (fleet-paths-data-root)))
(defun fleet-paths-fleet-dir (fleet-id) "Artifact root of FLEET-ID." (fleet-paths-join-managed (fleet-paths-fleets-root) fleet-id))
(defun fleet-paths-fleet-archive-dir (fleet-id)
  "Archive location for FLEET-ID's artifact tree after retirement."
  (fleet-paths-join-managed (fleet-paths-fleets-root) (concat ".archive/" fleet-id)))
(defun fleet-paths-task-dir (fleet-id task-id) "Task directory." (fleet-paths-join-managed (fleet-paths-fleet-dir fleet-id) (concat "tasks/" task-id)))
(defun fleet-paths-commander-dir (fleet-id) "Commander directory." (fleet-paths-join-managed (fleet-paths-fleet-dir fleet-id) "commander"))
(defun fleet-paths-run-dir (owner-dir runtime-id) "Run directory for RUNTIME-ID under OWNER-DIR." (fleet-paths-join-managed owner-dir (concat "runs/" runtime-id)))

(defun fleet-paths-eca-cache-dir (runtime-id) "Per-runtime ECA cache root." (fleet-paths-join-managed (fleet-paths-cache-root) (concat "eca/" runtime-id)))

(defun fleet-paths-socket ()
  "Control socket path; asserts the platform length limit."
  (let ((p (expand-file-name "control.sock" (fleet-paths-runtime-root))))
    (when (> (string-bytes p) 100)
      (fleet-fail 'socket-path-too-long "Unix socket path too long" :path p))
    p))

(defun fleet-paths-credentials-dir () "Ephemeral credential directory." (expand-file-name "credentials" (fleet-paths-runtime-root)))
(defun fleet-paths-credential-file (runtime-id) "Credential file for RUNTIME-ID." (fleet-paths-join-managed (fleet-paths-credentials-dir) (concat runtime-id ".json")))

(defun fleet-paths-worktree-dir (repo-name fleet-name task-name task-id)
  "Bounded, UUID-disambiguated worktree directory name."
  (let ((stem (format "%s--%s-%s-%s"
                      (truncate-string-to-width repo-name 24 nil nil "")
                      (truncate-string-to-width fleet-name 16 nil nil "")
                      (truncate-string-to-width task-name 24 nil nil "")
                      (fleet-paths-short-id task-id))))
    (fleet-paths-join-managed (fleet-paths-worktree-root) stem)))

(defconst fleet-paths--source-file (or load-file-name buffer-file-name)
  "This file's location, captured while fleet-paths itself loads.")

(defun fleet-paths-source-root ()
  "Fleet's own repository root (parent of lisp/)."
  (let ((here (or fleet-paths--source-file (locate-library "fleet-paths"))))
    (fleet-paths-canonical (expand-file-name ".." (file-name-directory here)))))

(defun fleet-paths-bridge-executable ()
  "Absolute path of the Python bridge."
  (expand-file-name "bridge/fleet_bridge.py" (fleet-paths-source-root)))

(defun fleet-paths-prompt-file (name)
  "Absolute path of canonical prompt NAME (without extension)."
  (expand-file-name (concat "prompts/" name ".md") (fleet-paths-source-root)))

(defun fleet-paths-schema-file (name)
  "Absolute path of schema file NAME."
  (expand-file-name (concat "schema/" name) (fleet-paths-source-root)))

;;;; Filesystem helpers

(defun fleet-paths-ensure-dir (dir &optional mode)
  "Create DIR (and parents) if missing; apply MODE when given.  Return DIR."
  (unless (file-directory-p dir)
    (with-file-modes (or mode #o700)
      (make-directory dir t)))
  (when mode (set-file-modes dir mode))
  (file-name-as-directory dir))

(defun fleet-paths-write-atomically (file content &optional mode)
  "Write CONTENT to FILE via temp file, fsync, and rename; optional MODE."
  (let* ((dir (fleet-paths-ensure-dir (file-name-directory file)))
         (tmp (make-temp-file (expand-file-name ".fleet-tmp-" dir))))
    (condition-case err
        (progn
          (let ((coding-system-for-write 'utf-8-unix)
                (write-region-inhibit-fsync nil))
            (write-region content nil tmp nil 'silent))
          (when mode (set-file-modes tmp mode))
          (rename-file tmp file t))
      (error
       (ignore-errors (delete-file tmp))
       (signal (car err) (cdr err))))
    file))

(defun fleet-paths-read-file (file)
  "Return FILE contents as a string, or nil when missing."
  (when (file-readable-p file)
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8-unix))
        (insert-file-contents file))
      (buffer-string))))

(defun fleet-paths-sha256-file (file)
  "SHA-256 hex digest of FILE contents, or nil when missing."
  (when (file-readable-p file)
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally file)
      (secure-hash 'sha256 (current-buffer)))))

(defun fleet-paths-sha256-string (string)
  "SHA-256 hex digest of STRING (UTF-8)."
  (secure-hash 'sha256 (encode-coding-string string 'utf-8)))

(defun fleet-paths-relative (root file)
  "Return FILE relative to ROOT, signalling if FILE is outside ROOT."
  (unless (fleet-paths-contains-p root file)
    (fleet-fail 'invalid-path "File not under root" :root root :file file))
  (file-relative-name (fleet-paths-canonical file) (fleet-paths-canonical root)))

(provide 'fleet-paths)
;;; fleet-paths.el ends here
