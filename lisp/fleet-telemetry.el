;;; fleet-telemetry.el --- Retrospective views over the durable record -*- lexical-binding: t; -*-

;;; Commentary:

;; Read-only.  Everything here is derived from the `events', `operations',
;; `messages', `event_receipts' and `wake_batches' tables, so it works on a
;; live store, a read-only second Emacs, or a backup opened by hand.
;;
;;   M-x fleet-timeline  chronological log of one fleet with latencies
;;   M-x fleet-stats     counts, latencies, tool calls, refusals, tokens

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'fleet-paths)
(require 'fleet-store)
(require 'fleet-supervisor)

(defun fleet-telemetry--secs (from to)
  "Seconds between ISO timestamps FROM and TO, or nil."
  (fleet-paths-seconds-between from to))

(defun fleet-telemetry--num (v)
  "V as a number, or nil.  ECA sends costs as strings (\"0.11\")."
  (cond ((numberp v) v)
        ((and (stringp v) (string-match-p "\\`-?[0-9.]+\\'" v)) (string-to-number v))
        (t nil)))

(defun fleet-telemetry-turn-usage (turns)
  "Attribute tokens and cost to each of TURNS (payload plists, oldest first).
Returns a list of (:in N :out N :cost C :derived BOOL) aligned with TURNS.
Providers such as openai-responses report only session totals
\(`session-tokens', `session-cost') and null message-level fields; then the
turn's share is the increase of the session total since the previous turn of
the same runtime (the first turn gets the whole total).  Message-level fields
win when present."
  (let ((last-tokens (make-hash-table :test 'equal))
        (last-cost (make-hash-table :test 'equal)))
    (mapcar
     (lambda (p)
       (let* ((u (plist-get p :usage)) (rid (or (plist-get p :runtime-id) "?"))
              (min (fleet-telemetry--num (plist-get u :message-input-tokens)))
              (mout (fleet-telemetry--num (plist-get u :message-output-tokens)))
              (mcost (fleet-telemetry--num (plist-get u :message-cost)))
              (stok (fleet-telemetry--num (plist-get u :session-tokens)))
              (scost (fleet-telemetry--num (plist-get u :session-cost)))
              (derived nil)
              (in (or min (and stok (progn (setq derived t) (max 0 (- stok (gethash rid last-tokens 0)))))))
              (out (or mout (and min 0)))
              (cost (or mcost (and scost (max 0.0 (- scost (gethash rid last-cost 0.0)))))))
         (when stok (puthash rid stok last-tokens))
         (when scost (puthash rid scost last-cost))
         (list :in (or in 0) :out (or out 0) :cost (or cost 0.0) :derived derived)))
     turns)))

(defun fleet-telemetry--fmt-secs (s)
  "Compact duration string for S seconds (nil -> \"-\")."
  (cond ((null s) "-")
        ((< s 1) (format "%dms" (round (* 1000 s))))
        ((< s 90) (format "%.1fs" s))
        ((< s 5400) (format "%dm%02ds" (floor (/ s 60)) (mod (round s) 60)))
        (t (format "%dh%02dm" (floor (/ s 3600)) (mod (floor (/ s 60)) 60)))))

(defun fleet-telemetry--stats (values)
  "Return (:n N :mean M :p50 P :max X) over numeric VALUES."
  (let* ((vs (sort (cl-remove-if-not #'numberp values) #'<)) (n (length vs)))
    (if (= n 0) (list :n 0)
      (list :n n :mean (/ (apply #'+ vs) (float n)) :p50 (nth (/ n 2) vs) :max (car (last vs))))))

(defun fleet-telemetry--fmt-stats (st)
  "Render a stats plist ST."
  (if (= 0 (plist-get st :n)) "n=0"
    (format "n=%d mean %s p50 %s max %s" (plist-get st :n)
            (fleet-telemetry--fmt-secs (plist-get st :mean)) (fleet-telemetry--fmt-secs (plist-get st :p50))
            (fleet-telemetry--fmt-secs (plist-get st :max)))))

;;;; Data

(defun fleet-telemetry-summary (store fleet-id)
  "Compute the statistics plist for FLEET-ID from STORE (pure read)."
  (let* ((events (fleet-store-query store "SELECT * FROM events WHERE fleet_id = ? ORDER BY seq" fleet-id))
         (by-kind (make-hash-table :test 'equal))
         (tool-calls (make-hash-table :test 'equal))
         (refusals (make-hash-table :test 'equal))
         (turns nil) (usage-in 0) (usage-out 0) (cost 0.0) (turn-secs nil) (tokens-derived nil)
         (receipts (fleet-store-query store "SELECT r.*, e.created_at AS event_at FROM event_receipts r JOIN events e ON e.id = r.event_id WHERE r.fleet_id = ?" fleet-id))
         (batches (fleet-store-query store "SELECT b.*, m.created_at AS message_at FROM wake_batches b LEFT JOIN messages m ON m.id = b.message_id WHERE b.fleet_id = ?" fleet-id))
         (ops (fleet-store-query store "SELECT * FROM operations WHERE fleet_id = ?" fleet-id))
         (messages (fleet-store-query store "SELECT origin, state, COUNT(*) AS n FROM messages WHERE fleet_id = ? GROUP BY origin, state" fleet-id)))
    (dolist (e events)
      (cl-incf (gethash (plist-get e :kind) by-kind 0))
      (let ((p (fleet-store-unjson (plist-get e :payload))))
        (pcase (plist-get e :kind)
          ("tool-call"
           (cl-incf (gethash (plist-get p :operation) tool-calls 0))
           (unless (equal (plist-get p :outcome) "ok")
             (cl-incf (gethash (format "%s: %s" (plist-get p :operation) (plist-get p :code)) refusals 0))))
          ("turn-finished"
           (push (plist-put (copy-sequence p) :runtime-id (plist-get e :runtime-id)) turns)
           (when (plist-get p :seconds) (push (plist-get p :seconds) turn-secs))))))
    (dolist (u (fleet-telemetry-turn-usage (reverse turns)))
      (cl-incf usage-in (plist-get u :in))
      (cl-incf usage-out (plist-get u :out))
      (cl-incf cost (plist-get u :cost))
      (when (plist-get u :derived) (setq tokens-derived t)))
    (let* ((event->wake (cl-loop for r in receipts
                                 for b = (cl-find-if (lambda (b) (equal (plist-get b :id) (plist-get r :batch-id))) batches)
                                 when (and b (plist-get b :message-at)) collect (fleet-telemetry--secs (plist-get r :event-at) (plist-get b :message-at))))
           (event->ack (cl-loop for r in receipts when (plist-get r :acked-at) collect (fleet-telemetry--secs (plist-get r :event-at) (plist-get r :acked-at))))
           (op-durations (make-hash-table :test 'equal)))
      (dolist (op ops)
        (push (fleet-telemetry--secs (plist-get op :created-at) (plist-get op :updated-at)) (gethash (plist-get op :kind) op-durations)))
      (list :events (length events)
            :by-kind (let (l) (maphash (lambda (k v) (push (cons k v) l)) by-kind) (sort l (lambda (a b) (> (cdr a) (cdr b)))))
            :tool-calls (let (l) (maphash (lambda (k v) (push (cons k v) l)) tool-calls) (sort l (lambda (a b) (> (cdr a) (cdr b)))))
            :refusals (let (l) (maphash (lambda (k v) (push (cons k v) l)) refusals) l)
            :turns (length turns)
            :turn-seconds (fleet-telemetry--stats turn-secs)
            :tokens-in usage-in :tokens-out usage-out :cost cost :tokens-derived tokens-derived
            :receipts (length receipts)
            :unacknowledged (cl-count-if (lambda (r) (not (equal (plist-get r :state) "acknowledged"))) receipts)
            :event->wake (fleet-telemetry--stats event->wake)
            :event->ack (fleet-telemetry--stats event->ack)
            :wakes (length batches)
            :reminders (cl-count-if (lambda (b) (eql 1 (plist-get b :reminder-used))) batches)
            :held-batches (cl-count-if (lambda (b) (member (plist-get b :state) '("held" "needs-reconciliation"))) batches)
            :operations (let (l) (maphash (lambda (k v) (push (cons k (fleet-telemetry--stats v)) l)) op-durations) l)
            :failed-operations (cl-count-if (lambda (o) (equal (plist-get o :state) "failed")) ops)
            :messages (mapcar (lambda (m) (list (plist-get m :origin) (plist-get m :state) (plist-get m :n))) messages)))))

(defun fleet-telemetry-timeline (store fleet-id &optional limit)
  "Chronological rows (plists) for FLEET-ID, at most LIMIT.
Each row has :at :kind :task :runtime :summary :latency."
  (let* ((tasks (make-hash-table :test 'equal))
         (events (fleet-store-query store (format "SELECT * FROM events WHERE fleet_id = ? ORDER BY seq %s" (if limit (format "LIMIT %d" limit) "")) fleet-id)))
    (dolist (task (fleet-store-tasks store fleet-id t)) (puthash (plist-get task :id) (plist-get task :name) tasks))
    (mapcar
     (lambda (e)
       (let* ((p (fleet-store-unjson (plist-get e :payload)))
              (receipt (and (eql 1 (plist-get e :actionable))
                            (fleet-store-query1 store "SELECT r.state, r.acked_at, m.created_at AS wake_at FROM event_receipts r LEFT JOIN wake_batches b ON b.id = r.batch_id LEFT JOIN messages m ON m.id = b.message_id WHERE r.event_id = ?" (plist-get e :id)))))
         (list :at (plist-get e :created-at) :kind (plist-get e :kind)
               :task (and (plist-get e :task-id) (or (gethash (plist-get e :task-id) tasks) (fleet-paths-short-id (plist-get e :task-id))))
               :runtime (and (plist-get e :runtime-id) (fleet-paths-short-id (plist-get e :runtime-id)))
               :actionable (eql 1 (plist-get e :actionable))
               :summary (fleet-telemetry--summarize (plist-get e :kind) p)
               :latency (and receipt
                             (format "wake %s · ack %s%s"
                                     (fleet-telemetry--fmt-secs (fleet-telemetry--secs (plist-get e :created-at) (plist-get receipt :wake-at)))
                                     (fleet-telemetry--fmt-secs (fleet-telemetry--secs (plist-get e :created-at) (plist-get receipt :acked-at)))
                                     (if (equal (plist-get receipt :state) "acknowledged") "" (format " [%s]" (plist-get receipt :state))))))))
     events)))

(defun fleet-telemetry--summarize (kind p)
  "One-line summary of payload P for event KIND."
  (pcase kind
    ("tool-call" (format "%s → %s%s (%dms)" (plist-get p :operation) (plist-get p :outcome)
                         (if (plist-get p :code) (format " %s" (plist-get p :code)) "") (or (plist-get p :ms) 0)))
    ("turn-finished" (let ((u (plist-get p :usage)))
                       (format "%s turn %s%s%s" (or (plist-get p :origin) "?")
                               (fleet-telemetry--fmt-secs (plist-get p :seconds))
                               (cond ((and u (plist-get u :message-input-tokens))
                                      (format " · %s+%s tok" (plist-get u :message-input-tokens) (or (plist-get u :message-output-tokens) "?")))
                                     ((and u (plist-get u :session-tokens))
                                      (format " · session %s tok%s" (plist-get u :session-tokens)
                                              (if (plist-get u :session-cost) (format " $%s" (plist-get u :session-cost)) "")))
                                     (t ""))
                               (cond ((plist-get p :stopped) " · stopped") ((plist-get p :error) " · error") (t "")))))
    ((or "task-done" "task-failed" "task-blocked" "task-working" "task-paused" "decision-requested" "runtime-waiting-long")
     (or (plist-get p :detail) ""))
    ("operation-failed" (format "%s@%s: %s" (plist-get p :kind) (plist-get p :step) (plist-get p :error)))
    ("message-rejected" (format "%s: %s" (plist-get p :origin) (plist-get p :code)))
    ("events-acknowledged" (format "%d id(s): %s" (length (plist-get p :ids)) (plist-get p :outcome)))
    ("brief-revised" (format "revision %s" (plist-get p :revision)))
    ("runtime-reconciled" (format "verdict %s" (plist-get p :verdict)))
    ("task-archived" (format "worktree-removed=%s branch-deleted=%s" (plist-get p :worktree-removed) (plist-get p :branch-deleted)))
    (_ (let ((s (and p (fleet-store-json p)))) (if (and s (> (length s) 100)) (concat (substring s 0 100) "…") (or s ""))))))

;;;; Commands

(defun fleet-telemetry--read-fleet (prompt)
  "Read any fleet (archived included) by name; return its row."
  (let* ((store (fleet-supervisor-store))
         (fleets (fleet-store-fleets store t))
         (name (completing-read prompt (mapcar (lambda (f) (plist-get f :name)) fleets) nil t)))
    (or (cl-find-if (lambda (f) (equal (plist-get f :name) name)) fleets)
        (user-error "No such fleet"))))

;;;###autoload
(defun fleet-timeline (fleet-name)
  "Show the chronological event timeline of FLEET-NAME with wake/ack latencies."
  (interactive (list (plist-get (fleet-telemetry--read-fleet "Timeline for fleet: ") :name)))
  (let* ((store (fleet-supervisor-store))
         (fleet (or (cl-find-if (lambda (f) (equal (plist-get f :name) fleet-name)) (fleet-store-fleets store t)) (user-error "No such fleet")))
         (rows (fleet-telemetry-timeline store (plist-get fleet :id)))
         (buf (get-buffer-create (format "*fleet-timeline: %s*" fleet-name))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Timeline — fleet %s (%s), %d events\n\n" fleet-name (plist-get fleet :lifecycle) (length rows)))
        (dolist (r rows)
          (insert (format "%s  %-22s %-16s %-8s %s%s\n"
                          (substring (plist-get r :at) 11 19)
                          (truncate-string-to-width (plist-get r :kind) 22 nil nil "…")
                          (truncate-string-to-width (or (plist-get r :task) "") 16 nil nil "…")
                          (or (plist-get r :runtime) "")
                          (propertize (or (plist-get r :summary) "") 'face (if (plist-get r :actionable) 'warning 'default))
                          (if (plist-get r :latency) (propertize (format "  ⟨%s⟩" (plist-get r :latency)) 'face 'shadow) ""))))
        (goto-char (point-min))
        (special-mode)))
    (pop-to-buffer buf)))

;;;###autoload
(defun fleet-stats (fleet-name)
  "Show supervision statistics for FLEET-NAME.
Latencies, tool calls, refusals, tokens and cost."
  (interactive (list (plist-get (fleet-telemetry--read-fleet "Stats for fleet: ") :name)))
  (let* ((store (fleet-supervisor-store))
         (fleet (or (cl-find-if (lambda (f) (equal (plist-get f :name) fleet-name)) (fleet-store-fleets store t)) (user-error "No such fleet")))
         (s (fleet-telemetry-summary store (plist-get fleet :id)))
         (buf (get-buffer-create (format "*fleet-stats: %s*" fleet-name))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Fleet %s (%s)\n\n" fleet-name (plist-get fleet :lifecycle)))
        (insert (format "Events: %d   Actionable receipts: %d (unacknowledged %d)\n" (plist-get s :events) (plist-get s :receipts) (plist-get s :unacknowledged)))
        (insert (format "Wakes: %d   reminders: %d   held/reconcile batches: %d\n" (plist-get s :wakes) (plist-get s :reminders) (plist-get s :held-batches)))
        (insert (format "Latency event→wake: %s\nLatency event→ack:  %s\n" (fleet-telemetry--fmt-stats (plist-get s :event->wake)) (fleet-telemetry--fmt-stats (plist-get s :event->ack))))
        (insert (format "\nTurns: %d   duration: %s\n" (plist-get s :turns) (fleet-telemetry--fmt-stats (plist-get s :turn-seconds))))
        (insert (if (plist-get s :tokens-derived)
                    (format "Tokens: %d (session totals; provider gave no per-message split)   cost: %.4f\n" (plist-get s :tokens-in) (plist-get s :cost))
                  (format "Tokens: %d in / %d out   cost: %.4f\n" (plist-get s :tokens-in) (plist-get s :tokens-out) (plist-get s :cost))))
        (insert "\nTool calls:\n")
        (if (plist-get s :tool-calls)
            (dolist (c (plist-get s :tool-calls)) (insert (format "  %5d  %s\n" (cdr c) (car c))))
          (insert "  none\n"))
        (insert "\nRefusals/errors:\n")
        (if (plist-get s :refusals)
            (dolist (c (plist-get s :refusals)) (insert (format "  %5d  %s\n" (cdr c) (car c))))
          (insert "  none\n"))
        (insert (format "\nOperations (failed %d):\n" (plist-get s :failed-operations)))
        (dolist (o (plist-get s :operations)) (insert (format "  %-16s %s\n" (car o) (fleet-telemetry--fmt-stats (cdr o)))))
        (insert "\nMessages by origin/state:\n")
        (dolist (m (plist-get s :messages)) (insert (format "  %5d  %s %s\n" (nth 2 m) (nth 0 m) (nth 1 m))))
        (insert "\nEvents by kind:\n")
        (dolist (k (plist-get s :by-kind)) (insert (format "  %5d  %s\n" (cdr k) (car k))))
        (goto-char (point-min))
        (special-mode)))
    (pop-to-buffer buf)))

(provide 'fleet-telemetry)
;;; fleet-telemetry.el ends here
