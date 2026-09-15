;;; fleet-policy-tests.el --- Tests for fleet-policy -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)
(require 'fleet-policy)
(require 'fleet-test-helpers)

(defconst fleet-policy-test-json
  "{
  \"version\": 1,
  \"default\": {\"model\": \"or/grok\"},
  \"ask_first\": [\"oa/astra\", \"an/fable\"],
  \"fallback\": {\"or/grok\": {\"model\": \"oa/terra\", \"variant\": \"medium\"}},
  \"rules\": [
    {\"when\": \"new feature work on project X\", \"use\": {\"model\": \"an/fable\", \"variant\": \"high\"},
     \"why\": \"standing rule from the user\"},
    {\"when\": \"non-simple technical/architecture design or research\",
     \"use\": [{\"model\": \"oa/astra\", \"variant\": \"medium\"}, {\"model\": \"an/fable\", \"variant\": \"high\"}, \"or/kimi\"]},
    {\"when\": \"simple bug fix with a known root cause, documentation update or chore\", \"use\": \"or/flash\"}
  ]
}")

(defun fleet-policy-test-write (json)
  "Write JSON as a stand-alone `models.json' in the temporary config root; return the path.
The parsing tests below exercise the bare policy format this way; the
`config.json' wrapper is covered by `fleet-policy-config-json-*'."
  (fleet-test-write (fleet-policy-legacy-file) json))

(ert-deftest fleet-policy-missing-file-means-no-policy ()
  (fleet-test-with-roots
    (should-not (file-exists-p (fleet-policy-file)))
    (should (string-prefix-p fleet-config-root (fleet-policy-file)))
    (should (equal (fleet-policy-file) (fleet-config-file)))
    (should-not (fleet-policy-load))
    (should-not (fleet-config-fleets))
    (should-not (fleet-config-lieutenants "any"))
    ;; Every question answered nil without a policy.
    (should-not (fleet-policy-default nil))
    (should-not (fleet-policy-ask-first-p nil "oa/astra"))
    (should-not (fleet-policy-ask-first-p nil nil))
    (should-not (fleet-policy-fallback nil "or/grok"))
    ;; The defcustom points elsewhere when set.
    (let ((fleet-model-policy-file (expand-file-name "elsewhere.json" fleet-test--roots)))
      (should (equal (fleet-policy-file) (expand-file-name "elsewhere.json" fleet-test--roots))))))

(ert-deftest fleet-policy-parses-and-normalizes ()
  (fleet-test-with-roots
    (fleet-policy-test-write fleet-policy-test-json)
    (let ((p (fleet-policy-load)))
      (should (equal (plist-get p :file) (fleet-policy-file)))
      (should (equal (plist-get p :default) '(:model "or/grok" :variant nil)))
      (should (equal (plist-get p :ask-first) '("oa/astra" "an/fable")))
      (should (equal (fleet-policy-fallback p "or/grok") '(:model "oa/terra" :variant "medium")))
      (should-not (fleet-policy-fallback p "oa/terra"))
      (should (fleet-policy-ask-first-p p "an/fable"))
      (should-not (fleet-policy-ask-first-p p "or/kimi"))
      (should-not (fleet-policy-ask-first-p p nil))
      (should (= 3 (length (plist-get p :rules))))
      ;; A single object `use' and a bare string `use' normalize like the chain form.
      (let ((r0 (nth 0 (plist-get p :rules))) (r2 (nth 2 (plist-get p :rules))))
        (should (equal (plist-get r0 :when) "new feature work on project X"))
        (should (equal (plist-get r0 :use) '((:model "an/fable" :variant "high"))))
        (should (equal (plist-get r0 :why) "standing rule from the user"))
        (should (equal (plist-get r2 :use) '((:model "or/flash" :variant nil))))
        (should-not (plist-get r2 :why)))
      (should (equal (mapcar (lambda (s) (plist-get s :model)) (plist-get (nth 1 (plist-get p :rules)) :use)) '("oa/astra" "an/fable" "or/kimi")))
      ;; Every id the policy mentions, once each, wildcard excluded.
      (should (equal (fleet-policy-models p) '("or/grok" "an/fable" "oa/astra" "or/kimi" "or/flash" "oa/terra")))
      ;; The default is only offered when the catalog has it.
      (should (fleet-policy-default p))
      (should (fleet-policy-default p '("or/grok" "x/y")))
      (should-not (fleet-policy-default p '("x/y"))))))

(ert-deftest fleet-policy-ask-first-wildcard-covers-every-model ()
  (fleet-test-with-roots
    (fleet-policy-test-write "{\"default\": \"or/grok\", \"ask_first\": [\"*\"]}")
    (let ((p (fleet-policy-load)))
      (should (fleet-policy-ask-first-p p "or/grok"))
      (should (fleet-policy-ask-first-p p "anything/else"))
      ;; nil is the ECA default: still a model that would run
      (should (fleet-policy-ask-first-p p nil))
      (should (equal (fleet-policy-models p) '("or/grok")))
      (should (string-match-p "Ask first: \\*\\*every task\\*\\*" (fleet-policy-describe p))))))

(ert-deftest fleet-policy-refuses-malformed-files-with-a-reason ()
  (fleet-test-with-roots
    (cl-flet ((invalid (json)
                (fleet-policy-test-write json)
                (let ((err (fleet-test-should-fail 'invalid-model-policy (fleet-policy-load))))
                  (should (equal (plist-get (fleet-error-evidence err) :file) (fleet-policy-file)))
                  (fleet-error-message err))))
      (should (string-match-p "not valid JSON" (invalid "{")))
      (should (string-match-p "top level must be an object" (invalid "[1]")))
      (should (string-match-p "unknown key defaults" (invalid "{\"defaults\": \"x/y\"}")))
      (should (string-match-p "unsupported version" (invalid "{\"version\": 2}")))
      (should (string-match-p "rules\\[0\\] needs a non-empty use" (invalid "{\"rules\": [{\"when\": \"x\"}]}")))
      (should (string-match-p "rules\\[0\\]\\.when must be a non-empty string" (invalid "{\"rules\": [{\"use\": \"a/b\"}]}")))
      (should (string-match-p "rules\\[0\\]\\.when must be a non-empty string" (invalid "{\"rules\": [{\"when\": \"  \", \"use\": \"a/b\"}]}")))
      (should (string-match-p "unknown key difficulty in rules\\[0\\]" (invalid "{\"rules\": [{\"when\": \"x\", \"difficulty\": \"hard\", \"use\": \"a/b\"}]}")))
      (should (string-match-p "use\\[0\\] needs a non-empty model" (invalid "{\"rules\": [{\"when\": \"x\", \"use\": [{\"variant\": \"high\"}]}]}")))
      (should (string-match-p "unknown key modle in default" (invalid "{\"default\": {\"modle\": \"a/b\"}}")))
      (should (string-match-p "fallback must be an object" (invalid "{\"fallback\": [\"a/b\"]}")))
      ;; ({} parses to nil, so an empty object is indistinguishable from an absent key and passes.)
      (should (string-match-p "rules must be an array" (invalid "{\"rules\": \"a/b\"}")))
      (should (string-match-p "ask_first must be a list" (invalid "{\"ask_first\": [1]}"))))))

(ert-deftest fleet-policy-describe-lists-everything-the-commander-needs ()
  (fleet-test-with-roots
    (fleet-policy-test-write fleet-policy-test-json)
    (let ((text (fleet-policy-describe (fleet-policy-load))))
      (should (string-match-p "Policy file: `.*models.json`" text))
      (should (string-match-p "Default (no rule applies; omit `model`): `or/grok`" text))
      (should (string-match-p "1\\. when new feature work on project X → `an/fable` (variant `high`) (why: standing rule from the user)" text))
      (should (string-match-p "2\\. when non-simple technical/architecture design or research → `oa/astra` (variant `medium`), then `an/fable` (variant `high`), then `or/kimi`\n" text))
      (should (string-match-p "3\\. when simple bug fix.* → `or/flash`\n" text))
      (should (string-match-p "cite the rule in `model_reason`" text))
      (should (string-match-p "Ask first (refused without `owner_approved`, however chosen): `oa/astra`, `an/fable`" text))
      (should (string-match-p "fallback.*`or/grok` → `oa/terra` (variant `medium`)" text)))
    (fleet-policy-test-write "{}")
    (let ((text (fleet-policy-describe (fleet-policy-load))))
      (should (string-match-p "No policy default" text))
      (should (string-match-p "No routing rules" text))
      (should (string-match-p "No ask-first models" text)))))

(ert-deftest fleet-policy-config-json-holds-models-and-wins-over-legacy ()
  "`config.json' carries the policy under `models'; when present it is read
instead of `models.json'; a config without `models' is an empty policy."
  (fleet-test-with-roots
    (fleet-policy-test-write "{\"default\": \"legacy/model\"}")
    (should (equal (plist-get (fleet-policy-default (fleet-policy-load)) :model) "legacy/model"))
    (fleet-test-write-config :models "{\"default\": \"new/model\", \"ask_first\": [\"new/model\"]}" :fleets "{}")
    (should (equal (fleet-policy-file) (fleet-config-file)))
    (let ((p (fleet-policy-load)))
      (should (equal (plist-get p :file) (fleet-config-file)))
      (should (equal (plist-get (fleet-policy-default p) :model) "new/model"))
      (should (fleet-policy-ask-first-p p "new/model"))
      (should (string-match-p "Policy file: `.*config.json`" (fleet-policy-describe p))))
    (fleet-test-write-config :fleets "{}")
    (let ((p (fleet-policy-load)))
      (should p)
      (should-not (fleet-policy-default p))
      (should-not (plist-get p :rules)))
    ;; Section errors are reported where they belong: a broken models section
    ;; is an invalid policy; the fleets reader is untouched by it and vice versa.
    (fleet-test-write-config :models "{\"defaults\": 1}" :fleets "{\"w\": {\"lieutenants\": {\"a\": {\"charter\": \"x\"}}}}")
    (should (string-match-p "unknown key defaults in the models section"
                            (fleet-error-message (fleet-test-should-fail 'invalid-model-policy (fleet-policy-load)))))
    (should (equal (mapcar (lambda (l) (plist-get l :name)) (fleet-config-lieutenants "w")) '("a")))
    (fleet-test-write-config :models "{\"default\": \"a/b\"}" :fleets "{\"w\": {\"lieutenant\": {}}}")
    (should (fleet-policy-load))
    (should (string-match-p "unknown key lieutenant in fleets.w"
                            (fleet-error-message (fleet-test-should-fail 'invalid-fleet-config (fleet-config-fleets)))))
    ;; Top-level problems hit both readers.
    (fleet-test-write (fleet-config-file) "{\"model\": {}}")
    (fleet-test-should-fail 'invalid-model-policy (fleet-policy-load))
    (fleet-test-should-fail 'invalid-fleet-config (fleet-config-fleets))))

(ert-deftest fleet-policy-config-json-lieutenants-parse-and-validate ()
  (fleet-test-with-roots
    (fleet-test-write-config
     :fleets "{\"workshop\": {\"lieutenants\": {
                 \"frontend\": {\"charter\": \"UI and browser-facing work.\"},
                 \"backend\": {\"charter\": \"Services and data.\", \"model\": \"a/x\", \"variant\": \"high\"}}},
               \"personal\": {},
               \"quiet\": {\"lieutenants\": {}}}")
    (should (equal (mapcar (lambda (f) (plist-get f :name)) (fleet-config-fleets)) '("workshop" "personal" "quiet")))
    (should (equal (fleet-config-lieutenants "workshop")
                   '((:name "frontend" :charter "UI and browser-facing work." :model nil :variant nil)
                     (:name "backend" :charter "Services and data." :model "a/x" :variant "high"))))
    (should-not (fleet-config-lieutenants "personal"))
    (should-not (fleet-config-lieutenants "quiet"))
    (should-not (fleet-config-lieutenants "unknown"))
    (cl-flet ((invalid (fleets)
                (fleet-test-write-config :fleets fleets)
                (let ((err (fleet-test-should-fail 'invalid-fleet-config (fleet-config-fleets))))
                  (should (equal (plist-get (fleet-error-evidence err) :file) (fleet-config-file)))
                  (fleet-error-message err))))
      (should (string-match-p "fleets.bad name is not a valid fleet name" (invalid "{\"bad name\": {}}")))
      (should (string-match-p "fleets.w must be an object" (invalid "{\"w\": 3}")))
      (should (string-match-p "fleets.w.lieutenants must be an object" (invalid "{\"w\": {\"lieutenants\": [\"a\"]}}")))
      (should (string-match-p "fleets.w.lieutenants.a must be an object with a charter" (invalid "{\"w\": {\"lieutenants\": {\"a\": \"x\"}}}")))
      (should (string-match-p "fleets.w.lieutenants.a.charter must be a non-empty string" (invalid "{\"w\": {\"lieutenants\": {\"a\": {\"model\": \"m\"}}}}")))
      (should (string-match-p "fleets.w.lieutenants.a.charter must be a non-empty string" (invalid "{\"w\": {\"lieutenants\": {\"a\": {\"charter\": \" \"}}}}")))
      (should (string-match-p "fleets.w.lieutenants.a/b is not a valid lieutenant name" (invalid "{\"w\": {\"lieutenants\": {\"a/b\": {\"charter\": \"x\"}}}}")))
      (should (string-match-p "one level only" (invalid "{\"w\": {\"lieutenants\": {\"a\": {\"charter\": \"x\", \"lieutenants\": {}}}}}")))
      (should (string-match-p "unknown key when in fleets.w.lieutenants.a" (invalid "{\"w\": {\"lieutenants\": {\"a\": {\"charter\": \"x\", \"when\": \"y\"}}}}")))
      (should (string-match-p "a.model must be a non-empty string" (invalid "{\"w\": {\"lieutenants\": {\"a\": {\"charter\": \"x\", \"model\": \"\"}}}}"))))))

(provide 'fleet-policy-tests)
;;; fleet-policy-tests.el ends here
