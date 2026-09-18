"""Review and submission validation."""

import unittest

from helpers import example_review, schema


class ReviewSchemaTests(unittest.TestCase):
    def test_example_is_valid_and_needs_you_rule(self):
        r = example_review()
        self.assertEqual(schema.validate_review(r), [])
        needs = [i["id"] for i in r["items"] if schema.needs_you(i)]
        self.assertEqual(needs, ["navigation", "release-note"])  # choices; done-with-attention
        self.assertFalse(schema.needs_you({"phase": "waiting", "attention": "   "}))
        self.assertTrue(schema.needs_you({"phase": "decision"}))

    def test_strict_parse_rejects_duplicate_keys(self):
        with self.assertRaises(ValueError):
            schema.parse_strict('{"a": 1, "a": 2}')
        self.assertEqual(schema.parse_strict('{"a": [1, {"b": 2}]}'), {"a": [1, {"b": 2}]})

    def test_structural_errors_are_all_reported(self):
        r = example_review()
        r["version"] = 2
        r["extra"] = True
        r["items"][0]["phase"] = "working"          # native enum, not a review phase
        r["items"][0]["choices"][0]["options"] = [{"id": "only", "label": "One"}]
        r["items"][0]["choices"][0]["recommendation"] = "nope"
        r["items"][1]["id"] = "navigation-tests"    # collides with the choice id (shared namespace)
        r["items"][2]["depends_on"] = ["ghost"]
        r["items"][2]["surprise"] = 1
        errors = schema.validate_review(r)
        joined = "\n".join(errors)
        for needle in ("version must be 1", "unknown keys ['extra']", "phase: must be one of", "at least two options",
                       "recommendation: must name", "duplicate id 'navigation-tests'", "unknown item 'ghost'", "unknown keys ['surprise']"):
            self.assertIn(needle, joined)

    def test_dispositions_validate(self):
        r = example_review()
        r["dispositions"] = [{"input_id": "i1", "status": "planned", "note": "later"},
                             {"input_id": "i1", "status": "applied", "note": ""},
                             {"input_id": "bad id!", "status": "noted", "note": "x"}]
        joined = "\n".join(schema.validate_review(r))
        self.assertIn("status: must be one of", joined)
        self.assertIn("duplicate 'i1'", joined)
        self.assertIn("note: must be a non-empty string", joined)
        self.assertIn("input_id: missing or not a safe id", joined)
        r["dispositions"] = [{"input_id": "i1", "status": "needs-clarification", "note": "Which repo?"}]
        self.assertEqual(schema.validate_review(r), [])

    def test_non_object_and_limits(self):
        self.assertEqual(schema.validate_review([]), ["review must be a JSON object"])
        r = example_review()
        r["items"][0]["body"] = "x" * (schema.TEXT_LIMIT + 1)
        self.assertTrue(any("body" in e for e in schema.validate_review(r)))


class SubmissionSchemaTests(unittest.TestCase):
    def setUp(self):
        self.review = example_review()

    def test_valid_feedback_and_end(self):
        sub = {"id": "s1", "revision": 1, "kind": "feedback", "inputs": [
            {"id": "a", "type": "choice", "choice_id": "navigation-tests", "option_id": "broader"},
            {"id": "b", "type": "comment", "anchor_id": "navigation", "text": "ok"},
            {"id": "c", "type": "message", "text": "hi"}]}
        self.assertEqual(schema.validate_submission(sub, self.review), [])
        self.assertEqual(schema.validate_submission({"id": "s2", "revision": 1, "kind": "end", "inputs": []}, self.review), [])

    def test_anchors_options_and_picks_checked_against_the_revision(self):
        sub = {"id": "s1", "revision": 1, "inputs": [
            {"id": "a", "type": "choice", "choice_id": "navigation-tests", "option_id": "nope"},
            {"id": "b", "type": "choice", "choice_id": "navigation-tests", "option_id": "focused"},
            {"id": "c", "type": "choice", "choice_id": "ghost", "option_id": "x"},
            {"id": "d", "type": "comment", "anchor_id": "ghost", "text": "?"},
            {"id": "e", "type": "message", "text": "   "},
            {"id": "e", "type": "message", "text": "dup id", "anchor_id": "navigation"},
            {"id": "f", "type": "shout", "text": "x"}]}
        joined = "\n".join(schema.validate_submission(sub, self.review))
        for needle in ("'nope' is not an option", "more than one pick for choice 'navigation-tests'", "'ghost' is not a choice",
                       "'ghost' is not an item", "text: must be a non-empty string", "duplicate input id 'e'", "a message has no anchor",
                       "type: must be one of"):
            self.assertIn(needle, joined)

    def test_feedback_needs_inputs_kind_and_revision_types(self):
        joined = "\n".join(schema.validate_submission({"id": "s", "revision": "1", "kind": "poke", "inputs": []}, self.review))
        self.assertIn("revision: must be an integer", joined)
        self.assertIn("kind: must be one of", joined)
        joined = "\n".join(schema.validate_submission({"id": "s", "revision": 1, "inputs": []}, self.review))
        self.assertIn("at least one input", joined)

    def test_missing_dispositions(self):
        sub = {"id": "s1", "revision": 1, "inputs": [{"id": "a", "type": "message", "text": "x"}, {"id": "b", "type": "message", "text": "y"}]}
        self.review["dispositions"] = [{"input_id": "a", "status": "noted", "note": "ok"}]
        self.assertEqual(schema.missing_dispositions(self.review, sub), ["b"])


if __name__ == "__main__":
    unittest.main()
