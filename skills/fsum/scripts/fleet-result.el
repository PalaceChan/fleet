;;; fleet-result.el --- Unresolved owner-facing results, shared by /fsum and /frev -*- lexical-binding: t; -*-

;;; Commentary:

;; Durable tracking of **owner-facing results that remain unresolved** because the
;; user has not acknowledged them, or has not supplied a disposition.  It is shared
;; by the `/fsum' and `/frev' skills: `/frev' loads this file as a sibling of
;; `fleet-read.el', exactly as it already loads that reader.
;;
;; WHAT THIS STATE IS, AND IS NOT
;; -----------------------------
;; This is **skill review/adjudication state**, not Fleet task or store truth.  It is
;; not a Fleet projection, it has no row in Fleet's SQLite schema, no RPC or MCP tool
;; writes it, and it must never be presented as Fleet's own record of anything.  It
;; records what the two review skills were told or shown about results that still
;; await the user.  Fleet's own tools remain the stronger evidence for everything
;; they cover.
;;
;; THE AUTHORITY BOUNDARY (see AGENTS.md: "Emacs alone writes state")
;; -----------------------------------------------------------------
;; Every authoritative mutation of the checkpoint happens **here, in Emacs Lisp**,
;; through `fleet-result-apply'.  `/frev''s Python app and its browser page may
;; *submit* choices, comments and messages into their own disposable session files;
;; they never write this checkpoint.  The commander reads a round and routes each
;; adjudication back through `frev-result-apply-to-file', which calls this module.
;; There is exactly one writer.
;;
;; `/fsum' is a read path and must stay one: it calls `fleet-result-read',
;; `fleet-result-scan' and `fleet-result-candidates' only.  Nothing in those three
;; creates a directory or touches a file.
;;
;; LAYOUT
;; ------
;;   $XDG_DATA_HOME/fleet-result-review/<namespace>/<root-fleet-id>/
;;       state.json     current items, cursors and dismissed fingerprints (atomic)
;;       events.jsonl   append-only audit, one line per applied operation
;;       .lock          O_EXCL lock file held across a read-modify-write
;;
;; <namespace> is Fleet's data-root hash (`fleet-paths-root-hash') when Fleet is
;; loaded, so a test data root can never mix with the owner's; <root-fleet-id> keys
;; the checkpoint by ROOT FLEET, which is what makes it survive commander
;; replacement.
;;
;; EVIDENCE RULES THIS FILE EXISTS TO KEEP
;; ---------------------------------------
;; - Acknowledgement and disposition are INDEPENDENT.  "I saw it, I'll review later"
;;   is acknowledged + outstanding, and stays visible.
;; - A later user message is NEVER acknowledgement.  Only an explicit `record'
;;   changes an item.  `fleet-result-scan' pairs turns chronologically and nothing
;;   in it closes anything.
;; - Inference yields CANDIDATES, never authority.  Candidates live in memory, are
;;   labelled `inferred', and only become items when a commander adjudicates them.
;; - Corruption, a held lock, a shrunken transcript or a scan cap FAIL VISIBLY:
;;   a stable error code or a coverage string.  Recoverable data is preserved; the
;;   checkpoint is never silently truncated or rebuilt.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)

;; Installed Fleet function, declared and never required: this file never loads Fleet.
(declare-function fleet-paths-root-hash "fleet-paths" ())

(defconst fleet-result-schema 1
  "Version of the `state.json' shape this module reads and writes.")

(defconst fleet-result-dispositions '("outstanding" "deferred" "resolved" "withdrawn" "superseded")
  "Every disposition an item may carry.  Orthogonal to acknowledgement.")

(defconst fleet-result-terminal-dispositions '("resolved" "withdrawn" "superseded")
  "Dispositions after which an item accepts no further interaction.")

(defconst fleet-result-bases '("owner-report" "fleet-observation" "commander-withdrawal")
  "How the last interaction became known.  Never inferred from a nearby message.")

(defconst fleet-result-origins '("explicit" "inferred")
  "Whether an item was declared by a commander or promoted from a scan candidate.")

(defconst fleet-result-presentations '("staged" "presented")
  "Whether a declared item has actually been emitted to the user yet.")

(defconst fleet-result-acknowledgements '("unacknowledged" "acknowledged")
  "Whether the user has been recorded as having seen the result at all.")

(defconst fleet-result-summary-limit 600
  "Characters kept of an item summary; items are compact by contract.")

(defconst fleet-result-text-limit 400
  "Characters kept of any other stored free text (reason, expectation, note).")

(defconst fleet-result-excerpt-limit 300
  "Characters of transcript text carried in a scan candidate excerpt.")

