;;; fsum.el --- Render one screen of Fleet bearings as Markdown -*- lexical-binding: t; -*-

;;; Commentary:

;; `/fsum' = `fleet-read-bearings' (evidence) + this file (presentation).
;; `fsum-bearings' returns a Markdown string: heading with observation time, one
;; synthesis sentence, a supervisor table, a work table with moving work first,
;; "Needs you" bullets, coverage notes.  The formatter adds no facts: every label
;; is derived from the evidence plist with the conservative rules in SKILL.md
;; (working may be stale, park is not a decision, done is not verified).
;;
;; Exceptions (decision, blocked, failed, lost, unknown, unverified done, closing)
;; are always individual rows.  Only routine rows may be rolled up, and a rollup
;; row names its tasks and states its count.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'fleet-read (expand-file-name "fleet-read.el"
                                       (file-name-directory (or load-file-name buffer-file-name default-directory))))

(defconst fsum-rollup-threshold 12
  "Above this many retained tasks, routine rows are rolled up per owner and state.")
(defconst fsum-cell-width 90 "Display width a free-text table cell is truncated to.")
(defconst fsum-focus-width 48 "Display width of the supervisor Focus cell.")
(defconst fsum-frev-hint-threshold 3
  "Suggest `/frev' only when at least this many items need the user.")

;;;; Text

(defun fsum--clean (s)
  "S as one line safe inside a Markdown table cell."
  (let ((s (replace-regexp-in-string "[[:cntrl:][:space:]]+" " " (or s ""))))
    (string-trim (replace-regexp-in-string "|" "\\\\|" s))))

(defun fsum--cell (s &optional width)
  "Clean and truncate S to WIDTH display columns (default `fsum-cell-width')."
  (let ((s (fsum--clean s)))
    (if (string-empty-p s) "—" (truncate-string-to-width s (or width fsum-cell-width) nil nil "…"))))

(defun fsum--table (header rows)
  "Markdown table with HEADER and ROWS (lists of already-clean strings)."
  (concat "| " (string-join header " | ") " |\n"
          "|" (mapconcat (lambda (_) "---|") header "") "\n"
          (mapconcat (lambda (r) (concat "| " (string-join r " | ") " |")) rows "\n")
          (and rows "\n")))

(defun fsum--plural (n singular &optional plural)
  "N with SINGULAR or PLURAL (default SINGULAR + s)."
  (format "%d %s" n (if (= n 1) singular (or plural (concat singular "s")))))

(defun fsum--hhmm (iso)
  "HH:MM of an ISO timestamp ISO (as produced by `fleet-read-bearings')."
  (if (and (stringp iso) (>= (length iso) 16)) (substring iso 11 16) (or iso "?")))

;;;; Classification

(defconst fsum-classes
  '(working native decision blocked failed dead unknown paused done closing done-verified suspended ready draft)
  "Row order: moving work first, then what needs someone, then closeout and rest.")

(defconst fsum-exception-classes '(native decision blocked failed dead unknown done closing)
  "Classes that are always individual rows, never rolled up.")

