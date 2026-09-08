;;; fleet-store.el --- Fleet SQLite schema, transactions, projections -*- lexical-binding: t; -*-

;;; Commentary:

;; The single authoritative writer of Fleet facts.  Typed tables are the
;; current truth; `events' is an audit and delivery log.  Every mutation
;; runs inside `fleet-store-transaction', which also advances the global
;; snapshot revision so readers can render coherently.
;;
;; Rows are returned as plists with keyword keys (column `foo_bar' becomes
;; `:foo-bar').  JSON columns hold serialized plists; use
;; `fleet-store-json' / `fleet-store-unjson'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'fleet-paths)

(defconst fleet-store-schema-version 1
  "Newest schema this package can open for writing.")

(defconst fleet-store-busy-timeout-ms 3000
  "Bounded busy wait so a stray writer cannot freeze Emacs.")

(cl-defstruct (fleet-store (:constructor fleet-store--make))
  db path read-only (tx-depth 0))

(defvar fleet-store--tx-store nil
  "Store whose transaction is currently open, or nil.")

;;;; JSON

(defun fleet-store-json (value)
  "Serialize VALUE (plist/vector/string/number/t/nil) to JSON text.
nil serializes as JSON null; use :false for boolean false.  The result
is a multibyte string (json-serialize yields UTF-8 bytes)."
  (let ((s (json-serialize (fleet-store--jsonify value) :null-object nil :false-object :false)))
    (if (multibyte-string-p s) s (decode-coding-string s 'utf-8))))

(defun fleet-store--jsonify (v)
  "Normalize V for `json-serialize'.
Plists stay plists; other lists become vectors."
  (cond
   ((null v) nil)
   ((eq v t) t)
   ((eq v :false) :false)
   ((stringp v) v)
   ((numberp v) v)
   ((vectorp v) (apply #'vector (mapcar #'fleet-store--jsonify (append v nil))))
   ((and (consp v) (keywordp (car v)))
    (cl-loop for (k val) on v by #'cddr
             append (list k (fleet-store--jsonify val))))
   ((consp v) (apply #'vector (mapcar #'fleet-store--jsonify v)))
   ((symbolp v) (symbol-name v))
   (t (format "%s" v))))

(defun fleet-store-unjson (text)
  "Parse JSON TEXT into plists/vectors; nil for nil/empty."
  (when (and text (not (string-empty-p text)))
    (json-parse-string text :object-type 'plist :array-type 'array
                       :null-object nil :false-object :false)))

;;;; Column/key conversion

(defun fleet-store--col->key (name)
  "Column NAME to keyword."
  (intern (concat ":" (replace-regexp-in-string "_" "-" name))))

(defun fleet-store--key->col (key)
  "Keyword KEY to column name."
  (replace-regexp-in-string "-" "_" (substring (symbol-name key) 1)))

(defun fleet-store--rows->plists (rows)
  "Convert ROWS from `sqlite-select' (return type `full') into plists."
  (let ((keys (mapcar #'fleet-store--col->key (car rows))))
    (mapcar (lambda (row)
              (cl-loop for k in keys for v in row append (list k v)))
            (cdr rows))))

;;;; Open / close / migrate

(defun fleet-store-open (path &optional read-only)
  "Open the database at PATH, migrating when needed.  READ-ONLY forbids writes.
Signals `sqlite-unavailable', `schema-too-new', or `db-error'."
  (unless (and (fboundp 'sqlite-available-p) (sqlite-available-p))
    (fleet-fail 'sqlite-unavailable "This Emacs lacks SQLite support; Fleet requires it"))
  (fleet-paths-ensure-dir (file-name-directory path))
  (let* ((db (condition-case err (sqlite-open path)
               (error (fleet-fail 'db-error "Cannot open database" :path path :error (error-message-string err)))))
         (store (fleet-store--make :db db :path path :read-only read-only)))
    (sqlite-pragma db (format "busy_timeout = %d" fleet-store-busy-timeout-ms))
    (sqlite-pragma db "foreign_keys = ON")
    (unless read-only
      (sqlite-pragma db "journal_mode = WAL")
      (sqlite-pragma db "synchronous = FULL"))
    (when read-only
      (sqlite-pragma db "query_only = ON"))
    (fleet-store--migrate store)
    store))

(defun fleet-store-close (store)
  "Close STORE."
  (when (and store (fleet-store-db store))
    (ignore-errors (sqlite-close (fleet-store-db store)))
    (setf (fleet-store-db store) nil)))

(defun fleet-store--current-version (store)
  "Schema version of STORE, or 0 for an empty database."
  (let ((has-meta (sqlite-select (fleet-store-db store)
                                 "SELECT 1 FROM sqlite_master WHERE type='table' AND name='meta'")))
    (if has-meta
        (string-to-number (or (caar (sqlite-select (fleet-store-db store)
                                                   "SELECT value FROM meta WHERE key='schema_version'"))
                              "0"))
      0)))

(defun fleet-store--migrate (store)
  "Bring STORE to `fleet-store-schema-version'; refuse newer schemas."
  (let ((current (fleet-store--current-version store)))
    (cond
     ((> current fleet-store-schema-version)
      (fleet-fail 'schema-too-new "Database schema is newer than this Fleet"
                  :db-version current :package-version fleet-store-schema-version))
     ((= current fleet-store-schema-version) nil)
     ((fleet-store-read-only store)
      (fleet-fail 'schema-migration-required "Read-only store needs migration by the owner"
                  :db-version current))
     (t
      (when (> current 0)
        (fleet-store-backup store (format "%s.pre-migration-v%d-%s.sqlite3"
                                          (fleet-store-path store) current
                                          (format-time-string "%Y%m%dT%H%M%S" nil t))))
      (cl-loop for v from (1+ current) to fleet-store-schema-version
               do (fleet-store--apply-schema store v))))))

(defun fleet-store--apply-schema (store version)
  "Apply schema/VERSION.sql to STORE atomically."
  (let* ((file (fleet-paths-schema-file (format "%03d.sql" version)))
         (sql (or (fleet-paths-read-file file)
                  (fleet-fail 'schema-missing "Schema file missing" :file file)))
         (db (fleet-store-db store)))
    (sqlite-transaction db)
    (condition-case err
        (progn
          (dolist (stmt (split-string sql ";[ \t]*\n" t "[ \t\n]+"))
            (let ((clean (replace-regexp-in-string "^--.*$" "" stmt)))
              (unless (string-blank-p clean)
                (sqlite-execute db clean))))
          (sqlite-execute db "INSERT OR REPLACE INTO meta(key,value) VALUES ('schema_version', ?)"
                          (list (number-to-string version)))
          (sqlite-execute db "INSERT OR IGNORE INTO meta(key,value) VALUES ('created_at', ?)"
                          (list (fleet-paths-now)))
          (sqlite-execute db "INSERT OR IGNORE INTO meta(key,value) VALUES ('snapshot_revision', '0')")
          (sqlite-commit db))
      (error (sqlite-rollback db)
             (fleet-fail 'db-error "Schema migration failed" :version version :error (error-message-string err))))))

(defun fleet-store-backup (store dest)
  "Write a consistent online copy of STORE to DEST using VACUUM INTO."
  (when (file-exists-p dest) (delete-file dest))
  (sqlite-execute (fleet-store-db store) "VACUUM INTO ?" (list dest))
  dest)

;;;; Queries

(defun fleet-store-query (store sql &rest params)
  "Run SELECT SQL with PARAMS on STORE; return a list of plists."
  (let ((rows (sqlite-select (fleet-store-db store) sql (and params (apply #'vector params)) 'full)))
    (when rows (fleet-store--rows->plists rows))))

(defun fleet-store-query1 (store sql &rest params)
  "Return the first plist of `fleet-store-query'."
  (car (apply #'fleet-store-query store sql params)))

(defun fleet-store-scalar (store sql &rest params)
  "Return the first column of the first row."
  (caar (sqlite-select (fleet-store-db store) sql (and params (apply #'vector params)))))

(defun fleet-store-exec (store sql &rest params)
  "Run mutating SQL with PARAMS inside an open transaction; return affected rows."
  (when (fleet-store-read-only store)
    (fleet-fail 'read-only "Store is read-only (another Emacs owns this data root)"))
  (unless (eq fleet-store--tx-store store)
    (fleet-fail 'no-transaction "Mutation outside fleet-store-transaction" :sql sql))
  (sqlite-execute (fleet-store-db store) sql (and params (apply #'vector params))))

(defmacro fleet-store-transaction (store &rest body)
  "Run BODY inside one IMMEDIATE transaction on STORE, advancing snapshot revision.
Nested use joins the outer transaction.  Any error rolls back everything."
  (declare (indent 1) (debug t))
  (let ((s (make-symbol "store")) (outer (make-symbol "outer")))
    `(let* ((,s ,store)
            (,outer (eq fleet-store--tx-store ,s)))
       (when (and fleet-store--tx-store (not ,outer))
         (fleet-fail 'db-error "Transaction already open on a different store"))
       (when (fleet-store-read-only ,s)
         (fleet-fail 'read-only "Store is read-only (another Emacs owns this data root)"))
       (if ,outer
           (progn ,@body)
         (let ((fleet-store--tx-store ,s))
           (sqlite-execute (fleet-store-db ,s) "BEGIN IMMEDIATE")
           (condition-case err
               (prog1 (progn ,@body)
                 (sqlite-execute (fleet-store-db ,s)
                                 "UPDATE meta SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT) WHERE key='snapshot_revision'")
                 (sqlite-commit (fleet-store-db ,s)))
             (error (ignore-errors (sqlite-rollback (fleet-store-db ,s)))
                    (signal (car err) (cdr err)))))))))

(defun fleet-store-snapshot-revision (store)
  "Global commit sequence of STORE."
  (string-to-number (or (fleet-store-scalar store "SELECT value FROM meta WHERE key='snapshot_revision'") "0")))

;;;; Generic row helpers

(defun fleet-store--plist-cols (plist)
  "Return (COLS . VALUES) for PLIST, serializing non-scalar values as JSON."
  (let (cols vals)
    (cl-loop for (k v) on plist by #'cddr
             do (push (fleet-store--key->col k) cols)
             (push (cond ((or (null v) (stringp v) (numberp v)) v)
                         ((eq v t) 1)
                         ((eq v :false) 0)
                         (t (fleet-store-json v)))
                   vals))
    (cons (nreverse cols) (nreverse vals))))

(defun fleet-store-insert (store table plist)
  "INSERT PLIST into TABLE."
  (pcase-let ((`(,cols . ,vals) (fleet-store--plist-cols plist)))
    (apply #'fleet-store-exec store
           (format "INSERT INTO %s (%s) VALUES (%s)" table
                   (string-join cols ", ")
                   (string-join (make-list (length cols) "?") ", "))
           vals)))

(defun fleet-store-update (store table id plist)
  "UPDATE TABLE row ID with PLIST; sets updated_at when the table has it."
  (pcase-let ((`(,cols . ,vals) (fleet-store--plist-cols plist)))
    (apply #'fleet-store-exec store
           (format "UPDATE %s SET %s WHERE id = ?" table
                   (string-join (mapcar (lambda (c) (concat c " = ?")) cols) ", "))
           (append vals (list id)))))

(defun fleet-store-get (store table id)
  "Row ID of TABLE as plist or nil."
  (fleet-store-query1 store (format "SELECT * FROM %s WHERE id = ?" table) id))

(defun fleet-store-touch (plist)
  "Return PLIST with :updated-at set to now."
  (plist-put (copy-sequence plist) :updated-at (fleet-paths-now)))

(defun fleet-store-bump-revision (store table id)
  "Advance entity_revision of TABLE row ID; return the new value."
  (fleet-store-exec store (format "UPDATE %s SET entity_revision = entity_revision + 1, updated_at = ? WHERE id = ?" table)
                    (fleet-paths-now) id)
  (fleet-store-scalar store (format "SELECT entity_revision FROM %s WHERE id = ?" table) id))

(defun fleet-store-check-revision (store table id expected)
  "Signal `revision-mismatch' unless TABLE row ID has entity_revision EXPECTED (when non-nil)."
  (when expected
    (let ((actual (fleet-store-scalar store (format "SELECT entity_revision FROM %s WHERE id = ?" table) id)))
      (unless (eql actual expected)
        (fleet-fail 'revision-mismatch "Entity changed since it was read"
                    :table table :id id :expected expected :actual actual)))))

;;;; Events and receipts

(cl-defun fleet-store-append-event (store &key fleet-id task-id runtime-id kind payload source actor
                                          operation-id actionable)
  "Append a semantic event; when ACTIONABLE also create a pending receipt.
Returns the event id.  Must run inside a transaction with the fact update."
  (let ((id (fleet-paths-uuid)) (now (fleet-paths-now)))
    (fleet-store-insert store "events"
                        (list :id id :fleet-id fleet-id :task-id task-id :runtime-id runtime-id
                              :kind kind :payload (and payload (fleet-store-json payload))
                              :source source :actor actor :operation-id operation-id
                              :actionable (if actionable 1 0) :created-at now))
    (when (and actionable fleet-id)
      (fleet-store-insert store "event_receipts"
                          (list :id (fleet-paths-uuid) :event-id id :fleet-id fleet-id :consumer "commander"
                                :state "pending" :created-at now :updated-at now)))
    id))

(defun fleet-store-pending-receipts (store fleet-id &optional states limit)
  "Receipts for FLEET-ID in STATES (default pending) joined with their events, oldest first."
  (let ((states (or states '("pending"))))
    (apply #'fleet-store-query store
           (format "SELECT r.id AS receipt_id, r.state, r.batch_id, r.runtime_id AS receipt_runtime_id, r.outcome,
                           e.seq, e.id AS event_id, e.kind, e.payload, e.task_id, e.runtime_id, e.created_at
                    FROM event_receipts r JOIN events e ON e.id = r.event_id
                    WHERE r.fleet_id = ? AND r.state IN (%s) ORDER BY e.seq ASC %s"
                   (string-join (make-list (length states) "?") ",")
                   (if limit (format "LIMIT %d" limit) ""))
           fleet-id states)))

;;;; Actions (idempotency by logical actor + action id)

(defun fleet-store-action-lookup (store actor action-id)
  "Existing action row for ACTOR/ACTION-ID, or nil."
  (fleet-store-query1 store "SELECT * FROM actions WHERE actor = ? AND action_id = ?" actor action-id))

(defun fleet-store-payload-digest (payload)
  "Canonical digest of PAYLOAD (a plist)."
  (fleet-paths-sha256-string (fleet-store-json (fleet-store--sort-plist payload))))

(defun fleet-store--sort-plist (v)
  "Recursively sort plist keys in V for canonical serialization."
  (cond
   ((and (consp v) (keywordp (car v)))
    (let ((pairs (cl-loop for (k val) on v by #'cddr collect (cons k (fleet-store--sort-plist val)))))
      (cl-loop for (k . val) in (sort pairs (lambda (a b) (string< (symbol-name (car a)) (symbol-name (car b)))))
               append (list k val))))
   ((vectorp v) (apply #'vector (mapcar #'fleet-store--sort-plist (append v nil))))
   ((consp v) (mapcar #'fleet-store--sort-plist v))
   (t v)))

(cl-defun fleet-store-action-record (store &key actor action-id payload operation-id event-id batch-id result)
  "Record ACTION-ID for ACTOR with PAYLOAD digest and linkage.
OPERATION-ID, EVENT-ID, BATCH-ID and RESULT are optional linkage."
  (fleet-store-insert store "actions"
                      (list :actor actor :action-id action-id
                            :payload-digest (fleet-store-payload-digest payload)
                            :operation-id operation-id :event-id event-id :batch-id batch-id
                            :result (and result (fleet-store-json result))
                            :created-at (fleet-paths-now))))

(defmacro fleet-store-with-action (store actor action-id payload &rest body)
  "Idempotently run BODY for ACTOR's ACTION-ID with PAYLOAD.
If the action exists with the same digest, return its recorded result
without running BODY.  Different payload signals `action-payload-mismatch'.
BODY must return a plist result; it is recorded with the action."
  (declare (indent 4) (debug t))
  (let ((s (make-symbol "s")) (a (make-symbol "a")) (id (make-symbol "id"))
        (p (make-symbol "p")) (existing (make-symbol "existing")) (res (make-symbol "res")))
    `(let* ((,s ,store) (,a ,actor) (,id ,action-id) (,p ,payload))
       (fleet-store-transaction ,s
         (let ((,existing (and ,id (fleet-store-action-lookup ,s ,a ,id))))
           (cond
            ((and ,existing (string= (plist-get ,existing :payload-digest) (fleet-store-payload-digest ,p)))
             (append (list :replayed t) (fleet-store-unjson (plist-get ,existing :result))))
            (,existing
             (fleet-fail 'action-payload-mismatch "Same action id reused with a different payload"
                         :actor ,a :action-id ,id))
            (t
             (let ((,res (progn ,@body)))
               (when ,id
                 (fleet-store-action-record ,s :actor ,a :action-id ,id :payload ,p
                                            :operation-id (plist-get ,res :operation-id)
                                            :event-id (plist-get ,res :event-id)
                                            :result ,res))
               ,res))))))))

;;;; Projection

(defun fleet-store-fleets (store &optional include-archived)
  "All fleets (alphabetical), excluding archived unless INCLUDE-ARCHIVED."
  (fleet-store-query store (format "SELECT * FROM fleets %s ORDER BY name ASC"
                                   (if include-archived "" "WHERE lifecycle <> 'archived'"))))

(defun fleet-store-fleet-by-name (store name)
  "Non-archived fleet named NAME or nil."
  (fleet-store-query1 store "SELECT * FROM fleets WHERE name = ? AND lifecycle <> 'archived'" name))

(defun fleet-store-tasks (store fleet-id &optional include-archived)
  "Tasks of FLEET-ID alphabetically."
  (fleet-store-query store (format "SELECT * FROM tasks WHERE fleet_id = ? %s ORDER BY name ASC"
                                   (if include-archived "" "AND lifecycle <> 'archived'"))
                     fleet-id))

(defun fleet-store-task-by-name (store fleet-id name)
  "Non-archived task NAME in FLEET-ID."
  (fleet-store-query1 store "SELECT * FROM tasks WHERE fleet_id = ? AND name = ? AND lifecycle <> 'archived'" fleet-id name))

(defun fleet-store-snapshot (store &optional fleet-id)
  "Coherent read of everything the dashboard and tools need.
Returns (:revision N :fleets (FLEET...)) where each FLEET plist carries
:tasks, :commander (runtime plist or nil), :pending-events, :open-decisions,
:running-operations, :queued-wakes, and each task carries :runtime,
:artifacts, :decisions, :operations, :external-jobs, :messages-recent."
  (let* ((fleets (if fleet-id
                     (let ((f (fleet-store-get store "fleets" fleet-id))) (and f (list f)))
                   (fleet-store-fleets store))))
    (list :revision (fleet-store-snapshot-revision store)
          :fleets
          (mapcar
           (lambda (f)
             (let ((fid (plist-get f :id)))
               (append f
                       (list :commander (and (plist-get f :commander-runtime-id)
                                             (fleet-store-get store "runtimes" (plist-get f :commander-runtime-id)))
                             :pending-events (fleet-store-scalar store "SELECT COUNT(*) FROM event_receipts WHERE fleet_id = ? AND state IN ('pending','claimed','held-unknown','needs-reconciliation')" fid)
                             :queued-wakes (fleet-store-scalar store "SELECT COUNT(*) FROM messages WHERE fleet_id = ? AND origin IN ('wake','reminder') AND state IN ('queued','held','dispatching')" fid)
                             :open-decisions (fleet-store-query store "SELECT * FROM decisions WHERE fleet_id = ? AND state = 'open'" fid)
                             :running-operations (fleet-store-query store "SELECT * FROM operations WHERE fleet_id = ? AND state IN ('running','blocked','failed') ORDER BY created_at" fid)
                             :tasks (mapcar (lambda (task) (fleet-store--task-projection store task))
                                            (fleet-store-tasks store fid))))))
           fleets))))

(defun fleet-store--task-projection (store task)
  "TASK plist enriched with its runtime and related facts."
  (let ((tid (plist-get task :id)))
    (append task
            (list :runtime (and (plist-get task :current-runtime-id)
                                (fleet-store-get store "runtimes" (plist-get task :current-runtime-id)))
                  :artifacts (fleet-store-query store "SELECT * FROM artifacts WHERE task_id = ? ORDER BY created_at" tid)
                  :decisions (fleet-store-query store "SELECT * FROM decisions WHERE task_id = ? AND state = 'open' ORDER BY created_at" tid)
                  :operations (fleet-store-query store "SELECT * FROM operations WHERE task_id = ? AND state IN ('running','blocked','failed') ORDER BY created_at" tid)
                  :external-jobs (fleet-store-query store "SELECT * FROM external_jobs WHERE task_id = ? AND state IN ('running','unknown') ORDER BY created_at" tid)
                  :dependencies (fleet-store-query store "SELECT d.depends_on_id, d.satisfied_revision, t.name, t.phase, t.brief_revision FROM task_dependencies d JOIN tasks t ON t.id = d.depends_on_id WHERE d.task_id = ?" tid)
                  :messages-recent (fleet-store-query store "SELECT id, origin, state, text, created_at FROM messages WHERE task_id = ? ORDER BY created_at DESC LIMIT 3" tid)))))

(provide 'fleet-store)
;;; fleet-store.el ends here
