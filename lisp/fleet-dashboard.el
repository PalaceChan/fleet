;;; fleet-dashboard.el --- Rendering and navigation; no state derivation -*- lexical-binding: t; -*-

;;; Commentary:

;; A read-only, hierarchical view over `fleet-store-snapshot'.  Rows carry
;; (FLEET-ID . TASK-ID-or-commander) identity so refresh preserves the
;; selected entity rather than a character offset, and every action
;; revalidates identity and revision before mutating.  The dashboard never
;; drains or acknowledges events and never performs Git/systemd/network work
;; while rendering.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'hl-line)
(require 'view)
(require 'fleet-paths)
(require 'fleet-store)
(require 'fleet-core)
(require 'fleet-supervisor)

(declare-function fleet-park "fleet")
(declare-function fleet-dashboard-ensure-started "fleet")
(declare-function dired "dired")

(defconst fleet-dashboard-buffer-name "fleet:*")
(defconst fleet-dashboard-peek-buffer-name "fleet-peek*")
(defconst fleet-dashboard-refresh-delay 0.2 "Coalescing delay after a committed change.")
(defconst fleet-dashboard-age-interval 30 "Age redisplay interval while visible.")

;;;; Faces and glyphs

(defface fleet-dashboard-header '((t :inherit bold)) "Fleet header." :group 'fleet)
(defface fleet-dashboard-footer '((t :inherit shadow)) "Key footer." :group 'fleet)

(defconst fleet-dashboard-states
  ;; state . (face glyph ascii)
  '((unknown  warning "?" "?")
    (working  success "●" "*")
    (decision warning "◐" "?")
    (paused   warning "◌" "o")
    (suspended shadow "◌" "o")
    (stopping warning "◌" "o")
    (blocked  error   "×" "x")
    (failed   error   "!" "!")
    (dead     error   "!" "!")
    (done     shadow  "✓" "v")))

(defun fleet-dashboard--glyph (state)
  "Glyph for STATE, ASCII when the frame cannot show wide glyphs."
  (let ((e (assq state fleet-dashboard-states)))
    (if (and (display-graphic-p) (char-displayable-p (aref (nth 2 e) 0))) (nth 2 e) (nth 3 e))))

(defun fleet-dashboard--face (state) "Face for STATE." (nth 1 (assq state fleet-dashboard-states)))

;;;; Projection (design §12.2)

(defun fleet-dashboard-task-projection (task fleet)
  "Compute (STATE SOURCE DETAIL ATTENTION) for enriched TASK in FLEET.
The projection is derived from orthogonal facts.
STATE is a symbol from `fleet-dashboard-states'; SOURCE is
eca/status/runtime/nil."
  (let* ((rt (plist-get task :runtime))
         (lifecycle (plist-get task :lifecycle))
         (phase (plist-get task :phase))
         (detail (or (plist-get task :detail) ""))
         (rt-life (plist-get rt :lifecycle))
         (turn (plist-get rt :turn-state))
         (tool (and rt (fleet-store-unjson (plist-get rt :active-tool))))
         (pending-q (and rt (plist-get rt :pending-question)))
         (pending-a (and rt (plist-get rt :pending-approvals)))
         (failed-ops (cl-remove-if-not (lambda (o) (member (plist-get o :state) '("failed" "blocked"))) (plist-get task :operations)))
         (badge (cond ((member rt-life '("stop-unknown")) " · stop unknown")
                      (failed-ops (format " · op %s failed" (plist-get (car failed-ops) :kind)))
                      ((equal turn "unknown") " · delivery unknown")
                      ;; A lieutenant's result nobody upstream has heard of (docs/lieutenants.md §4).
                      ((plist-get task :report-owed) " · report owed upstream")
                      (t ""))))
    (cl-flet ((out (state source d attention) (list state source (concat d badge) (or attention (not (string-empty-p badge))))))
      (cond
       ((member rt-life '("stop-unknown"))
        (out 'unknown "runtime" (format "service stop unknown (%s)" (plist-get rt :unit)) t))
       ((member (plist-get fleet :lifecycle) '("parking"))
        (out 'stopping nil (if (member phase '("done" "failed")) (format "%s · %s" phase detail) "stopping operators") nil))
       ((equal lifecycle "suspended")
        (out 'suspended nil (if (member phase '("done" "failed")) (format "%s · %s" phase detail) detail) nil))
       ((equal lifecycle "closing") (out 'stopping "runtime" "teardown in progress" nil))
       ((and (equal rt-life "lost") (not (member phase '("done" "failed"))))
        (out 'dead "runtime" "runtime connection lost; service not proven stopped" t))
       ((or pending-q pending-a (equal phase "needs-decision"))
        (out 'decision (if (or pending-q pending-a) "eca" "status")
             (cond (pending-a (format "tool approval needed%s" (if (plist-get (car (plist-get task :decisions)) :question) "" "")))
                   (pending-q (format "question: %s" (or (plist-get (fleet-store-unjson pending-q) :question) "")))
                   (t (let ((d (car (plist-get task :decisions))))
                        (format "%s%s" (or (plist-get d :question) detail) (if d (format " [%s]" (fleet-paths-short-id (plist-get d :id))) "")))))
             t))
       ((equal phase "blocked") (out 'blocked "status" detail t))
       ((equal phase "failed") (out 'failed "status" detail t))
       ((equal phase "done")
        (out 'done "status" (if (equal turn "running") (format "%s · still responding" detail) detail) nil))
       ((equal phase "paused") (out 'paused "status" (format "waiting: %s" (or (plist-get task :wait-reason) detail)) nil))
       ((and rt (equal turn "running"))
        (out 'working "eca" (if tool (format "%s · tool %s %s" detail (plist-get tool :name) (fleet-dashboard--age (plist-get tool :since))) detail) nil))
       ;; Last working status with an observed runtime: idle is stated, not implied execution.
       ((and rt (equal phase "working"))
        (out 'working "status" (if (equal turn "idle") (format "%s · idle, awaiting next step" detail) detail) nil))
       ((equal lifecycle "ready") (out 'suspended nil "ready to start" nil))
       (t (out 'unknown nil (if (string-empty-p detail) "no execution evidence" detail) t))))))

(defun fleet-dashboard-commander-status (fleet)
  "Return (LABEL SEVERITY) describing FLEET's commander."
  (let* ((rt (plist-get fleet :commander))
         (life (plist-get rt :lifecycle)) (turn (plist-get rt :turn-state)))
    (cond
     ((null rt) (list "none" 'warn))
     ((equal life "ready") (list (format "live/%s" (cond ((equal turn "running") "busy") ((equal turn "unknown") "unknown") (t "idle")))
                                 (if (equal turn "unknown") 'warn nil)))
     ((member life '("launching" "starting")) (list "starting" nil))
     ((member life '("stopped" "never-launched")) (list "stopped" 'warn))
     ((equal life "lost") (list "lost" 'error))
     ((equal life "stop-unknown") (list "stop-unknown" 'error))
     (t (list life 'warn)))))

(defun fleet-dashboard-attention-p (projection)
  "Non-nil when PROJECTION (from `fleet-dashboard-task-projection') needs the user."
  (nth 3 projection))

;;;; Formatting

(defun fleet-dashboard--age (iso)
  "Compact age of ISO timestamp: <90s seconds, <90m minutes, else hours."
  (if (not (and iso (stringp iso)))
      ""
    (let* ((then (ignore-errors (float-time (date-to-time iso))))
           (secs (and then (max 0 (floor (- (float-time) then))))))
      (cond ((null secs) "")
            ((< secs 90) (format "%ds" secs))
            ((< secs 5400) (format "%dm" (/ secs 60)))
            (t (format "%dh" (/ secs 3600)))))))

(defun fleet-dashboard--clean (s)
  "Strip newlines and control characters from S."
  (replace-regexp-in-string "[[:cntrl:]]+" " " (or s "")))

(defun fleet-dashboard--fit (s width &optional right)
  "Truncate/pad S to WIDTH display columns; RIGHT aligns right."
  (let* ((s (fleet-dashboard--clean s))
         (tr (truncate-string-to-width s width nil nil "…"))
         (pad (max 0 (- width (string-width tr)))))
    (if right (concat (make-string pad ?\s) tr) (concat tr (make-string pad ?\s)))))

(defun fleet-dashboard--col-width (values min max)
  "Data-sized width of VALUES clamped to [MIN, MAX]."
  (min max (max min (apply #'max 0 (mapcar #'string-width values)))))

;;;; Buffer, mode, keys

(defvar fleet-dashboard-mode-map (make-sparse-keymap) "Keymap for `fleet-dashboard-mode'.")

(defun fleet-dashboard--define-keys ()
  "Define the exact key contract into the live map (re-run on every load)."
  (let ((map fleet-dashboard-mode-map))
    (define-key map (kbd "n") #'fleet-dash-next)
    (define-key map (kbd "p") #'fleet-dash-prev)
    (define-key map (kbd "N") #'fleet-dash-next-fleet)
    (define-key map (kbd "P") #'fleet-dash-prev-fleet)
    (define-key map (kbd "j") #'fleet-dash-jump)
    (define-key map (kbd "a") #'fleet-dash-attention)
    (define-key map (kbd "RET") #'fleet-dash-visit)
    (define-key map (kbd "<return>") #'fleet-dash-visit)
    (define-key map (kbd "v") #'fleet-dash-peek)
    (define-key map (kbd "s") #'fleet-dash-send)
    (define-key map (kbd "i") #'fleet-dash-interrupt)
    (define-key map (kbd "t") #'fleet-dash-teardown)
    (define-key map (kbd "b") #'fleet-dash-brief)
    (define-key map (kbd "r") #'fleet-dash-report)
    (define-key map (kbd "w") #'fleet-dash-worktree)
    (define-key map (kbd "X") #'fleet-dash-park)
    (define-key map (kbd "g") #'fleet-dash-refresh)
    (define-key map (kbd "?") #'fleet-dash-peek)
    ;; deliberately absent: d (drain), k (kill), destroy
    (define-key map (kbd "d") nil)
    (define-key map (kbd "k") nil)
    map))

(fleet-dashboard--define-keys)

(define-derived-mode fleet-dashboard-mode special-mode "Fleet"
  "Live grouped view of Fleet fleets and operators.
\\{fleet-dashboard-mode-map}"
  (setq truncate-lines t)
  (setq-local revert-buffer-function (lambda (&rest _) (fleet-dash-refresh)))
  (hl-line-mode 1)
  (add-hook 'fleet-supervisor-change-hook #'fleet-dashboard--on-change)
  (fleet-dashboard--age-timer-start))

(defvar fleet-dashboard--refresh-timer nil)
(defvar fleet-dashboard--age-timer nil)

(defun fleet-dashboard-buffer () "The dashboard buffer, created on demand." (get-buffer-create fleet-dashboard-buffer-name))

(defun fleet-dashboard--on-change (&rest _)
  "Coalesce refreshes after committed changes."
  (when (and (get-buffer fleet-dashboard-buffer-name) (not fleet-dashboard--refresh-timer))
    (setq fleet-dashboard--refresh-timer
          (run-with-timer fleet-dashboard-refresh-delay nil
                          (lambda ()
                            (setq fleet-dashboard--refresh-timer nil)
                            (when-let* ((buf (get-buffer fleet-dashboard-buffer-name)))
                              (with-current-buffer buf (ignore-errors (fleet-dashboard-render)))))))))

(defun fleet-dashboard--age-timer-start ()
  "Redisplay ages periodically while the dashboard is visible."
  (unless fleet-dashboard--age-timer
    (setq fleet-dashboard--age-timer
          (run-with-timer fleet-dashboard-age-interval fleet-dashboard-age-interval
                          (lambda ()
                            (when-let* ((buf (get-buffer fleet-dashboard-buffer-name)))
                              (if (get-buffer-window buf t)
                                  (with-current-buffer buf (ignore-errors (fleet-dashboard-render)))
                                nil)))))))

;;;; Rendering

(defvar-local fleet-dashboard--rows nil "List of row identities in buffer order.")

(defun fleet-dashboard--row-at (&optional pos)
  "Row identity (FLEET-ID . TASK-ID|commander) at POS."
  (get-text-property (or pos (point)) 'fleet-row))

(defun fleet-dashboard--revision-at (&optional pos)
  "Entity revision recorded on the row at POS."
  (get-text-property (or pos (point)) 'fleet-revision))

(defun fleet-dashboard-render ()
  "Render the snapshot, preserving selected identity, column and window start."
  (let* ((store (ignore-errors (fleet-supervisor-store)))
         (inhibit-read-only t)
         (sel (fleet-dashboard--row-at))
         (col (current-column))
         (win (get-buffer-window (current-buffer) t))
         (start-row (and win (fleet-dashboard--row-at (window-start win))))
         (snap (and store (fleet-store-snapshot store))))
    (erase-buffer)
    (setq fleet-dashboard--rows nil)
    (cond
     ((null store)
      (insert (propertize "Fleet is not started in this Emacs — M-x fleet-dashboard\n" 'face 'warning)))
     ((null (plist-get snap :fleets))
      (insert (propertize "no active fleets — M-x fleet-new\n" 'face 'shadow)))
     (t
      (when (fleet-supervisor-read-only-p)
        (insert (propertize "read-only: another Emacs owns this Fleet data root; actions must be taken there\n" 'face 'warning)))
      (when (and (not (fleet-supervisor-read-only-p)) (not (fleet-supervisor-owner-p)))
        (insert (propertize "ownership fenced: lease lost; restart Fleet to recover\n" 'face 'error)))
      (fleet-dashboard--insert-fleets (plist-get snap :fleets))))
    (insert "\n")
    (insert (propertize "n/p entry · N/P fleet · a attention · j jump · RET open · v peek · s send · i interrupt ·\nt teardown · b brief · r report · w worktree · X park fleet · g refresh · q quit"
                        'face 'fleet-dashboard-footer))
    (insert "\n")
    (setq fleet-dashboard--rows (nreverse fleet-dashboard--rows))
    (fleet-dashboard--restore sel col win start-row)))

(defun fleet-dashboard--insert-fleets (fleets)
  "Insert every fleet in FLEETS with its tasks."
  (let* ((all-tasks (apply #'append (mapcar (lambda (f) (plist-get f :tasks)) fleets)))
         (w-task (fleet-dashboard--col-width (mapcar (lambda (task) (plist-get task :name)) all-tasks) 12 28))
         (projections (mapcar (lambda (task) (cons (plist-get task :id) (fleet-dashboard-task-projection task (fleet-dashboard--fleet-of fleets task)))) all-tasks))
         (w-state (fleet-dashboard--col-width (mapcar (lambda (p) (fleet-dashboard--state-label (cdr p))) projections) 12 20))
         (w-repo (fleet-dashboard--col-width (mapcar #'fleet-dashboard--repo-label all-tasks) 4 20))
         (w-model (fleet-dashboard--col-width (mapcar #'fleet-dashboard--task-model-label all-tasks) 5 30)))
    ;; One group per root: its header and tasks, then each lieutenant's header and
    ;; tasks indented under it (docs/lieutenants.md §6).  A lieutenant whose root
    ;; is not in the snapshot is shown on its own rather than dropped.
    (let ((ids (mapcar (lambda (f) (plist-get f :id)) fleets)))
      (dolist (fleet fleets)
        (unless (member (plist-get fleet :parent-id) ids)
          (fleet-dashboard--insert-group fleet nil projections w-task w-state w-repo w-model)
          (dolist (lt fleets)
            (when (equal (plist-get lt :parent-id) (plist-get fleet :id))
              (fleet-dashboard--insert-group lt fleet projections w-task w-state w-repo w-model)))
          (insert "\n"))))))

(defun fleet-dashboard--insert-group (fleet parent projections w-task w-state w-repo w-model)
  "Insert FLEET's header and task rows; PARENT (a fleet or nil) sets the nesting."
  (fleet-dashboard--insert-header fleet projections parent)
  (dolist (task (plist-get fleet :tasks))
    (fleet-dashboard--insert-task fleet task (cdr (assoc (plist-get task :id) projections)) w-task w-state w-repo w-model (if parent "    " "  "))))

(defun fleet-dashboard--fleet-of (fleets task)
  "Fleet plist in FLEETS owning TASK."
  (cl-find-if (lambda (f) (equal (plist-get f :id) (plist-get task :fleet-id))) fleets))

(defun fleet-dashboard--state-label (p)
  "State/source column text for projection P."
  (if (nth 1 p) (format "%s·%s" (nth 0 p) (nth 1 p)) (symbol-name (nth 0 p))))

(defun fleet-dashboard--repo-label (task)
  "Repo column for TASK."
  (if (plist-get task :repo-path) (file-name-nondirectory (directory-file-name (plist-get task :repo-path))) "."))

(defun fleet-dashboard-model-label (rt &optional full)
  "Model column text for runtime RT: model/variant, or \"\" without a runtime.
The provider prefix is dropped unless FULL; the peek view shows full ids."
  (let ((model (and rt (plist-get rt :model))))
    (cond
     ((null model) (if (and rt (plist-get rt :variant)) (format "?/%s" (plist-get rt :variant)) ""))
     (t (concat (if full model (replace-regexp-in-string "\\`[^/]+/" "" model))
                (if (plist-get rt :variant) (format "/%s" (plist-get rt :variant)) ""))))))

(defun fleet-dashboard--task-model-label (task)
  "Model column for TASK from its current runtime, else the task's own request."
  (let ((rt (plist-get task :runtime)))
    (if rt (fleet-dashboard-model-label rt)
      (fleet-dashboard-model-label (and (or (plist-get task :model) (plist-get task :variant))
                                        (list :model (plist-get task :model) :variant (plist-get task :variant)))))))

(defun fleet-dashboard--tally (fleet projections)
  "Fixed-order tally string for FLEET from PROJECTIONS."
  (let ((counts (make-hash-table)))
    (dolist (task (plist-get fleet :tasks))
      (let ((s (car (cdr (assoc (plist-get task :id) projections)))))
        (puthash s (1+ (gethash s counts 0)) counts)))
    (let ((parts nil))
      (dolist (s '(working decision paused blocked failed dead unknown stopping suspended done))
        (when (> (gethash s counts 0) 0) (push (format "%d %s" (gethash s counts) s) parts)))
      (if parts (string-join (nreverse parts) ", ") "no tasks"))))

(defun fleet-dashboard--insert-header (fleet projections &optional parent)
  "Insert FLEET's header row; with PARENT, as a lieutenant group nested under it."
  (let* ((cmd (fleet-dashboard-commander-status fleet))
         (attention (cl-some (lambda (task) (fleet-dashboard-attention-p (cdr (assoc (plist-get task :id) projections)))) (plist-get fleet :tasks)))
         (severe (cl-some (lambda (task) (memq (car (cdr (assoc (plist-get task :id) projections))) '(blocked failed dead))) (plist-get fleet :tasks)))
         (face (cond ((or severe (eq (nth 1 cmd) 'error)) '(bold error))
                     ((or attention (eq (nth 1 cmd) 'warn) (> (plist-get fleet :pending-events) 0)) '(bold warning))
                     (t 'fleet-dashboard-header)))
         (lifecycle (plist-get fleet :lifecycle))
         (sup (cond ((member lifecycle '("parked" "parking" "retiring")) lifecycle)
                    ((eql 1 (plist-get fleet :supervision)) "supervision on")
                    (t "supervision paused")))
         (model (fleet-dashboard-model-label (plist-get fleet :commander)))
         (requests (length (plist-get fleet :open-requests)))
         (line (format "%s%s %s - %s %s%s · %s · wakes %d%s · %s"
                       (if parent "  " "") (if parent "↳" "Fleet") (plist-get fleet :name)
                       (if parent "lieutenant" "commander") (car cmd)
                       (if (string-empty-p model) "" (format " [%s]" model))
                       sup (plist-get fleet :queued-wakes)
                       (if (> requests 0) (format " · %d open request%s" requests (if (= requests 1) "" "s")) "")
                       (fleet-dashboard--tally fleet projections)))
         (beg (point)))
    (insert (propertize (fleet-dashboard--clean line) 'face face) "\n")
    (add-text-properties beg (point) (list 'fleet-row (cons (plist-get fleet :id) 'commander)
                                           'fleet-revision (plist-get fleet :entity-revision)
                                           'fleet-attention (and (memq (nth 1 cmd) '(warn error)) (not (member lifecycle '("parked")))) ))
    (push (cons (plist-get fleet :id) 'commander) fleet-dashboard--rows)))

(defun fleet-dashboard--insert-task (fleet task p w-task w-state w-repo w-model &optional indent)
  "Insert one TASK row of FLEET with projection P and column widths.
INDENT (default two spaces) nests lieutenant tasks under their group."
  (let* ((state (nth 0 p))
         (face (if (and (member (plist-get fleet :lifecycle) '("parked" "parking")) (memq state '(suspended stopping)))
                   'shadow
                 (fleet-dashboard--face state)))
         (beg (point)))
    (insert (or indent "  ")
            (propertize (fleet-dashboard--glyph state) 'face face) " "
            (propertize (fleet-dashboard--fit (plist-get task :name) w-task) 'face face) " "
            (propertize (fleet-dashboard--fit (fleet-dashboard--state-label p) w-state) 'face face) " "
            (fleet-dashboard--fit (plist-get task :kind) 6) " "
            (fleet-dashboard--fit (fleet-dashboard--repo-label task) w-repo) " "
            (propertize (fleet-dashboard--fit (fleet-dashboard--task-model-label task) w-model) 'face 'shadow) " "
            (fleet-dashboard--fit (fleet-dashboard--age (plist-get task :detail-at)) 5 t) " "
            (fleet-dashboard--clean (nth 2 p))
            "\n")
    (add-text-properties beg (point) (list 'fleet-row (cons (plist-get fleet :id) (plist-get task :id))
                                           'fleet-revision (plist-get task :entity-revision)
                                           'fleet-attention (fleet-dashboard-attention-p p)))
    (push (cons (plist-get fleet :id) (plist-get task :id)) fleet-dashboard--rows)))

(defun fleet-dashboard--goto-row (id)
  "Move point to the row with identity ID; return non-nil when found."
  (let ((pos (cl-loop for pos = (point-min) then (next-single-property-change pos 'fleet-row)
                      while pos
                      when (equal (get-text-property pos 'fleet-row) id) return pos)))
    (when pos (goto-char pos) t)))

(defun fleet-dashboard--restore (sel col win start-row)
  "Restore selection SEL/COL and window START-ROW after a render."
  (cond
   ((and sel (fleet-dashboard--goto-row sel)))
   (sel ;; vanished: next sibling, prior sibling, then its fleet header
    (let* ((fid (car sel))
           (siblings (cl-remove-if-not (lambda (r) (and (equal (car r) fid) (not (eq (cdr r) 'commander)))) fleet-dashboard--rows)))
      (or (and siblings (fleet-dashboard--goto-row (car siblings)))
          (fleet-dashboard--goto-row (cons fid 'commander))
          (goto-char (point-min)))))
   (t (goto-char (point-min))))
  (move-to-column col)
  (when (and win start-row)
    (save-excursion
      (when (fleet-dashboard--goto-row start-row)
        (set-window-start win (line-beginning-position))))))

;;;; Navigation

(defun fleet-dash-refresh ()
  "Refresh the snapshot and render; no lifecycle mutation."
  (interactive)
  (fleet-dashboard-render))

(defun fleet-dash-next ()
  "Next entry (fleet headers included); no wrap."
  (interactive)
  (let ((pos (next-single-property-change (line-end-position) 'fleet-row)))
    (while (and pos (null (get-text-property pos 'fleet-row)))
      (setq pos (next-single-property-change pos 'fleet-row)))
    (if pos (goto-char pos) (message "Last entry"))))

(defun fleet-dash-prev ()
  "Previous entry; no wrap."
  (interactive)
  (let ((pos (previous-single-property-change (line-beginning-position) 'fleet-row)))
    (while (and pos (> pos (point-min)) (null (get-text-property (1- pos) 'fleet-row)))
      (setq pos (previous-single-property-change pos 'fleet-row)))
    (if (and pos (> pos (point-min)))
        (progn (goto-char (1- pos)) (beginning-of-line))
      (message "First entry"))))

(defun fleet-dash-next-fleet ()
  "Next fleet header."
  (interactive)
  (let ((here (fleet-dashboard--row-at)))
    (or (cl-loop for r in (cdr (member here fleet-dashboard--rows))
                 when (eq (cdr r) 'commander) return (fleet-dashboard--goto-row r))
        (message "Last fleet"))))

(defun fleet-dash-prev-fleet ()
  "Previous fleet header; from a task, its own header."
  (interactive)
  (let* ((here (fleet-dashboard--row-at))
         (before (reverse (cl-subseq fleet-dashboard--rows 0 (or (cl-position here fleet-dashboard--rows :test #'equal) 0)))))
    (or (cl-loop for r in before when (eq (cdr r) 'commander) return (fleet-dashboard--goto-row r))
        (message "First fleet"))))

(defun fleet-dash-jump ()
  "Jump to a fleet or lieutenant header by selector (`root' or `root/child')."
  (interactive)
  (let* ((store (fleet-supervisor-store))
         (fleets (fleet-store-fleets store))
         (choices (mapcar (lambda (f) (cons (fleet-core-fleet-selector store f) f)) fleets))
         (name (completing-read "Fleet: " (mapcar #'car choices) nil t))
         (fleet (cdr (assoc name choices))))
    (when (fleet-dashboard--goto-row (cons (plist-get fleet :id) 'commander))
      (recenter 0))))

(defun fleet-dash-attention ()
  "Next entry requiring action, wrapping.
Header when only the commander has a problem."
  (interactive)
  (let* ((start (point))
         (next (lambda (from)
                 (cl-loop for pos = (next-single-property-change from 'fleet-row) then (next-single-property-change pos 'fleet-row)
                          while pos
                          when (and (get-text-property pos 'fleet-row) (get-text-property pos 'fleet-attention)) return pos))))
    (let ((pos (or (funcall next (line-end-position)) (funcall next (point-min)))))
      (cond ((and pos (or (/= pos start) (get-text-property start 'fleet-attention))) (goto-char pos))
            ((get-text-property (line-beginning-position) 'fleet-attention) (message "Only this entry needs attention"))
            (t (message "Nothing needs attention"))))))

;;;; Row helpers for actions

(defun fleet-dashboard--target ()
  "Return (STORE FLEET TASK-OR-NIL REVISION) for the row at point, or signal."
  (let* ((id (or (fleet-dashboard--row-at) (user-error "No entry at point")))
         (store (fleet-supervisor-store))
         (fleet (or (fleet-store-get store "fleets" (car id)) (user-error "Fleet no longer exists")))
         (task (and (not (eq (cdr id) 'commander)) (fleet-store-get store "tasks" (cdr id)))))
    (when (and (not (eq (cdr id) 'commander)) (null task)) (user-error "Task no longer exists; refresh"))
    (list store fleet task (fleet-dashboard--revision-at))))

(defun fleet-dashboard--revalidate (target)
  "Signal when the entity of TARGET changed since the row was rendered."
  (pcase-let ((`(,store ,fleet ,task ,rev) target))
    (let ((current (if task (plist-get (fleet-store-get store "tasks" (plist-get task :id)) :entity-revision)
                     (plist-get (fleet-store-get store "fleets" (plist-get fleet :id)) :entity-revision))))
      (unless (eql current rev)
        (fleet-dashboard-render)
        (user-error "Entry changed while you were deciding; refreshed — please retry")))))

(defun fleet-dashboard--runtime (task-or-fleet)
  "Runtime row for a task or a fleet's commander."
  (let ((store (fleet-supervisor-store)))
    (if (plist-get task-or-fleet :kind)
        (and (plist-get task-or-fleet :current-runtime-id) (fleet-store-get store "runtimes" (plist-get task-or-fleet :current-runtime-id)))
      (and (plist-get task-or-fleet :commander-runtime-id) (fleet-store-get store "runtimes" (plist-get task-or-fleet :commander-runtime-id))))))

(defun fleet-dashboard--require-owner ()
  "Refuse actions in read-only or fenced mode."
  (when (fleet-supervisor-read-only-p) (user-error "Read-only: another Emacs owns this Fleet; act there"))
  (unless (fleet-supervisor-owner-p) (user-error "Fleet ownership is fenced in this Emacs; restart Fleet (fleet-dashboard) to recover")))

;;;; Actions

(defun fleet-dash-visit ()
  "Header -> commander chat; task -> operator chat.
Never creates an empty fake buffer."
  (interactive)
  (pcase-let ((`(,_store ,fleet ,task ,_rev) (fleet-dashboard--target)))
    (let* ((rt (fleet-dashboard--runtime (or task fleet)))
           (conn (and rt (fleet-eca-conn (plist-get rt :id)))))
      (cond
       ((and conn (fleet-eca-visit conn)))
       (rt (fleet-dashboard--show-unavailable (or task fleet) rt))
       (t (message "%s has no runtime yet%s" (if task "Task" "Fleet commander")
                   (if task "; the commander starts it, or resume the fleet" " — M-x fleet-new to start one")))))))

(defun fleet-dashboard--show-unavailable (entity rt)
  "Show honest recovery information for ENTITY whose runtime RT has no live chat."
  (let ((buf (get-buffer-create fleet-dashboard-peek-buffer-name))
        (conn (fleet-eca-conn (plist-get rt :id)))
        (store (fleet-supervisor-store)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "%s `%s` has no live chat.\n\nRuntime %s: lifecycle %s, unit %s\nstop evidence: %s\n\n"
                        (if (plist-get entity :kind) "Task" "Fleet") (plist-get entity :name)
                        (plist-get rt :id) (plist-get rt :lifecycle) (plist-get rt :unit)
                        (or (plist-get rt :stop-evidence) "none")))
        (insert (pcase (plist-get rt :lifecycle)
                  ((or "stopped" "never-launched") "Recovery: resume via M-x fleet-new (parked fleet) or ask the commander to start the task again.\n")
                  ("lost" "Recovery: the service is not proven stopped. M-x fleet-doctor shows it; park (X) or fleet-commander-stop runs the verified stop.\n")
                  ("stop-unknown" "Recovery: stop verdict unknown. Inspect the unit with `systemctl --user status <unit>`; no replacement until proven stopped.\n")
                  (_ "The connection is not attached in this Emacs (restart?). Runtime reconciliation runs when Fleet starts.\n")))
        (insert "\nRetained transcript (last 40 entries):\n\n")
        (insert (or (and conn (fleet-eca-peek conn 40))
                    (let ((f (expand-file-name "transcript.jsonl" (fleet-core--run-dir store rt))))
                      (and (file-readable-p f) (fleet-eca-transcript-tail f 40)))
                    "(no transcript)"))
        (goto-char (point-min))
        (special-mode)))
    (display-buffer buf)))

(defun fleet-dash-peek ()
  "Read-only snapshot of the last 40 logical lines of the chat at point."
  (interactive)
  (pcase-let ((`(,store ,fleet ,task ,_rev) (fleet-dashboard--target)))
    (let* ((rt (fleet-dashboard--runtime (or task fleet)))
           (conn (and rt (fleet-eca-conn (plist-get rt :id))))
           (text (or (and conn (fleet-eca-peek conn 40))
                     (and rt (let ((f (expand-file-name "transcript.jsonl" (fleet-core--run-dir store rt))))
                               (and (file-readable-p f) (fleet-eca-transcript-tail f 40))))
                     "(no chat or transcript yet)"))
           (buf (get-buffer-create fleet-dashboard-peek-buffer-name)))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "%s — %s%s\n\n" (if task (format "operator %s" (plist-get task :name)) (format "commander of %s" (plist-get fleet :name)))
                          (if conn (format "live chat, %s" (fleet-eca-conn-state conn)) "retained transcript")
                          (let ((m (fleet-dashboard-model-label rt t))) (if (string-empty-p m) "" (format " — model %s" m)))))
          (insert text)
          (goto-char (point-max))
          (special-mode)))
      (display-buffer buf))))

(defun fleet-dash-send ()
  "Send one minibuffer message to the commander (header) or operator (task)."
  (interactive)
  (fleet-dashboard--require-owner)
  (pcase-let* ((target (fleet-dashboard--target)) (`(,store ,fleet ,task ,_rev) target))
    (let* ((rt (fleet-dashboard--runtime (or task fleet))))
      (unless (and rt (equal (plist-get rt :lifecycle) "ready"))
        (user-error "Target has no ready runtime (%s); it is not restarted implicitly" (or (plist-get rt :lifecycle) "none")))
      (let* ((conn (fleet-eca-conn (plist-get rt :id)))
             (q (and conn (fleet-eca-conn-pending-question conn))))
        (if q
            (let ((answer (completing-read (format "Answer question \"%s\": " (plist-get q :question)) (plist-get q :options) nil (not (plist-get q :allow-freeform)))))
              (fleet-dashboard--revalidate target)
              (fleet-eca-answer-question conn (plist-get q :request-id) answer)
              (message "Answered pending question"))
          (let ((text (read-string (format "Message to %s: " (if task (plist-get task :name) (format "commander %s" (plist-get fleet :name)))))))
            (when (string-blank-p text) (user-error "Empty message"))
            (fleet-dashboard--revalidate target)
            (let ((r (fleet-supervisor-send store :fleet-id (plist-get fleet :id) :task-id (and task (plist-get task :id))
                                            :runtime-id (plist-get rt :id) :text text :sender fleet-core-actor-human)))
              (message "Message %s" (plist-get r :state)))))))))

(defun fleet-dash-interrupt ()
  "Operator-only guarded cancellation request."
  (interactive)
  (fleet-dashboard--require-owner)
  (pcase-let* ((target (fleet-dashboard--target)) (`(,_store ,_fleet ,task ,_rev) target))
    (unless task (user-error "Interrupt applies to operators; use fleet-commander-stop for the commander"))
    (let* ((rt (fleet-dashboard--runtime task)) (conn (and rt (fleet-eca-conn (plist-get rt :id)))))
      (unless conn (user-error "No live connection to interrupt"))
      (when (yes-or-no-p (format "Request cancellation of %s's current turn (%s)? " (plist-get task :name)
                                 (or (plist-get rt :turn-state) "turn state unknown")))
        (fleet-dashboard--revalidate target)
        (if (fleet-eca-request-cancel conn)
            (message "Cancellation requested; the operator is not idle until the server says so")
          (message "Nothing to cancel"))))))

(defun fleet-dash-teardown ()
  "Operator-only normal teardown with confirmation and the full evidence gate."
  (interactive)
  (fleet-dashboard--require-owner)
  (pcase-let* ((target (fleet-dashboard--target)) (`(,store ,_fleet ,task ,_rev) target))
    (unless task (user-error "Teardown applies to tasks; fleets are retired with M-x fleet-destroy"))
    (when (yes-or-no-p (format "Tear down task %s (phase %s)? Removes only a clean, Fleet-owned, preserved worktree. " (plist-get task :name) (or (plist-get task :phase) "none")))
      (fleet-dashboard--revalidate target)
      (condition-case err
          (let ((r (fleet-core-teardown-task store (plist-get task :id) :expected-revision (plist-get task :entity-revision)
                                             :callback (lambda (op)
                                                         (message "Teardown %s: %s" (plist-get op :state) (or (plist-get op :error) "archived"))
                                                         (fleet-supervisor--changed)))))
            (message "Teardown operation %s started" (fleet-paths-short-id (plist-get r :operation-id))))
        (fleet-error (user-error "Teardown refused — %s" (fleet-error-string err)))))))

(defun fleet-dashboard--view-file (file editable-hint)
  "Open FILE read-only with view-mode; `e' edits after showing EDITABLE-HINT."
  (unless (file-readable-p file) (user-error "%s does not exist" (file-name-nondirectory file)))
  (let ((buf (find-file-noselect file)))
    (with-current-buffer buf
      (view-mode 1)
      (setq-local view-exit-action (lambda (b) (with-current-buffer b (message "%s" editable-hint))))
      (local-set-key (kbd "e") (lambda () (interactive) (view-mode -1) (message "%s" editable-hint))))
    (pop-to-buffer buf)))

(defun fleet-dash-brief ()
  "View the current brief read-only."
  (interactive)
  (pcase-let ((`(,store ,_fleet ,task ,_rev) (fleet-dashboard--target)))
    (unless task (user-error "A fleet header has no operator brief; talk to the commander instead"))
    (fleet-dashboard--view-file (expand-file-name "brief.md" (fleet-core-task-dir store task))
                                "Editing brief.md does not change the dispatched scope; the commander must retask to publish a new revision")))

(defun fleet-dash-report ()
  "View the task report read-only."
  (interactive)
  (pcase-let ((`(,store ,_fleet ,task ,_rev) (fleet-dashboard--target)))
    (unless task (user-error "A fleet header has no report"))
    (let ((f (expand-file-name "report.md" (fleet-core-task-dir store task))))
      (unless (file-exists-p f) (user-error "No report yet for %s" (plist-get task :name)))
      (fleet-dashboard--view-file f "Editing report.md invalidates its verification hash"))))

(defun fleet-dash-worktree ()
  "Dired into the verified existing task worktree."
  (interactive)
  (pcase-let ((`(,_store ,_fleet ,task ,_rev) (fleet-dashboard--target)))
    (unless task (user-error "Fleet headers have no worktree"))
    (let ((ws (plist-get task :workspace-path)))
      (cond ((not (equal (plist-get task :kind) "change")) (user-error "%s is a %s task; its workspace is %s" (plist-get task :name) (plist-get task :kind) (or ws "not created yet")))
            ((or (null ws) (not (file-directory-p ws))) (user-error "Worktree not present (%s)" (or ws "not created")))
            (t (dired ws))))))

(defun fleet-dash-park ()
  "Park the fleet at point with exactly the M-x semantics.
On a lieutenant or one of its tasks this parks the whole root fleet; the
confirmation names that scope."
  (interactive)
  (pcase-let ((`(,store ,fleet ,_task ,_rev) (fleet-dashboard--target)))
    (fleet-park (plist-get (fleet-core-root-fleet store fleet) :name))))

(provide 'fleet-dashboard)
;;; fleet-dashboard.el ends here