(defun fsum--decision-authority (task)
  "Authority of TASK's open decision: human, commander, or unknown."
  (let ((d (cl-find "open" (plist-get task :decisions) :key (lambda (d) (plist-get d :state)) :test #'equal)))
    (or (and d (plist-get d :authority)) (and (plist-get task :decisions) (plist-get (car (plist-get task :decisions)) :authority)) "unknown")))

(defun fsum--classify (task)
  "Return (CLASS LABEL NEXT) for TASK from evidence only.
CLASS is a symbol from `fsum-classes'; LABEL is the State cell; NEXT the
Next-step cell before qualifiers."
  (let* ((life (plist-get task :lifecycle)) (phase (plist-get task :phase))
         (detail (or (plist-get task :detail) ""))
         (rt (plist-get task :runtime)) (rt-life (plist-get rt :lifecycle)) (turn (plist-get rt :turn-state))
         (open-decision (cl-find "open" (plist-get task :decisions) :key (lambda (d) (plist-get d :state)) :test #'equal))
         (verified (cl-some (lambda (a) (plist-get a :verified)) (plist-get task :artifacts)))
         (terminal (member phase '("done" "failed"))))
    (cond
     ((equal rt-life "stop-unknown") (list 'unknown "Stop unknown" "service stop verdict unknown; inspect before anything else"))
     ((equal life "suspended") (list 'suspended (if terminal (format "Suspended · reported %s" phase) "Suspended (parked)")
                                     (if terminal detail "no resume requested")))
     ((equal life "closing") (list 'closing "Teardown in progress" detail))
     ((and (equal rt-life "lost") (not terminal)) (list 'dead "Runtime lost" "connection lost; service not proven stopped"))
     ((and rt (> (or (plist-get rt :pending-approvals) 0) 0)) (list 'native "Native approval waiting" "only you can approve it, in the operator's chat"))
     ((and rt (plist-get rt :pending-question)) (list 'native "Native question waiting" "answer it in the operator's chat"))
     ((or open-decision (equal phase "needs-decision"))
      (let ((auth (fsum--decision-authority task)))
        (list 'decision
              (pcase auth ("human" "Decision (yours)") ("commander" "Decision (commander)") (_ "Decision (routing unverified)"))
              (or (plist-get open-decision :question) detail))))
     ((equal phase "blocked") (list 'blocked "Blocked" detail))
     ((equal phase "failed") (list 'failed "Failed" detail))
     ((equal phase "done")
      (if verified
          (list 'done-verified "Reported done · verified" "closeout (teardown) pending")
        (list 'done "Reported done" "verification pending")))
     ((equal phase "paused") (list 'paused "Waiting"
                                   (let ((w (plist-get task :wait)))
                                     (if w (format "%s%s" (or (plist-get w :reason) detail)
                                                   (if (plist-get w :deadline) (format " (until %s)" (fsum--hhmm (plist-get w :deadline))) ""))
                                       detail))))
     ((equal phase "working")
      (list 'working
            (cond ((equal turn "running") (format "Working%s" (if (plist-get rt :active-tool) (format " · %s" (plist-get rt :active-tool)) "")))
                  ((null rt) "Working (reported; no runtime)")
                  ((member rt-life '("stopped" "never-launched")) "Working (reported; runtime stopped)")
                  (t "Working (reported; idle now)"))
            detail))
     ((equal life "ready") (list 'ready "Ready, not started" detail))
     ((equal life "draft") (list 'draft "Draft" detail))
     (t (list 'unknown "Unknown" (if (string-empty-p detail) "no execution evidence" detail))))))

(defun fsum--qualifiers (task class)
  "Short evidence qualifiers appended to TASK's Next cell for CLASS."
  (let (q)
    (when (> (or (plist-get task :newer-instructions) 0) 0)
      (push (format "%s sent since this status" (fsum--plural (plist-get task :newer-instructions) "message")) q))
    (dolist (k (plist-get task :failed-operations)) (push (format "op %s failed" k) q))
    (dolist (j (plist-get task :external-jobs))
      (push (format "%s job %s" (plist-get j :system) (plist-get j :state)) q))
    (when (memq class '(done done-verified))
      (when-let* ((ref (cl-some (lambda (a) (and (plist-get a :external) (plist-get a :ref))) (plist-get task :artifacts))))
        (push (format "%s (reported, not rechecked)" ref) q)))
    (nreverse q)))

;;;; Rows

(defun fsum--owner (member)
  "Owner cell for MEMBER: Commander for the root, else the lieutenant's name."
  (if (equal (plist-get member :role) "root") "Commander" (plist-get member :name)))

(defun fsum--task-rows (bearings)
  "Work rows: (CLASS OWNER TASK-NAME STATE NEXT) for every retained task."
  (let (rows)
    (dolist (m (plist-get bearings :members))
      (dolist (task (plist-get m :tasks))
        (pcase-let ((`(,class ,label ,next) (fsum--classify task)))
          (push (list class (fsum--owner m) (plist-get task :name) label
                      (string-join (cons next (fsum--qualifiers task class)) " · "))
                rows))))
    (sort (nreverse rows)
          (lambda (a b) (let ((ia (cl-position (car a) fsum-classes)) (ib (cl-position (car b) fsum-classes)))
                          (if (/= ia ib) (< ia ib) (string< (nth 2 a) (nth 2 b))))))))

