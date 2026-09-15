;;; fleet-policy.el --- Owner model-selection policy -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: MIT

;;; Commentary:

;; The owner's operator model policy, read from a JSON file under the Fleet
;; config root (`fleet-policy-file').  It lets the owner write down, once and
;; in their own words, how operators should be routed to models, instead of
;; naming a model to the commander for every task.
;;
;; The split of responsibilities is deliberate:
;;
;;   - Routing is judgement, so the *commander* does it: it reads the rules
;;     (`fleet-policy-describe' puts them in its boot message), decides which
;;     `when' clause the task falls under, passes the exact model and a
;;     `model_reason' naming the rule, and Fleet records both.
;;   - Everything mechanical stays in *Fleet*: the default when no rule
;;     applies, catalog validation, the ask-first gate
;;     (`fleet-policy-ask-first-p'), and the provider-failure fallback
;;     (`fleet-policy-fallback').
;;
;; This module is pure: no store, no ECA.  `fleet-core' applies the default
;; and the approval gate at task creation; `fleet-supervisor' applies the
;; fallback to a barren turn.  Owner model choices belong in owner
;; configuration, never in product defaults, so a missing file means "no
;; policy" and every function then answers nil.
;;
;; The owner file is `config.json' under the Fleet config root
;; (`fleet-config-file').  Its `models' object is the policy; its `fleets'
;; object declares lieutenants per root fleet (docs/lieutenants.md §3).  The
;; two sections are validated independently, so a typo in one does not
;; disable the other.  The earlier `models.json' (the bare policy object) is
;; still read when `config.json' is absent.
;;
;;   {
;;     "version": 1,
;;     "models": {
;;       "default": {"model": "provider/model", "variant": "medium"},
;;       "ask_first": ["provider/expensive", ...],       // or ["*"] for everything
;;       "fallback": {"provider/model": {"model": "provider/other", "variant": "medium"}},
;;       "rules": [
;;         {"when": "non-simple architecture design or research",
;;          "use": [{"model": "a/x", "variant": "medium"}, "b/y"],
;;          "why": "standing preference"}
;;       ]
;;     },
;;     "fleets": {
;;       "workshop": {
;;         "lieutenants": {
;;           "frontend": {"charter": "UI and browser-facing work."},
;;           "backend":  {"charter": "Services and data.", "model": "a/x", "variant": "high"}
;;         }
;;       }
;;     }
;;   }
;;
;; A selection is an object with `model' and optional `variant', or a bare
;; model id string.  `use' is a single selection or an ordered preference
;; chain: best first, the rest are what the commander offers when the owner
;; declines or the catalog lacks the first.  `when' is free text for the
;; commander's judgement; `why' is optional context shown alongside it.  A
;; lieutenant's `charter' is likewise free text the root commander routes by;
;; its optional `model'/`variant' pin the lieutenant's own runtime.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'fleet-paths)

(defcustom fleet-config-file nil
  "Path of the owner's Fleet configuration JSON (models policy and lieutenants).
Nil means `config.json' under the Fleet config root (see
`fleet-paths-config-root')."
  :type '(choice (const nil) file) :group 'fleet)

(defcustom fleet-model-policy-file nil
  "Path of a stand-alone operator model policy JSON (the pre-`config.json' format).
Nil means `models.json' under the Fleet config root, consulted only when
`fleet-config-file' does not exist.  Set this to keep a bare policy file
elsewhere; it then wins over `config.json'."
  :type '(choice (const nil) file) :group 'fleet)

(defconst fleet-policy-ask-first-wildcard "*"
  "An `ask_first' entry meaning every model, the default included.")

(defconst fleet-config--top-keys '(:version :models :fleets))
(defconst fleet-config--fleet-keys '(:lieutenants))
(defconst fleet-config--lieutenant-keys '(:charter :model :variant))
(defconst fleet-policy--top-keys '(:version :default :ask_first :fallback :rules))
(defconst fleet-policy--rule-keys '(:when :use :why))
(defconst fleet-policy--selection-keys '(:model :variant))

(defun fleet-config-file ()
  "Absolute path of the owner configuration file, whether or not it exists."
  (expand-file-name (or fleet-config-file (expand-file-name "config.json" (fleet-paths-config-root)))))

(defun fleet-policy-legacy-file ()
  "Absolute path of the stand-alone policy file (`models.json')."
  (expand-file-name (or fleet-model-policy-file (expand-file-name "models.json" (fleet-paths-config-root)))))

(defun fleet-policy-file ()
  "Absolute path of the file the model policy is read from.
An explicitly configured `fleet-model-policy-file' wins; otherwise
`config.json' when it exists, else a present `models.json', else the
(absent) `config.json'.  Callers show this path in messages."
  (cond (fleet-model-policy-file (fleet-policy-legacy-file))
        ((file-exists-p (fleet-config-file)) (fleet-config-file))
        ((file-exists-p (fleet-policy-legacy-file)) (fleet-policy-legacy-file))
        (t (fleet-config-file))))

(defun fleet-policy-legacy-file-p (file)
  "Non-nil when FILE is a bare policy file rather than a `config.json'."
  (equal (expand-file-name file) (fleet-policy-legacy-file)))

;;;; Parsing

(defvar fleet-policy--error-code 'invalid-model-policy
  "Error code the parsers signal; bound per section.")

(defun fleet-policy--fail (file reason &rest evidence)
  "Signal `fleet-policy--error-code' for FILE with REASON and EVIDENCE."
  (apply #'fleet-fail fleet-policy--error-code
         (format "%s is invalid: %s" (if (eq fleet-policy--error-code 'invalid-fleet-config) "Fleet configuration" "Model policy") reason)
         :file file evidence))

(defun fleet-policy--list (v)
  "Normalize JSON V (scalar, object, vector or nil) into a list."
  (cond ((null v) nil)
        ((vectorp v) (append v nil))
        (t (list v))))

(defun fleet-policy--check-keys (file what plist allowed)
  "Refuse keys of PLIST not in ALLOWED; WHAT names the object for FILE."
  (cl-loop for (k _v) on plist by #'cddr
           unless (memq k allowed)
           do (fleet-policy--fail file (format "unknown key %s in %s" (substring (symbol-name k) 1) what)
                                  :key (substring (symbol-name k) 1) :allowed (mapcar (lambda (a) (substring (symbol-name a) 1)) allowed))))

(defun fleet-policy--selection (file what v)
  "Normalize selection V (object or bare model string) to (:model M :variant V)."
  (cond
   ((and (stringp v) (not (string-blank-p v))) (list :model v :variant nil))
   ((and (consp v) (keywordp (car v)))
    (fleet-policy--check-keys file what v fleet-policy--selection-keys)
    (let ((m (plist-get v :model)) (var (plist-get v :variant)))
      (unless (and (stringp m) (not (string-blank-p m)))
        (fleet-policy--fail file (format "%s needs a non-empty model string" what)))
      (when (and var (not (stringp var)))
        (fleet-policy--fail file (format "%s variant must be a string" what)))
      (list :model m :variant var)))
   (t (fleet-policy--fail file (format "%s must be a model id or an object with model/variant" what)))))

(defun fleet-policy--text (file what v &optional optional)
  "V as a non-blank string for WHAT in FILE; nil allowed when OPTIONAL."
  (cond ((and (null v) optional) nil)
        ((and (stringp v) (not (string-blank-p v))) v)
        (t (fleet-policy--fail file (format "%s must be a non-empty string" what)))))

(defun fleet-policy--rule (file i r)
  "Normalize rule R at index I."
  (let ((what (format "rules[%d]" i)))
    (unless (and (consp r) (keywordp (car r))) (fleet-policy--fail file (format "%s must be an object" what)))
    (fleet-policy--check-keys file what r fleet-policy--rule-keys)
    (let ((use (fleet-policy--list (plist-get r :use))))
      (unless use (fleet-policy--fail file (format "%s needs a non-empty use" what)))
      (list :index i
            :when (fleet-policy--text file (concat what ".when") (plist-get r :when))
            :use (cl-loop for s in use for j from 0
                          collect (fleet-policy--selection file (format "%s.use[%d]" what j) s))
            :why (fleet-policy--text file (concat what ".why") (plist-get r :why) t)))))

(defun fleet-policy--json (text file)
  "Parse JSON TEXT of FILE into a plist; nil for an empty object."
  (let ((raw (condition-case err
                 (json-parse-string text :object-type 'plist :array-type 'array :null-object nil :false-object :false)
               (error (fleet-policy--fail file (format "not valid JSON (%s)" (error-message-string err)))))))
    ;; An empty object parses to nil in plist mode; that is a valid, empty document.
    (unless (or (null raw) (and (consp raw) (keywordp (car raw)))) (fleet-policy--fail file "top level must be an object"))
    raw))

(defun fleet-config-parse (text file)
  "Parse `config.json' TEXT of FILE into (:models RAW-POLICY :fleets RAW-FLEETS).
Only the top level is checked here; each section is validated by its own
reader so that one broken section does not disable the other."
  (let ((raw (fleet-policy--json text file)))
    (fleet-policy--check-keys file "the top level" raw fleet-config--top-keys)
    (when (and (plist-get raw :version) (not (eql (plist-get raw :version) 1)))
      (fleet-policy--fail file "unsupported version" :version (plist-get raw :version)))
    (dolist (k '(:models :fleets))
      (let ((v (plist-get raw k)))
        (unless (or (null v) (and (consp v) (keywordp (car v))))
          (fleet-policy--fail file (format "%s must be an object" (substring (symbol-name k) 1))))))
    (list :models (plist-get raw :models) :fleets (plist-get raw :fleets))))

(defun fleet-policy-parse (text file)
  "Parse policy JSON TEXT (from FILE, for messages) into a normalized plist.
TEXT is a bare policy object (`models.json') or a `config.json' whose
`models' section is the policy, by FILE.  Signals `invalid-model-policy'
on any structural problem."
  (let* ((legacy (fleet-policy-legacy-file-p file))
         (raw (if legacy
                  (fleet-policy--json text file)
                (plist-get (fleet-config-parse text file) :models))))
    (fleet-policy--check-keys file (if legacy "the top level" "the models section") raw fleet-policy--top-keys)
    (when (and (plist-get raw :version) (not (eql (plist-get raw :version) 1)))
      (fleet-policy--fail file "unsupported version" :version (plist-get raw :version)))
    (let ((fallback (plist-get raw :fallback)) (rules (plist-get raw :rules)) (ask (plist-get raw :ask_first)))
      (when (and fallback (not (and (consp fallback) (keywordp (car fallback)))))
        (fleet-policy--fail file "fallback must be an object mapping model ids to selections"))
      (when (and rules (not (vectorp rules))) (fleet-policy--fail file "rules must be an array"))
      (dolist (a (fleet-policy--list ask))
        (unless (stringp a) (fleet-policy--fail file "ask_first must be a list of model ids (or \"*\")")))
      (list :file file
            :default (and (plist-get raw :default) (fleet-policy--selection file "default" (plist-get raw :default)))
            :ask-first (fleet-policy--list ask)
            :fallback (cl-loop for (k v) on fallback by #'cddr
                               collect (cons (substring (symbol-name k) 1)
                                             (fleet-policy--selection file (format "fallback[%s]" (substring (symbol-name k) 1)) v)))
            :rules (cl-loop for r across (or rules []) for i from 0 collect (fleet-policy--rule file i r))))))

(defun fleet-policy-load ()
  "The owner's model policy as a normalized plist, or nil when there is no file.
The file is read on every call: it is small, and a stale cache would make
an owner's edit take effect at some unknown later time.  A malformed file
signals `invalid-model-policy' rather than silently running on defaults.
A `config.json' without a `models' section is an empty policy (not nil):
the owner has a configuration file, just no model rules."
  (let* ((fleet-policy--error-code 'invalid-model-policy)
         (file (fleet-policy-file))
         (text (fleet-paths-read-file file)))
    (when text (fleet-policy-parse text file))))

;;;; Lieutenants (docs/lieutenants.md §3)

(defun fleet-config--lieutenant (file what name v)
  "Normalize lieutenant entry V named NAME at WHAT in FILE."
  (unless (fleet-paths-valid-name-p name)
    (fleet-policy--fail file (format "%s is not a valid lieutenant name (%s)" what fleet-paths-name-regexp) :name name))
  (unless (and (consp v) (keywordp (car v)))
    (fleet-policy--fail file (format "%s must be an object with a charter" what)))
  (when (plist-member v :lieutenants)
    (fleet-policy--fail file (format "%s: lieutenants cannot have lieutenants (one level only)" what)))
  (fleet-policy--check-keys file what v fleet-config--lieutenant-keys)
  (let ((model (plist-get v :model)) (variant (plist-get v :variant)))
    (when (and model (not (and (stringp model) (not (string-blank-p model)))))
      (fleet-policy--fail file (format "%s.model must be a non-empty string" what)))
    (when (and variant (not (stringp variant)))
      (fleet-policy--fail file (format "%s.variant must be a string" what)))
    (list :name name :charter (fleet-policy--text file (concat what ".charter") (plist-get v :charter))
          :model model :variant variant)))

(defun fleet-config--fleet (file name v)
  "Normalize fleet entry V named NAME: (:name NAME :lieutenants (...))."
  (let ((what (format "fleets.%s" name)))
    (unless (fleet-paths-valid-name-p name)
      (fleet-policy--fail file (format "%s is not a valid fleet name (%s)" what fleet-paths-name-regexp) :name name))
    (unless (or (null v) (and (consp v) (keywordp (car v))))
      (fleet-policy--fail file (format "%s must be an object" what)))
    (fleet-policy--check-keys file what v fleet-config--fleet-keys)
    (let ((lts (plist-get v :lieutenants)))
      (unless (or (null lts) (and (consp lts) (keywordp (car lts))))
        (fleet-policy--fail file (format "%s.lieutenants must be an object mapping names to entries" what)))
      (list :name name
            :lieutenants (cl-loop for (k lv) on lts by #'cddr
                                  for lname = (substring (symbol-name k) 1)
                                  collect (fleet-config--lieutenant file (format "%s.lieutenants.%s" what lname) lname lv))))))

(defun fleet-config-fleets ()
  "Configured fleets as a list of (:name :lieutenants), or nil without a `config.json'.
Only the `fleets' section is validated; signals `invalid-fleet-config'."
  (let* ((fleet-policy--error-code 'invalid-fleet-config)
         (file (fleet-config-file))
         (text (fleet-paths-read-file file)))
    (when text
      (let ((raw (plist-get (fleet-config-parse text file) :fleets)))
        (cl-loop for (k v) on raw by #'cddr
                 collect (fleet-config--fleet file (substring (symbol-name k) 1) v))))))

(defun fleet-config-lieutenants (fleet-name)
  "Configured lieutenants of root FLEET-NAME: a list of (:name :charter :model :variant)."
  (plist-get (cl-find fleet-name (fleet-config-fleets) :key (lambda (f) (plist-get f :name)) :test #'equal) :lieutenants))

;;;; Mechanical answers

(defun fleet-policy--available-p (selection catalog)
  "Non-nil when SELECTION's model is in CATALOG, or CATALOG is unknown."
  (or (null catalog) (member (plist-get selection :model) catalog)))

(defun fleet-policy-default (policy &optional catalog)
  "POLICY's default selection when CATALOG (if known) offers it, else nil."
  (let ((d (and policy (plist-get policy :default))))
    (and d (fleet-policy--available-p d catalog) d)))

(defun fleet-policy-ask-first-p (policy model)
  "Non-nil when POLICY wants the owner asked before MODEL runs.
True for a listed model and for every model while the wildcard
`fleet-policy-ask-first-wildcard' is listed; MODEL nil (the ECA default)
counts as a model under the wildcard."
  (and policy
       (let ((ask (plist-get policy :ask-first)))
         (and (or (member fleet-policy-ask-first-wildcard ask)
                  (and model (member model ask)))
              t))))

(defun fleet-policy-fallback (policy model)
  "Selection (:model :variant) POLICY names as the fallback for MODEL, or nil."
  (and policy model (cdr (assoc model (plist-get policy :fallback)))))

(defun fleet-policy-models (policy)
  "Every model id POLICY refers to, deduplicated.
Covers the default, rule selections, listed ask-first entries (not the
wildcard) and both sides of each fallback."
  (let ((ids nil))
    (cl-flet ((add (m) (when (and m (not (equal m fleet-policy-ask-first-wildcard)) (not (member m ids))) (push m ids))))
      (add (plist-get (plist-get policy :default) :model))
      (dolist (r (plist-get policy :rules)) (dolist (s (plist-get r :use)) (add (plist-get s :model))))
      (dolist (m (plist-get policy :ask-first)) (add m))
      (dolist (f (plist-get policy :fallback)) (add (car f)) (add (plist-get (cdr f) :model))))
    (nreverse ids)))

;;;; Presentation

(defun fleet-policy--selection-string (s)
  "Render selection S as `model` or `model` (variant `v`)."
  (if (plist-get s :variant)
      (format "`%s` (variant `%s`)" (plist-get s :model) (plist-get s :variant))
    (format "`%s`" (plist-get s :model))))

(defun fleet-policy-describe (policy)
  "Markdown lines describing POLICY for the commander's boot message."
  (concat
   (format "- Policy file: `%s`.\n" (plist-get policy :file))
   (if (plist-get policy :default)
       (format "- Default (no rule applies; omit `model`): %s.\n" (fleet-policy--selection-string (plist-get policy :default)))
     "- No policy default: with no applicable rule, omit `model` for the operator default above.\n")
   (if (plist-get policy :rules)
       (concat "- Rules, in the owner's words. Judge which `when` the task falls under, pass that `model`/`variant` and cite the rule in `model_reason`; `use` is best first, the rest are alternatives to offer if the first is declined or not in the catalog:\n"
               (mapconcat (lambda (r)
                            (format "  %d. when %s → %s%s\n"
                                    (1+ (plist-get r :index)) (plist-get r :when)
                                    (mapconcat #'fleet-policy--selection-string (plist-get r :use) ", then ")
                                    (if (plist-get r :why) (format " (why: %s)" (plist-get r :why)) "")))
                          (plist-get policy :rules) ""))
     "- No routing rules: every task gets the default unless the user names a model.\n")
   (cond
    ((member fleet-policy-ask-first-wildcard (plist-get policy :ask-first))
     "- Ask first: **every task** (`ask_first` contains `*`). Fleet refuses each creation until you have proposed the model with its reason and the user agreed; then pass `owner_approved`. The owner is shaping the rules this way.\n")
    ((plist-get policy :ask-first)
     (format "- Ask first (refused without `owner_approved`, however chosen): %s.\n"
             (mapconcat (lambda (m) (format "`%s`" m)) (plist-get policy :ask-first) ", ")))
    (t "- No ask-first models.\n"))
   (when (plist-get policy :fallback)
     (format "- Provider-failure fallback (Fleet applies it by itself to a turn that did nothing): %s.\n"
             (mapconcat (lambda (f) (format "`%s` → %s" (car f) (fleet-policy--selection-string (cdr f))))
                        (plist-get policy :fallback) "; ")))))

(provide 'fleet-policy)
;;; fleet-policy.el ends here