(defconst fleet-result-clip-length 4000
  "Length `fleet-eca--clip' truncates transcript text to.
A retained entry at or above this length may be missing its tail, so any
result it described may be missing too.")

(defconst fleet-result-max-items 500
  "Above this many retained items the checkpoint refuses new ones.
This is a review checkpoint, not a notification centre; hitting it means
old items were never dispositioned.")

(defvar fleet-result-lock-timeout 2.0
  "Seconds to wait for the checkpoint lock before failing visibly.")

(defvar fleet-result-data-root nil
  "Override of the result-review data root (tests).  Nil derives it from XDG.")

(defvar fleet-result-namespace-override nil
  "Override of the data-root namespace (tests).  Nil asks Fleet, else `default'.")

(define-error 'fleet-result-error "Fleet result-review error")

(defun fleet-result--fail (code message &rest evidence)
  "Signal `fleet-result-error' with stable CODE, MESSAGE and EVIDENCE plist."
  (signal 'fleet-result-error (list code message evidence)))

(defun fleet-result-error-code (err) "Stable code of `fleet-result-error' ERR." (nth 1 err))
(defun fleet-result-error-message (err) "Message of `fleet-result-error' ERR." (nth 2 err))
(defun fleet-result-error-evidence (err) "Evidence plist of `fleet-result-error' ERR." (nth 3 err))

(defun fleet-result-error-string (err)
  "Render ERR (a `fleet-result-error' or any error) for humans."
  (if (eq (car err) 'fleet-result-error)
      (format "%s: %s" (fleet-result-error-code err) (fleet-result-error-message err))
    (error-message-string err)))

;;;; Small helpers

(defun fleet-result-now ()
  "Current UTC time as the ISO-8601 string stored in the checkpoint."
  (format-time-string "%Y-%m-%dT%H:%M:%S.%3NZ" nil t))

(defun fleet-result--clip (text limit)
  "TEXT shortened to LIMIT characters with an ellipsis marker.
A non-string becomes the empty string."
  (let ((s (if (stringp text) text "")))
    (if (> (length s) limit) (concat (substring s 0 limit) "…") s)))

(defun fleet-result--one-line (text limit)
  "TEXT with runs of whitespace collapsed, clipped to LIMIT characters."
  (fleet-result--clip (string-trim (replace-regexp-in-string "[[:cntrl:][:space:]]+" " " (or text ""))) limit))

(defun fleet-result--require-text (value what limit)
  "VALUE as bounded text, or fail because WHAT is missing.
LIMIT bounds the stored length."
  (let ((s (and (stringp value) (string-trim value))))
    (when (or (null s) (string-empty-p s))
      (fleet-result--fail 'incomplete-declaration
                          (format "A result item needs %s; nothing was given" what)
                          :field what))
    (fleet-result--one-line s limit)))

(defun fleet-result--member-or-fail (value allowed code what)
  "VALUE when it is in ALLOWED, else fail with CODE naming WHAT."
  (unless (member value allowed)
    (fleet-result--fail code (format "%s must be one of %s; got %S" what (string-join allowed ", ") value)
                        :allowed allowed :given value))
  value)

;;;; Paths

(defun fleet-result-data-root ()
  "Canonical result-review data root: $XDG_DATA_HOME/fleet-result-review."
  (or fleet-result-data-root
      (let ((xdg (getenv "XDG_DATA_HOME")))
        (expand-file-name "fleet-result-review"
                          (if (and xdg (not (string-empty-p xdg))) xdg "~/.local/share")))))

(defun fleet-result-namespace ()
  "Fleet's data-root namespace, or `default' when Fleet is not loaded.
Keying by it keeps a disposable test data root out of the owner's checkpoint."
  (or fleet-result-namespace-override
      (and (fboundp 'fleet-paths-root-hash) (ignore-errors (fleet-paths-root-hash)))
      "default"))

(defconst fleet-result--segment-regexp "\\`[A-Za-z0-9][A-Za-z0-9_.-]\\{0,79\\}\\'"
  "Shape a namespace or fleet id must have before it becomes a path segment.")

(defun fleet-result--segment (value what)
  "VALUE when it is a safe path segment, else fail naming WHAT."
  (unless (and (stringp value) (string-match-p fleet-result--segment-regexp value))
    (fleet-result--fail 'bad-path-segment (format "%s has an unexpected shape" what) :given value))
  value)

(cl-defun fleet-result-directory (&key root-id namespace)
  "Checkpoint directory of ROOT-ID under NAMESPACE (default `fleet-result-namespace').
Returns the path whether or not it exists; nothing here creates it."
  (unless root-id (fleet-result--fail 'no-root-id "No root fleet id: the checkpoint is keyed by root fleet"))
  (expand-file-name (fleet-result--segment root-id "root fleet id")
                    (expand-file-name (fleet-result--segment (or namespace (fleet-result-namespace)) "namespace")
                                      (fleet-result-data-root))))

(defun fleet-result-state-file (dir) "Path of the canonical state file in DIR." (expand-file-name "state.json" dir))
(defun fleet-result-events-file (dir) "Path of the append-only audit log in DIR." (expand-file-name "events.jsonl" dir))
(defun fleet-result-lock-file (dir) "Path of the checkpoint lock in DIR." (expand-file-name ".lock" dir))

;;;; JSON

(defun fleet-result--jsonable (v)
  "V with lists as vectors and nil as :null, ready for `json-serialize'.
A list of plists would otherwise be mistaken for an alist."
  (cond ((null v) :null)
        ((eq v t) t)
        ((and (consp v) (keywordp (car v)))
         (cl-loop for (k val) on v by #'cddr append (list k (fleet-result--jsonable val))))
        ((consp v) (apply #'vector (mapcar #'fleet-result--jsonable v)))
        ((symbolp v) (symbol-name v))
        (t v)))

(defun fleet-result--parse (text)
  "Parse JSON TEXT into a plist, signalling on malformed input."
  (json-parse-string text :object-type 'plist :array-type 'list :null-object nil :false-object nil))

;;;; Read

(defun fleet-result--empty-state (root-id namespace)
  "A fresh, empty checkpoint state plist for ROOT-ID under NAMESPACE."
  (let ((now (fleet-result-now)))
    (list :schema fleet-result-schema :root-id root-id :namespace namespace :revision 0
          :created-at now :updated-at now :items nil :cursors nil :dismissed nil)))

(cl-defun fleet-result-read (&key root-id namespace)
  "One read-only observation of ROOT-ID's checkpoint under NAMESPACE.
Returns a plist with :status, :directory, :state-file, :coverage (human
strings) and, when readable, :schema :revision :items :cursors :dismissed.

:status is one of

  ok           the file was read and parsed;
  absent       no checkpoint exists for this root yet;
  corrupt      the file exists but did not parse — it is LEFT AS IT IS;
  unsupported  the file was written by a newer schema than this module knows.

A corrupt or unsupported checkpoint is a limitation to report, never a reason
to overwrite: every writer refuses until a human looks at the preserved file."
  (let* ((ns (or namespace (fleet-result-namespace)))
         (dir (fleet-result-directory :root-id root-id :namespace ns))
         (file (fleet-result-state-file dir))
         (base (list :root-id root-id :namespace ns :directory dir :state-file file)))
    (cond
     ((not (file-readable-p file))
      (append base (list :status (if (file-exists-p file) "corrupt" "absent")
                         :items nil :cursors nil :dismissed nil
                         :coverage (if (file-exists-p file)
                                       (list (format "The result-review checkpoint exists but is unreadable (%s)" file))
                                     (list "No result-review checkpoint exists for this fleet yet; nothing durable says whether a result is awaiting you")))))
     (t
      (condition-case err
          (let* ((text (with-temp-buffer
                         (let ((coding-system-for-read 'utf-8))
                           (insert-file-contents file))
                         (buffer-string)))
                 (state (fleet-result--parse text))
                 (schema (or (plist-get state :schema) 0)))
            (if (> schema fleet-result-schema)
                (append base (list :status "unsupported" :schema schema :items nil :cursors nil :dismissed nil
                                   :coverage (list (format "The result-review checkpoint is schema %s; this skill knows %s. Nothing was read or written."
                                                           schema fleet-result-schema))))
              (append base (list :status "ok" :schema schema
                                 :revision (or (plist-get state :revision) 0)
                                 :created-at (plist-get state :created-at)
                                 :updated-at (plist-get state :updated-at)
                                 :items (plist-get state :items)
                                 :cursors (plist-get state :cursors)
                                 :dismissed (plist-get state :dismissed)
                                 :coverage nil))))
        (error
         (append base (list :status "corrupt" :items nil :cursors nil :dismissed nil
                            :error (error-message-string err)
                            :coverage (list (format "The result-review checkpoint did not parse (%s); it was left untouched at %s"
                                                    (error-message-string err) file))))))))))

(defun fleet-result-open-items (read)
  "Items of a `fleet-result-read' result READ that still await the user.
Outstanding and deferred, presented or staged; terminal items are dropped."
  (cl-remove-if (lambda (i) (member (plist-get i :disposition) fleet-result-terminal-dispositions))
                (plist-get read :items)))

(defun fleet-result-item (read id)
  "Item ID in a `fleet-result-read' result READ, or nil."
  (cl-find id (plist-get read :items) :key (lambda (i) (plist-get i :id)) :test #'equal))

;;;; Lock and atomic write

(defun fleet-result--acquire-lock (dir)
  "Take the exclusive checkpoint lock in DIR and return its path.
The lock is one `O_EXCL' file naming the holder.  A lock this call cannot
take within `fleet-result-lock-timeout' is reported, never broken: breaking
it is a human act, because the other holder may be mid-write."
  (let ((lock (fleet-result-lock-file dir))
        (deadline (+ (float-time) fleet-result-lock-timeout)))
    (catch 'locked
      (while t
        (condition-case nil
            (let ((coding-system-for-write 'utf-8))
              (write-region (format "%d %s\n" (emacs-pid) (fleet-result-now)) nil lock nil 'silent nil 'excl)
              (throw 'locked lock))
          (file-already-exists
           (when (> (float-time) deadline)
             (fleet-result--fail 'checkpoint-locked
                                 (format "The result-review checkpoint is locked by another writer (%s); nothing was changed. Remove the lock only after checking no Emacs is mid-write."
                                         lock)
                                 :lock lock
                                 :holder (ignore-errors
                                           (with-temp-buffer (insert-file-contents lock) (string-trim (buffer-string))))))
           (sleep-for 0.05)))))))

(defun fleet-result--release-lock (lock)
  "Release the checkpoint LOCK, ignoring an already-removed file."
  (ignore-errors (delete-file lock)))

(defun fleet-result--write-atomic (file text)
  "Replace FILE with TEXT through a temporary file in the same directory.
The temporary file is created private and renamed over FILE, so a reader
sees either the old or the new content and never a partial one."
  (let ((tmp (make-temp-name (concat file ".tmp-"))))
    (condition-case err
        (progn
          (let ((coding-system-for-write 'utf-8))
            (with-temp-file tmp (set-buffer-file-coding-system 'utf-8) (insert text)))
          (set-file-modes tmp #o600)
          (rename-file tmp file t))
      (error (ignore-errors (delete-file tmp))
             (fleet-result--fail 'write-failed (format "Could not write %s: %s" file (error-message-string err))
                                 :file file)))))

(defun fleet-result--append-event (dir event)
  "Append EVENT (a plist) as one JSON line to the audit log in DIR.
The coding system is pinned: clipped text carries a `…' marker, and an
unpinned write asks the user which coding system to use — a prompt that
hangs a daemon or the owner's Emacs instead of failing."
  (let ((file (fleet-result-events-file dir))
        (coding-system-for-write 'utf-8))
    (write-region (concat (json-serialize (fleet-result--jsonable event)) "\n") nil file t 'silent)
    (ignore-errors (set-file-modes file #o600))))

(defun fleet-result--ensure-directory (dir)
  "Create DIR privately when it does not exist yet."
  (unless (file-directory-p dir)
    (make-directory dir t))
  (ignore-errors (set-file-modes dir #o700))
  dir)

;;;; Items

(defun fleet-result--new-id (items)
  "A fresh item id not used by any of ITEMS."
  (let ((taken (mapcar (lambda (i) (plist-get i :id)) items)) id)
    (while (or (null id) (member id taken))
      (setq id (format "rr-%s" (substring (secure-hash 'sha256 (format "%s-%s-%s" (float-time) (random 1000000) (length taken))) 0 8))))
    id))

(defun fleet-result--fingerprints (value)
  "VALUE as a clean list of fingerprint strings."
  (cl-remove-duplicates
   (cl-remove-if-not (lambda (s) (and (stringp s) (not (string-empty-p s))))
                     (if (listp value) value (list value)))
   :test #'equal))

(defun fleet-result--put (item &rest changes)
  "ITEM with CHANGES (a plist) applied, as a fresh plist."
  (let ((out (copy-sequence item)))
    (cl-loop for (k v) on changes by #'cddr do (setq out (plist-put out k v)))
    out))

(defun fleet-result--replace-item (items item)
  "ITEMS with the entry sharing ITEM's id replaced by ITEM."
  (mapcar (lambda (i) (if (equal (plist-get i :id) (plist-get item :id)) item i)) items))

(defun fleet-result--find (state id)
  "Item ID in STATE, or fail with `no-such-item'."
  (or (cl-find id (plist-get state :items) :key (lambda (i) (plist-get i :id)) :test #'equal)
      (fleet-result--fail 'no-such-item (format "No result item `%s' in this checkpoint" id) :id id)))

(defun fleet-result--refuse-terminal (item)
  "Fail when ITEM already carries a terminal disposition."
  (when (member (plist-get item :disposition) fleet-result-terminal-dispositions)
    (fleet-result--fail 'item-terminal
                        (format "Result item `%s' is already %s; terminal items are not reopened, declare a new one"
                                (plist-get item :id) (plist-get item :disposition))
                        :id (plist-get item :id) :disposition (plist-get item :disposition)))
  item)

;;;; Operations

(defun fleet-result--op-declare (state op)
  "Apply a `declare' OP to STATE, returning (STATE . EVENT-PAYLOAD)."
  (let* ((items (plist-get state :items))
         (_ (when (>= (length items) fleet-result-max-items)
              (fleet-result--fail 'checkpoint-full
                                  (format "The checkpoint already holds %d items; disposition old ones before declaring more" (length items))
                                  :count (length items))))
         (now (fleet-result-now))
         (id (or (plist-get op :id) (fleet-result--new-id items)))
         (origin (fleet-result--member-or-fail (or (plist-get op :origin) "explicit") fleet-result-origins
                                               'invalid-origin "Item origin"))
         (item (list :id id
                     :root-id (plist-get state :root-id)
                     :source-fleet (plist-get op :source-fleet)
                     :summary (fleet-result--require-text (plist-get op :summary) "a compact summary of the result" fleet-result-summary-limit)
                     :why (fleet-result--require-text (plist-get op :why) "why a response is still expected" fleet-result-text-limit)
                     :expected (fleet-result--require-text (plist-get op :expected) "what owner response is expected" fleet-result-text-limit)
                     :provenance (list :runtime-id (plist-get op :runtime-id)
                                       :transcript (plist-get op :transcript)
                                       :at (or (plist-get op :source-at) now)
                                       :note (fleet-result--one-line (plist-get op :provenance-note) fleet-result-text-limit))
                     :origin origin
                     :presentation (if (plist-get op :presented) "presented" "staged")
                     :acknowledgement "unacknowledged"
                     :disposition "outstanding"
                     :last-interaction nil
                     :basis nil
                     :successor-id nil
                     :fingerprints (fleet-result--fingerprints (plist-get op :fingerprints))
                     :created-at now
                     :updated-at now)))
    (when (cl-find id items :key (lambda (i) (plist-get i :id)) :test #'equal)
      (fleet-result--fail 'item-exists (format "A result item `%s' already exists" id) :id id))
    (cons (plist-put (copy-sequence state) :items (append items (list item)))
          (list :item-id id :origin origin :presentation (plist-get item :presentation) :item item))))

(defun fleet-result--op-presented (state op)
  "Apply a `presented' OP to STATE, returning (STATE . EVENT-PAYLOAD).
Confirming presentation is not acknowledgement: the user has been shown the
result, nothing says they answered."
  (let* ((item (fleet-result--refuse-terminal (fleet-result--find state (plist-get op :id))))
         (new (fleet-result--put item :presentation "presented" :updated-at (fleet-result-now))))
    (cons (plist-put (copy-sequence state) :items (fleet-result--replace-item (plist-get state :items) new))
          (list :item-id (plist-get item :id) :presentation "presented"))))

(defun fleet-result--op-record (state op)
  "Apply a `record' OP to STATE, returning (STATE . EVENT-PAYLOAD).
Acknowledgement and disposition move independently; neither is implied by the
other and neither is inferred from a nearby message."
  (let* ((item (fleet-result--refuse-terminal (fleet-result--find state (plist-get op :id))))
         (ackv (plist-get op :acknowledged))
         ;; Absent (nil) means "leave acknowledgement alone"; only an explicit
         ;; value moves it, and moving it never moves the disposition.
         (ack (cond ((null ackv) nil)
                    ((eq ackv t) "acknowledged")
                    ((stringp ackv) (fleet-result--member-or-fail ackv fleet-result-acknowledgements
                                                                  'invalid-acknowledgement "Acknowledgement"))
                    (t (fleet-result--fail 'invalid-acknowledgement
                                           "Acknowledgement must be t, \"acknowledged\" or \"unacknowledged\""
                                           :given ackv))))
         (disp (when (plist-get op :disposition)
                 (fleet-result--member-or-fail (plist-get op :disposition) fleet-result-dispositions
                                               'invalid-disposition "Disposition")))
         (note (and (plist-get op :note) (fleet-result--one-line (plist-get op :note) fleet-result-text-limit)))
         (basis (fleet-result--member-or-fail (plist-get op :basis) fleet-result-bases 'invalid-basis
                                              "The basis of this interaction")))
    (unless (or ack disp note)
      (fleet-result--fail 'empty-record "A record needs an acknowledgement, a disposition or a note" :id (plist-get op :id)))
    (when (equal disp "superseded")
      (fleet-result--fail 'invalid-disposition "Use the supersede operation so the successor is linked" :id (plist-get op :id)))
    (let ((new (fleet-result--put item
                                  :acknowledgement (or ack (plist-get item :acknowledgement))
                                  :disposition (or disp (plist-get item :disposition))
                                  :last-interaction (or note (plist-get item :last-interaction))
                                  :basis basis
                                  :updated-at (fleet-result-now))))
      (cons (plist-put (copy-sequence state) :items (fleet-result--replace-item (plist-get state :items) new))
            (list :item-id (plist-get item :id) :acknowledgement (plist-get new :acknowledgement)
                  :disposition (plist-get new :disposition) :basis basis :note note)))))

(defun fleet-result--op-withdraw (state op)
  "Apply a `withdraw' OP to STATE, returning (STATE . EVENT-PAYLOAD)."
  (let* ((item (fleet-result--refuse-terminal (fleet-result--find state (plist-get op :id))))
         (new (fleet-result--put item :disposition "withdrawn" :basis "commander-withdrawal"
                                 :last-interaction (fleet-result--one-line (or (plist-get op :note) "withdrawn by the commander")
                                                                           fleet-result-text-limit)
                                 :updated-at (fleet-result-now))))
    (cons (plist-put (copy-sequence state) :items (fleet-result--replace-item (plist-get state :items) new))
          (list :item-id (plist-get item :id) :disposition "withdrawn"))))

(defun fleet-result--op-supersede (state op)
  "Apply a `supersede' OP to STATE, returning (STATE . EVENT-PAYLOAD).
The successor must already exist, so a superseded item always names where the
matter continued."
  (let* ((item (fleet-result--refuse-terminal (fleet-result--find state (plist-get op :id))))
         (successor (plist-get op :successor-id)))
    (unless (cl-find successor (plist-get state :items) :key (lambda (i) (plist-get i :id)) :test #'equal)
      (fleet-result--fail 'no-such-successor "Declare the successor item first; a superseded item must name where the matter continued"
                          :id (plist-get item :id) :successor-id successor))
    (when (equal successor (plist-get item :id))
      (fleet-result--fail 'no-such-successor "An item cannot supersede itself" :id successor))
    (let ((new (fleet-result--put item :disposition "superseded" :successor-id successor
                                  :basis (or (plist-get op :basis) "commander-withdrawal")
                                  :last-interaction (fleet-result--one-line (or (plist-get op :note)
                                                                                (format "superseded by %s" successor))
                                                                            fleet-result-text-limit)
                                  :updated-at (fleet-result-now))))
      (cons (plist-put (copy-sequence state) :items (fleet-result--replace-item (plist-get state :items) new))
            (list :item-id (plist-get item :id) :disposition "superseded" :successor-id successor)))))

(defun fleet-result--op-attach (state op)
  "Apply an `attach' OP to STATE, returning (STATE . EVENT-PAYLOAD).
Attaching a scan fingerprint to an item is how a candidate is adjudicated:
split one transcript line across several items, or merge several lines into
one.  An attached fingerprint never returns as a candidate."
  (let* ((item (fleet-result--find state (plist-get op :id)))
         (add (fleet-result--fingerprints (plist-get op :fingerprints)))
         (new (fleet-result--put item
                                 :fingerprints (cl-remove-duplicates (append (plist-get item :fingerprints) add) :test #'equal)
                                 :updated-at (fleet-result-now))))
    (unless add (fleet-result--fail 'empty-attach "No fingerprints to attach" :id (plist-get op :id)))
    (cons (plist-put (copy-sequence state) :items (fleet-result--replace-item (plist-get state :items) new))
          (list :item-id (plist-get item :id) :fingerprints add))))

(defun fleet-result--op-dismiss (state op)
  "Apply a `dismiss' OP to STATE, returning (STATE . EVENT-PAYLOAD).
A dismissed fingerprint is reviewed noise: it is remembered so the same
transcript line is not proposed again at every review."
  (let* ((given (fleet-result--fingerprints (plist-get op :fingerprints)))
         (fps (or given (fleet-result--fingerprints (plist-get op :fingerprint))))
         (now (fleet-result-now))
         (note (fleet-result--one-line (plist-get op :note) fleet-result-text-limit))
         (known (mapcar (lambda (d) (plist-get d :fingerprint)) (plist-get state :dismissed)))
         (fresh (cl-remove-if (lambda (f) (member f known)) fps)))
    (unless fps (fleet-result--fail 'empty-dismiss "No fingerprints to dismiss"))
    (cons (plist-put (copy-sequence state) :dismissed
                     (append (plist-get state :dismissed)
                             (mapcar (lambda (f) (list :fingerprint f :at now :note note)) fresh)))
          (list :fingerprints fps :note note))))

(defun fleet-result--op-cursors (state op)
  "Apply a `cursors' OP to STATE, returning (STATE . EVENT-PAYLOAD).
Cursors record how far a deep scan has been *adjudicated*, never merely read:
`/frev' commits them together with the adjudications of that window, so an
unreviewed candidate is re-offered rather than silently skipped."
  (let* ((incoming (plist-get op :cursors))
         (kept (cl-remove-if (lambda (c) (cl-find (plist-get c :runtime-id) incoming
                                                  :key (lambda (n) (plist-get n :runtime-id)) :test #'equal))
                             (plist-get state :cursors))))
    (unless (listp incoming) (fleet-result--fail 'invalid-cursors "Cursors must be a list" :given incoming))
    (cons (plist-put (copy-sequence state) :cursors (append kept incoming))
          (list :cursors (mapcar (lambda (c) (plist-get c :runtime-id)) incoming)))))

(defun fleet-result--op-init (state _op)
  "Apply an `init' OP to STATE, returning (STATE . EVENT-PAYLOAD).
Creating the checkpoint file is an explicit act so that `/fsum' never has one
appear behind it."
  (cons state (list :initialized t)))

(defconst fleet-result--operations
  '(("init" . fleet-result--op-init)
    ("declare" . fleet-result--op-declare)
    ("presented" . fleet-result--op-presented)
    ("record" . fleet-result--op-record)
    ("withdraw" . fleet-result--op-withdraw)
    ("supersede" . fleet-result--op-supersede)
    ("attach" . fleet-result--op-attach)
    ("dismiss" . fleet-result--op-dismiss)
    ("cursors" . fleet-result--op-cursors))
  "The whole supported write contract, op name to implementation.")

;;;; The single writer

(cl-defun fleet-result-apply (&key root-id namespace ops actor)
  "Apply OPS to ROOT-ID's checkpoint under NAMESPACE, as one locked transaction.

This is the ONLY function in either skill that writes the checkpoint, and it
is Emacs Lisp by design (see the Commentary and AGENTS.md).  OPS is a list of
plists, each with an :op naming an entry of `fleet-result--operations'.
ACTOR is a short string recorded in the audit log.

All or nothing: every operation is validated and folded in memory first, so a
refusal in the middle leaves the file exactly as it was.  Only then is one
audit line per operation appended and the state file atomically replaced.
Each audit line carries the revision the write is about to produce, so an
interrupted write is visible afterwards as an event ahead of `state.json'.

A corrupt or unsupported checkpoint refuses every operation: the file is
preserved for a human, never rebuilt underneath them."
  (unless ops (fleet-result--fail 'no-operations "No operations to apply"))
  (let* ((ns (or namespace (fleet-result-namespace)))
         (dir (fleet-result-directory :root-id root-id :namespace ns))
         (lock nil))
    (fleet-result--ensure-directory dir)
    (unwind-protect
        (progn
          (setq lock (fleet-result--acquire-lock dir))
          (let* ((read (fleet-result-read :root-id root-id :namespace ns))
                 (status (plist-get read :status)))
            (unless (member status '("ok" "absent"))
              (fleet-result--fail (if (equal status "unsupported") 'checkpoint-unsupported 'checkpoint-corrupt)
                                  (car (plist-get read :coverage))
                                  :status status :state-file (plist-get read :state-file)))
            (let* ((state (if (equal status "ok")
                              (list :schema fleet-result-schema :root-id root-id :namespace ns
                                    :revision (or (plist-get read :revision) 0)
                                    :created-at (or (plist-get read :created-at) (fleet-result-now))
                                    :updated-at (plist-get read :updated-at)
                                    :items (plist-get read :items) :cursors (plist-get read :cursors)
                                    :dismissed (plist-get read :dismissed))
                            (fleet-result--empty-state root-id ns)))
                   (events nil))
              (dolist (op ops)
                (let* ((name (plist-get op :op))
                       (fn (cdr (assoc name fleet-result--operations))))
                  (unless fn
                    (fleet-result--fail 'invalid-op (format "Unknown result-review operation `%s'" name)
                                        :op name :supported (mapcar #'car fleet-result--operations)))
                  (let ((res (funcall fn state op)))
                    (setq state (car res))
                    (push (list :op name :payload (cdr res)) events))))
              (let* ((revision (1+ (or (plist-get state :revision) 0)))
                     (now (fleet-result-now)))
                (setq state (plist-put (plist-put state :revision revision) :updated-at now))
                (dolist (e (nreverse events))
                  (fleet-result--append-event dir (list :at now :to-revision revision :actor (or actor "commander")
                                                        :op (plist-get e :op) :payload (plist-get e :payload))))
                (fleet-result--write-atomic (fleet-result-state-file dir)
                                            (concat (json-serialize (fleet-result--jsonable state)) "\n"))
                (list :ok t :revision revision :directory dir :state-file (fleet-result-state-file dir)
                      :items (plist-get state :items))))))
      (when lock (fleet-result--release-lock lock)))))

;;;; The declaring contract, as named functions

(cl-defun fleet-result-declare (&key root-id namespace summary why expected expected-response
                                     runtime-id transcript source-at provenance-note origin
                                     fingerprints source-fleet presented actor)
  "Declare one unfinished owner-facing result and return the applied state.
SUMMARY, WHY and EXPECTED (or EXPECTED-RESPONSE) are all required: a result
with no unfinished expectation is a report, and reports create nothing.
Pass PRESENTED only when the paragraph has already been emitted.
ROOT-ID, NAMESPACE, RUNTIME-ID, TRANSCRIPT, SOURCE-AT, PROVENANCE-NOTE,
ORIGIN, FINGERPRINTS, SOURCE-FLEET and ACTOR are recorded as given."
  (fleet-result-apply :root-id root-id :namespace namespace :actor actor
                      :ops (list (list :op "declare" :summary summary :why why
                                       :expected (or expected expected-response)
                                       :runtime-id runtime-id :transcript transcript :source-at source-at
                                       :provenance-note provenance-note :origin origin
                                       :fingerprints fingerprints :source-fleet source-fleet
                                       :presented presented))))

(cl-defun fleet-result-presented (&key root-id namespace id actor)
  "Confirm item ID of ROOT-ID's checkpoint was actually emitted to the user.
NAMESPACE and ACTOR are as for `fleet-result-apply'."
  (fleet-result-apply :root-id root-id :namespace namespace :actor actor
                      :ops (list (list :op "presented" :id id))))

(cl-defun fleet-result-record (&key root-id namespace id acknowledged disposition basis note actor)
  "Record an interaction with item ID; ACKNOWLEDGED and DISPOSITION are separate.
Omitting either leaves it as it was, so \"I saw it, I will review later\" is
recorded as acknowledged with the disposition still outstanding.  BASIS is
required and says how this became known (`owner-report', `fleet-observation',
`commander-withdrawal').  NOTE is the last interaction in the user's
substance.  ROOT-ID, NAMESPACE and ACTOR are as for `fleet-result-apply'."
  (fleet-result-apply :root-id root-id :namespace namespace :actor actor
                      :ops (list (list :op "record" :id id :acknowledged acknowledged
                                       :disposition disposition :basis basis :note note))))

(cl-defun fleet-result-withdraw (&key root-id namespace id note actor)
  "Withdraw item ID of ROOT-ID's checkpoint with NOTE.
NAMESPACE and ACTOR are as for `fleet-result-apply'."
  (fleet-result-apply :root-id root-id :namespace namespace :actor actor
                      :ops (list (list :op "withdraw" :id id :note note))))

(cl-defun fleet-result-supersede (&key root-id namespace id successor-id note actor)
  "Supersede item ID by the already-declared SUCCESSOR-ID with NOTE.
ROOT-ID, NAMESPACE and ACTOR are as for `fleet-result-apply'."
  (fleet-result-apply :root-id root-id :namespace namespace :actor actor
                      :ops (list (list :op "supersede" :id id :successor-id successor-id :note note))))

(cl-defun fleet-result-dismiss (&key root-id namespace fingerprints note actor)
  "Dismiss scan FINGERPRINTS as reviewed noise with NOTE.
ROOT-ID, NAMESPACE and ACTOR are as for `fleet-result-apply'."
  (fleet-result-apply :root-id root-id :namespace namespace :actor actor
                      :ops (list (list :op "dismiss" :fingerprints fingerprints :note note))))

(cl-defun fleet-result-init (&key root-id namespace actor)
  "Create an empty checkpoint for ROOT-ID under NAMESPACE if there is none.
ACTOR is recorded in the audit log."
  (fleet-result-apply :root-id root-id :namespace namespace :actor actor :ops (list (list :op "init"))))

;;;; Transcript collector

(defun fleet-result-runs-directory (artifact-root)
  "Directory holding commander run transcripts under ARTIFACT-ROOT, or nil.
Current and replaced commanders each own one subdirectory, named by runtime
id; nothing in Fleet prunes them today, but that is current behaviour and not
a durable contract, so callers must report coverage."
  (and (stringp artifact-root) (not (string-empty-p artifact-root))
       (expand-file-name "commander/runs" artifact-root)))

(defun fleet-result--raw-slice (file beg end)
  "Bytes BEG..END of FILE as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file nil beg end)
    (buffer-string)))

(defun fleet-result-fingerprint (runtime-id at text)
  "Stable short fingerprint of the assistant turn RUNTIME-ID/AT with TEXT.
It survives a rescan, so an adjudicated or dismissed line never returns."
  (substring (secure-hash 'sha256 (format "%s\0%s\0%s" (or runtime-id "") (or at "") (or text ""))) 0 16))

(defun fleet-result--run-start (file)
  "First entry timestamp in transcript FILE, else its modification time.
Run directories are named by runtime id and carry no ordering, so the run
boundary order comes from the transcripts themselves."
  (or (ignore-errors
        (let* ((raw (fleet-result--raw-slice file 0 (min 4096 (or (file-attribute-size (file-attributes file)) 0))))
               (line (car (split-string (decode-coding-string raw 'utf-8) "\n" t))))
          (and line (plist-get (fleet-result--parse line) :at))))
      (ignore-errors (format-time-string "%Y-%m-%dT%H:%M:%S.%3NZ"
                                         (file-attribute-modification-time (file-attributes file)) t))
      ""))

(defun fleet-result-runs (runs-dir)
  "Every commander run transcript under RUNS-DIR, oldest run first.
Each entry is a plist with :runtime-id :file :size :started-at :status
\(`ok', `missing' or `unreadable')."
  (let (out)
    (when (and runs-dir (file-directory-p runs-dir))
      (dolist (name (sort (directory-files runs-dir nil "\\`[^.]" t) #'string<))
        (let* ((dir (expand-file-name name runs-dir))
               (file (expand-file-name "transcript.jsonl" dir)))
          (when (file-directory-p dir)
            (push (cond
                   ((not (file-exists-p file)) (list :runtime-id name :file file :size 0 :started-at "" :status "missing"))
                   ((not (file-readable-p file)) (list :runtime-id name :file file :size 0 :started-at "" :status "unreadable"))
                   (t (list :runtime-id name :file file
                            :size (or (file-attribute-size (file-attributes file)) 0)
                            :started-at (fleet-result--run-start file) :status "ok")))
                  out)))))
    (sort (nreverse out) (lambda (a b) (string< (plist-get a :started-at) (plist-get b :started-at))))))

(defun fleet-result--head-hash (file)
  "Hash of the first 256 bytes of FILE, identifying it across scans."
  (secure-hash 'sha256 (fleet-result--raw-slice file 0 (min 256 (or (file-attribute-size (file-attributes file)) 0)))))

(defun fleet-result--cursor (cursors runtime-id)
  "Cursor for RUNTIME-ID among CURSORS, or nil."
  (cl-find runtime-id cursors :key (lambda (c) (plist-get c :runtime-id)) :test #'equal))

(defun fleet-result--turns-of-run (run raw-start raw)
  "Conversational turns of RUN in RAW, the file slice beginning at byte RAW-START.
Returns a plist with :turns, :consumed (byte offset one past the last complete
line), :corrupt (unparsable line count), :tools, :unfinished and :coverage.

Pairing is chronological, never relational: a transcript line carries no
result, turn or message id.  A `fleet/submit' line is the authoritative input
and the adjacent duplicate `user/text' line is suppressed; `tool/called' lines
are counted and skipped; an input with no terminal assistant line after it is
reported as unfinished rather than paired with the next turn.  A trailing
partial line is not consumed, so a transcript being appended to right now is
resumed cleanly next time."
  (let* ((runtime-id (plist-get run :runtime-id))
         ;; `split-string' leaves "" after a final newline and the partial tail
         ;; otherwise; either way the last element is not a complete line.
         (lines (butlast (split-string raw "\n")))
         (coverage nil)
         (consumed raw-start)
         (turns nil) (corrupt 0) (tools 0)
         (input nil) (input-at nil) (last-submit nil) (unfinished nil))
    (dolist (line lines)
      (setq consumed (+ consumed (length line) 1))
      (let* ((text (decode-coding-string line 'utf-8))
             (entry (condition-case nil (and (not (string-empty-p (string-trim text))) (fleet-result--parse text))
                      (error (setq corrupt (1+ corrupt)) nil))))
        (when entry
          (let ((role (plist-get entry :role)) (kind (plist-get entry :kind))
                (at (plist-get entry :at)) (body (plist-get entry :text)))
            (cond
             ((and (equal role "fleet") (equal kind "submit"))
              (setq last-submit body input body input-at at unfinished t))
             ((and (equal role "user") (equal kind "text"))
              ;; ECA re-renders the submitted prompt as a user line; drop the duplicate.
              (unless (equal body last-submit)
                (setq input body input-at at unfinished t))
              (setq last-submit nil))
             ((and (equal role "assistant") (equal kind "text"))
              (push (list :runtime-id runtime-id
                          :at at
                          :text (or body "")
                          :clipped (and (stringp body) (>= (length body) fleet-result-clip-length))
                          :input (fleet-result--one-line input fleet-result-excerpt-limit)
                          :input-at input-at
                          :fingerprint (fleet-result-fingerprint runtime-id at body))
                    turns)
              (setq input nil input-at nil last-submit nil unfinished nil))
             ((equal role "tool") (setq tools (1+ tools)))
             (t nil))))))
    (when (> corrupt 0)
      (push (format "Transcript of runtime %s has %d unparsable line(s); they were skipped, nothing was inferred from them"
                    runtime-id corrupt)
            coverage))
    (when unfinished
      (push (format "Transcript of runtime %s ends on an unfinished turn; its answer, if any, was not retained"
                    runtime-id)
            coverage))
    (list :turns (nreverse turns) :consumed consumed :corrupt corrupt :tools tools
          :unfinished unfinished :coverage (nreverse coverage))))

(cl-defun fleet-result-scan (&key runs-dir cursors max-runs (max-bytes 262144) (max-turns 24))
  "Read commander transcripts under RUNS-DIR and return the conversational turns.

Pure observation: nothing here writes, and nothing here resolves anything.
CURSORS (as stored in the checkpoint) let a deep scan resume; MAX-RUNS keeps
only the newest runs; MAX-BYTES and MAX-TURNS bound the work.  Returns a plist

  :turns     oldest first, each :runtime-id :at :text :clipped :input
             :fingerprint, and :clipped meaning the 4,000-character clip may
             have removed the end of the result;
  :runs      what was seen per run, newest run first, including the bytes
             actually read;
  :cursors   cursors a caller MAY commit, only for runs read contiguously;
  :coverage  human strings naming every limit, gap and damaged input;
  :truncated non-nil when a cap stopped the scan.

A run whose transcript shrank or changed identity is rescanned from the start
and reported; a missing transcript is reported.  Nothing is ever treated as
closed because a file no longer holds it."
  (let* ((coverage nil)
         (all (fleet-result-runs runs-dir))
         (selected (if (and max-runs (> (length all) max-runs)) (last all max-runs) all))
         (budget max-bytes)
         (truncated nil)
         (collected nil)
         (run-reports nil)
         (new-cursors nil))
    (cond
     ((null runs-dir)
      (push "No artifact root is known for this fleet, so no commander transcript could be read" coverage))
     ((not (file-directory-p runs-dir))
      (push (format "No commander transcripts were found (%s does not exist); recent results could not be scanned" runs-dir) coverage))
     ((null all)
      (push (format "No commander run transcripts exist under %s yet" runs-dir) coverage)))
    (when (and max-runs (> (length all) (length selected)))
      (push (format "Only the %d most recent commander run(s) of %d were scanned; older runs are left to `/frev'"
                    (length selected) (length all))
            coverage))
    ;; Newest run first so the byte budget is spent where the recent results are.
    (dolist (run (reverse selected))
      (pcase (plist-get run :status)
        ("missing" (push (format "Run directory %s has no transcript.jsonl; that run's results cannot be seen"
                                 (plist-get run :runtime-id))
                         coverage))
        ("unreadable" (push (format "Transcript of runtime %s is not readable; that run's results cannot be seen"
                                    (plist-get run :runtime-id))
                            coverage))
        (_
         (let* ((file (plist-get run :file))
                (size (plist-get run :size))
                (head (fleet-result--head-hash file))
                (cursor (fleet-result--cursor cursors (plist-get run :runtime-id)))
                (start (cond ((null cursor) 0)
                             ((not (equal (plist-get cursor :head-hash) head))
                              (push (format "Transcript of runtime %s changed identity since the last review; it was rescanned from the start"
                                            (plist-get run :runtime-id))
                                    coverage)
                              0)
                             ((> (or (plist-get cursor :bytes) 0) size)
                              (push (format "Transcript of runtime %s shrank since the last review; it was rescanned from the start, and nothing is assumed closed"
                                            (plist-get run :runtime-id))
                                    coverage)
                              0)
                             (t (or (plist-get cursor :bytes) 0))))
                (contiguous t))
           (cond
            ((<= budget 0)
             (setq truncated t)
             (push (format "Transcript of runtime %s was not read at all: the %d-byte scan cap was already spent"
                           (plist-get run :runtime-id) max-bytes)
                   coverage))
            ((>= start size)
             (push (list :runtime-id (plist-get run :runtime-id) :status "up-to-date" :from start :to size
                         :size size :turns 0)
                   run-reports)
             (push (list :runtime-id (plist-get run :runtime-id) :bytes size :size size :head-hash head
                         :updated-at (fleet-result-now))
                   new-cursors))
            (t
             (when (> (- size start) budget)
               ;; Keep the tail: the newest turns matter most and the gap is declared.
               (let* ((want (- size budget))
                      (probe (fleet-result--raw-slice file want (min size (+ want 65536))))
                      (nl (cl-position ?\n probe)))
                 (setq start (if nl (+ want nl 1) size)
                       contiguous nil
                       truncated t)
                 (push (format "Only the last %d bytes of runtime %s's transcript were read (scan cap %d); earlier turns in that run were not seen"
                               (- size start) (plist-get run :runtime-id) max-bytes)
                       coverage)))
             (let* ((raw (fleet-result--raw-slice file start size))
                    (res (fleet-result--turns-of-run run start raw)))
               (setq coverage (append (reverse (plist-get res :coverage)) coverage))
               (setq budget (- budget (- size start)))
               (setq collected (append (plist-get res :turns) collected))
               (push (list :runtime-id (plist-get run :runtime-id) :status "read" :from start
                           :to (plist-get res :consumed) :size size
                           :turns (length (plist-get res :turns)) :corrupt-lines (plist-get res :corrupt)
                           :tool-lines (plist-get res :tools) :contiguous (and contiguous t))
                     run-reports)
               (when contiguous
                 (push (list :runtime-id (plist-get run :runtime-id) :bytes (plist-get res :consumed)
                             :size size :head-hash head :updated-at (fleet-result-now))
                       new-cursors)))))))))
    ;; `collected' is newest-run-first with each run's turns in order; sort by time.
    (let* ((turns (sort collected (lambda (a b) (string< (or (plist-get a :at) "") (or (plist-get b :at) "")))))
           (total (length turns)))
      (when (and max-turns (> total max-turns))
        (setq turns (last turns max-turns) truncated t)
        (push (format "Only the %d most recent conversational turns of %d read were kept" max-turns total) coverage))
      (dolist (turn turns)
        (when (plist-get turn :clipped)
          (push (format "An assistant turn of runtime %s at %s was retained clipped at %d characters; anything it asked after that point is not in the transcript"
                        (plist-get turn :runtime-id) (plist-get turn :at) fleet-result-clip-length)
                coverage)))
      (list :turns turns
            :runs (nreverse run-reports)
            :cursors (nreverse new-cursors)
            :coverage (nreverse (cl-remove-duplicates coverage :test #'equal))
            :truncated truncated))))

;;;; Candidates (inference, never authority)

(defconst fleet-result-ask-regexp
  (concat "\\(?:"
          "please \\(?:review\\|confirm\\|choose\\|decide\\|approve\\|merge\\|say\\|tell\\|report\\)"
          "\\|let me know\\|let us know\\|awaiting your\\|waiting on you\\|waiting for you"
          "\\|needs your\\|need your\\|your decision\\|your call\\|up to you"
          "\\|shall i\\|should i\\|do you want\\|would you like\\|if you approve"
          "\\)")
  "Deliberately broad marker of an assistant turn that may still expect the user.
Together with a question mark it decides whether a turn becomes a CANDIDATE.
Over-inclusion is the safe direction: a candidate is labelled inferred, capped
and adjudicated, while a missed result is simply lost.  A completed report with
no expectation matches neither and produces nothing.")

(defun fleet-result-ask-p (text)
  "Non-nil when TEXT may still expect something from the user.
A question mark or `fleet-result-ask-regexp'.  This is a heuristic filter on
inferred candidates and never evidence of anything."
  (let ((s (downcase (or text ""))))
    (and (or (string-search "?" s) (string-match-p fleet-result-ask-regexp s)) t)))

(cl-defun fleet-result-candidates (scan read &key (max nil))
  "Inferred candidates from SCAN that READ's checkpoint does not already cover.

A candidate is an assistant turn that may still expect the user and whose
fingerprint is attached to no item and has not been dismissed as noise.  The
NEXT user input in the same run is carried as context only: a later message is
never acknowledgement, and nothing here changes an item.  MAX keeps the newest
candidates.  Each candidate is a plist with :fingerprint :runtime-id :at
:excerpt :clipped :next-input :origin (always `inferred')."
  (let* ((turns (plist-get scan :turns))
         (known (apply #'append (mapcar (lambda (i) (plist-get i :fingerprints)) (plist-get read :items))))
         (dismissed (mapcar (lambda (d) (plist-get d :fingerprint)) (plist-get read :dismissed)))
         (out nil))
    (cl-loop for (turn . rest) on turns
             for fp = (plist-get turn :fingerprint)
             do (when (and (fleet-result-ask-p (plist-get turn :text))
                           (not (member fp known))
                           (not (member fp dismissed)))
                  (let ((next (cl-find-if (lambda (n) (and (equal (plist-get n :runtime-id) (plist-get turn :runtime-id))
                                                           (plist-get n :input)))
                                          rest)))
                    (push (list :fingerprint fp
                                :runtime-id (plist-get turn :runtime-id)
                                :at (plist-get turn :at)
                                :excerpt (fleet-result--one-line (plist-get turn :text) fleet-result-excerpt-limit)
                                :clipped (plist-get turn :clipped)
                                :next-input (and next (fleet-result--one-line (plist-get next :input) fleet-result-excerpt-limit))
                                :origin "inferred")
                          out))))
    (setq out (nreverse out))
    (if (and max (> (length out) max)) (last out max) out)))

(provide 'fleet-result)
;;; fleet-result.el ends here