(defun fsum--work-table (rows)
  "Markdown work table from ROWS; routine rows rolled up above the threshold."
  (let* ((rollup (> (length rows) fsum-rollup-threshold))
         (groups (make-hash-table :test 'equal))
         (keyed nil)) ; (CLASS-POS OWNER NAME CELLS) so rolled and individual rows share one order
    (dolist (r rows)
      (pcase-let ((`(,class ,owner ,name ,label ,next) r))
        (if (and rollup (not (memq class fsum-exception-classes)))
            (push name (gethash (list class owner label) groups))
          (push (list (cl-position class fsum-classes) owner name
                      (list (fsum--cell owner) (format "`%s`" (fsum--clean name)) (fsum--cell label) (fsum--cell next)))
                keyed))))
    (maphash (lambda (key names)
               (pcase-let ((`(,class ,owner ,label) key))
                 (push (list (cl-position class fsum-classes) owner ""
                             (list (fsum--cell owner)
                                   (format "%s (rolled up)" (fsum--plural (length names) "task"))
                                   (fsum--cell label)
                                   ;; never truncated: a rollup must name every task it stands for
                                   (mapconcat (lambda (n) (format "`%s`" (fsum--clean n))) (sort names #'string<) ", ")))
                       keyed)))
             groups)
    (setq keyed (sort keyed (lambda (a b) (or (< (car a) (car b))
                                              (and (= (car a) (car b))
                                                   (or (string< (nth 1 a) (nth 1 b))
                                                       (and (string= (nth 1 a) (nth 1 b)) (string< (nth 2 a) (nth 2 b)))))))))
    (if keyed
        (fsum--table '("Owner" "Task" "State" "Next step or blocker") (mapcar #'cl-fourth keyed))
      "No tasks retained.\n")))

(defun fsum--operators-cell (member)
  "Rollup of MEMBER's task classes, e.g. `1 working, 1 decision'."
  (let ((counts nil))
    (dolist (task (plist-get member :tasks))
      (let ((c (car (fsum--classify task))))
        (cl-incf (alist-get c counts 0))))
    (if (null counts) "none"
      (mapconcat (lambda (c) (format "%d %s" (cdr c) (car c)))
                 (sort counts (lambda (a b) (< (cl-position (car a) fsum-classes) (cl-position (car b) fsum-classes))))
                 ", "))))

(defun fsum--health-cell (member)
  "Session / health cell for MEMBER."
  (pcase (plist-get member :status)
    ("declared-not-created" "declared in config, not created")
    ("read-failed" (format "read failed: %s" (plist-get member :error)))
    (_ (let* ((c (plist-get member :commander)) (parts (list (or (plist-get member :commander-label) "none"))))
         (when (member (plist-get member :lifecycle) '("parked" "parking" "retiring"))
           (push (plist-get member :lifecycle) parts))
         (unless (plist-get member :supervision) (push "watch paused" parts))
         (when (> (or (plist-get member :pending-events) 0) 0)
           (push (format "%s pending" (fsum--plural (plist-get member :pending-events) "event")) parts))
         (when (plist-get c :pending-question) (push "native question waiting" parts))
         (when (> (or (plist-get c :pending-approvals) 0) 0) (push "native approval waiting" parts))
         (dolist (k (plist-get member :failed-operations)) (push (format "op %s failed" k) parts))
         (string-join (nreverse parts) " · ")))))

(defun fsum--focus-cell (member requests)
  "Focus cell: open delegations for the root, the charter for a lieutenant."
  (cond
   ((not (equal (plist-get member :status) "observed")) "—")
   ((equal (plist-get member :role) "root")
    (if requests (format "%s open to lieutenants" (fsum--plural (length requests) "request")) "direct work"))
   (t (let ((mine (cl-remove-if-not (lambda (r) (equal (plist-get r :child-fleet-id) (plist-get member :id))) requests)))
        (fsum--cell (concat (or (plist-get member :charter) "")
                            (if mine (format " (%s open)" (fsum--plural (length mine) "request")) ""))
                    fsum-focus-width)))))

(defun fsum--supervisor-table (bearings)
  "Markdown supervisor table."
  (let ((requests (plist-get bearings :requests)))
    (fsum--table '("Supervisor" "Session / health" "Focus" "Operators")
                 (mapcar (lambda (m)
                           (list (if (equal (plist-get m :role) "root")
                                     (format "Commander (`%s`)" (plist-get m :name))
                                   (format "`%s`" (plist-get m :name)))
                                 (fsum--cell (fsum--health-cell m))
                                 (fsum--focus-cell m requests)
                                 (fsum--cell (if (equal (plist-get m :status) "observed") (fsum--operators-cell m) "—"))))
                         (plist-get bearings :members)))))

;;;; Needs you / synthesis

(defun fsum--needs-you (bearings)
  "Bullets for what genuinely needs the user.
Human-authority decisions, native prompts only a human can answer, lost
runtimes and lieutenants without a session; commander-authority work is not."
  (let (items)
    (dolist (m (plist-get bearings :members))
      (let ((owner (fsum--owner m)) (c (plist-get m :commander)))
        (when (equal (plist-get m :status) "observed")
          (when (plist-get c :pending-question)
            (push (format "%s has a native question waiting in its chat: %s" owner (fsum--cell (plist-get c :pending-question))) items))
          (when (> (or (plist-get c :pending-approvals) 0) 0)
            (push (format "%s has a native tool approval waiting in its chat" owner) items))
          (when (and (equal (plist-get m :role) "lieutenant")
                     (member (plist-get c :lifecycle) '(nil "stopped" "never-launched" "lost" "stop-unknown"))
                     (not (member (plist-get m :lifecycle) '("parked" "parking"))))
            (push (format "Lieutenant `%s` has no live session (%s); only you restart it" (plist-get m :name)
                          (or (plist-get m :commander-label) "none"))
                  items)))
        (dolist (task (plist-get m :tasks))
          (pcase-let ((`(,class ,_label ,next) (fsum--classify task)))
            (pcase class
              ('decision (when (equal (fsum--decision-authority task) "human")
                           (push (format "Decide for `%s` (%s): %s" (plist-get task :name) owner (fsum--cell next)) items)))
              ('native (push (format "`%s` (%s): %s" (plist-get task :name) owner (fsum--cell next)) items))
              ((or 'dead 'unknown) (push (format "`%s` (%s): %s" (plist-get task :name) owner (fsum--cell next)) items)))))))
    (nreverse items)))

(defun fsum--supervisor-queue (bearings)
  "One line of what supervisors are handling themselves, or nil."
  (let ((cmd-decisions 0) (unrouted 0) (blocked 0) (failed 0) (events 0) (done 0))
    (dolist (m (plist-get bearings :members))
      (cl-incf events (or (plist-get m :pending-events) 0))
      (dolist (task (plist-get m :tasks))
        (pcase (car (fsum--classify task))
          ('decision (pcase (fsum--decision-authority task)
                       ("human" nil)
                       ("commander" (cl-incf cmd-decisions))
                       (_ (cl-incf unrouted))))
          ('blocked (cl-incf blocked))
          ('failed (cl-incf failed))
          ('done (cl-incf done)))))
    (let ((parts (delq nil (list (and (> cmd-decisions 0) (fsum--plural cmd-decisions "commander-authority decision"))
                                 (and (> unrouted 0) (fsum--plural unrouted "decision with unverified routing" "decisions with unverified routing"))
                                 (and (> blocked 0) (fsum--plural blocked "blocked task"))
                                 (and (> failed 0) (fsum--plural failed "failed task"))
                                 (and (> done 0) (format "%s to verify" (fsum--plural done "reported-done task")))
                                 (and (> events 0) (fsum--plural events "pending event"))))))
      (and parts (concat "Supervisors' queue: " (string-join parts ", ") ".")))))

(defun fsum--synthesis (bearings rows)
  "One sentence summarizing ROWS and member liveness."
  (let* ((count (lambda (&rest classes) (cl-count-if (lambda (r) (memq (car r) classes)) rows)))
         (members (plist-get bearings :members))
         (observed (cl-count "observed" members :key (lambda (m) (plist-get m :status)) :test #'equal))
         (live (cl-count-if (lambda (m) (and (equal (plist-get m :status) "observed")
                                             (equal (plist-get (plist-get m :commander) :lifecycle) "ready")))
                            members))
         (parts (delq nil (list (let ((n (funcall count 'working))) (and (> n 0) (format "%s moving" (fsum--plural n "task"))))
                                (let ((n (funcall count 'decision 'native))) (and (> n 0) (format "%d waiting on an answer" n)))
                                (let ((n (funcall count 'blocked 'failed 'dead 'unknown))) (and (> n 0) (format "%d blocked, failed or lost" n)))
                                (let ((n (funcall count 'paused))) (and (> n 0) (format "%d in a declared wait" n)))
                                (let ((n (funcall count 'done))) (and (> n 0) (format "%d reported done pending verification" n)))
                                (let ((n (funcall count 'done-verified 'closing))) (and (> n 0) (format "%d verified awaiting closeout" n)))
                                (let ((n (funcall count 'suspended))) (and (> n 0) (format "%d suspended by park" n)))))))
    (format "%s; %d of %s live%s."
            (if parts (string-join parts ", ") (if rows "Nothing is moving" "No tasks retained"))
            live (fsum--plural (length members) "supervisor")
            (if (< observed (length members)) (format ", %d not observed" (- (length members) observed)) ""))))

;;;; Render

(defun fsum-render (bearings)
  "Markdown bearings for the evidence plist BEARINGS from `fleet-read-bearings'."
  (let* ((rows (fsum--task-rows bearings))
         (needs (fsum--needs-you bearings))
         (queue (fsum--supervisor-queue bearings))
         (diagnostics (plist-get bearings :diagnostics))
         (owners (cl-remove-duplicates (mapcar #'cadr rows) :test #'equal)))
    (concat
     (format "**Fleet `%s` — observed %s**\n\n" (plist-get (plist-get bearings :root) :name) (fsum--hhmm (plist-get bearings :observed-at)))
     (fsum--synthesis bearings rows) "\n\n"
     (fsum--supervisor-table bearings) "\n"
     (fsum--work-table rows) "\n"
     "**Needs you**\n"
     (if needs (mapconcat (lambda (i) (concat "- " i)) needs "\n") "- Nothing needs you right now.")
     "\n"
     (if queue (concat "\n" queue "\n") "")
     (if diagnostics (concat "\n**Coverage**\n" (mapconcat (lambda (d) (concat "- " (fsum--clean d))) diagnostics "\n") "\n") "")
     (if (and (>= (length needs) fsum-frev-hint-threshold) (> (length owners) 1))
         (format "\n_%d items need you across %d owners — `/frev` is the place to work through them together._\n" (length needs) (length owners))
       ""))))

(cl-defun fsum-bearings (&key session-fleet-id selector runtime-id)
  "Read the selected root once and return its bearings as Markdown.
Arguments as for `fleet-read-bearings'.  A read that cannot start (store not
open, unknown or conflicting selector, lieutenant chosen) is returned as a
short Markdown limitation with its stable code rather than signaled, so the
caller can show it verbatim."
  (condition-case err
      (fsum-render (fleet-read-bearings :session-fleet-id session-fleet-id :selector selector :runtime-id runtime-id))
    (fleet-read-error
     (format "**/fsum could not observe the fleet** — `%s`: %s\n\nThis is a limitation to report, not permission to start, resume or repair anything.\n"
             (fleet-read-error-code err) (fleet-read-error-message err)))))

(provide 'fsum)
;;; fsum.el ends here
