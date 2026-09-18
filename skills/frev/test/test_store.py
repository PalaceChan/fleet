"""Session store: fresh sessions, publish/submit state machine, containment."""

import os
import stat
import unittest

from helpers import ROOT_ID, RUNTIME_ID, BEARINGS, FrevTestCase, example_review, schema, store


class SessionLifecycleTests(FrevTestCase):
    def test_every_start_is_a_fresh_private_directory(self):
        a = self.make_session(publish=False)
        b = self.make_session(publish=False)
        self.assertNotEqual(a.path, b.path)
        self.assertEqual(a.path.parent, self.data_root / "ns1" / ROOT_ID)
        self.assertEqual(stat.S_IMODE(a.path.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(a.meta_path.stat().st_mode), 0o600)
        meta = a.meta()
        self.assertEqual(meta["state"], "authoring")
        self.assertEqual(meta["head"], 0)
        self.assertEqual(meta["commander_runtime_id"], RUNTIME_ID)
        self.assertEqual(meta["root"], {"id": ROOT_ID, "name": "workshop"})
        self.assertTrue((a.path / "snapshot.json").is_file())
        self.assertIn("decision `d1` (open, authority human): Which threshold?", (a.path / "digest.md").read_text())
        self.assertIn("read failed: database is locked", (a.path / "digest.md").read_text())
        self.assertIsNone(a.current_review())

    def test_publish_submit_publish_round_trip(self):
        s = self.make_session()
        self.assertEqual(s.state(), "awaiting-user")
        self.assertEqual(s.head(), 1)
        rev1 = s.revision(1)
        self.assertEqual(rev1["revision"], 1)
        self.assertIsNone(rev1["in_reply_to"])
        sub = s.submit(self.feedback())
        self.assertEqual(sub["seq"], 1)
        self.assertIsNone(sub["notify"])
        self.assertEqual(s.state(), "awaiting-commander")
        self.assertEqual(s.pending_submission()["id"], "sub-1")
        # accounting is not optional
        with self.assertRaises(store.StoreError) as cm:
            s.publish(example_review())
        self.assertEqual(cm.exception.code, "inputs-unaccounted")
        self.assertEqual(cm.exception.evidence["missing"], ["i1", "i2", "i3"])
        rev2 = s.publish(self.with_dispositions(example_review(), sub))
        self.assertEqual(rev2["revision"], 2)
        self.assertEqual(rev2["in_reply_to"], "sub-1")
        self.assertEqual(s.state(), "awaiting-user")
        self.assertIsNone(s.pending_submission())
        # dispositions without a pending round are refused
        with self.assertRaises(store.StoreError) as cm:
            s.publish(self.with_dispositions(example_review(), sub))
        self.assertEqual(cm.exception.code, "no-pending-round")
        events = [line for line in (s.path / "events.jsonl").read_text().splitlines()]
        self.assertEqual(len(events), 4)  # created, published, received, published
        st = s.status()
        self.assertEqual([r["revision"] for r in st["revisions"]], [1, 2])
        self.assertEqual(st["submissions"][0]["inputs"][0]["choice_id"], "navigation-tests")

    def test_submit_refusals(self):
        s = self.make_session(publish=False)
        with self.assertRaises(store.StoreError) as cm:
            s.submit(self.feedback(revision=0))
        self.assertEqual(cm.exception.code, "no-revision")
        s.publish(example_review())
        with self.assertRaises(store.StoreError) as cm:
            s.submit(self.feedback(revision=7))
        self.assertEqual(cm.exception.code, "stale-revision")
        self.assertEqual(cm.exception.evidence["head"], 1)
        with self.assertRaises(schema.ValidationError):
            s.submit(self.feedback(inputs=[{"id": "x", "type": "choice", "choice_id": "ghost", "option_id": "a"}]))
        s.submit(self.feedback())
        with self.assertRaises(store.StoreError) as cm:
            s.submit(self.feedback("sub-2"))
        self.assertEqual(cm.exception.code, "round-pending")
        with self.assertRaises(store.StoreError) as cm:
            s.submit({"id": "end-1", "revision": 1, "kind": "end", "inputs": [{"id": "z", "type": "message", "text": "bye"}]})
        self.assertEqual(cm.exception.code, "round-pending")
        closure = s.submit({"id": "end-1", "revision": 1, "kind": "end", "inputs": []})
        self.assertEqual(closure["kind"], "end")
        self.assertEqual(s.state(), "ended")
        self.assertEqual(s.pending_submission()["id"], "sub-1")  # the feedback round is still owed; the empty end is not

    def test_submit_replay_is_idempotent_and_conflict_is_refused(self):
        s = self.make_session()
        first = s.submit(self.feedback())
        again = s.submit(self.feedback())
        self.assertTrue(again["replayed"])
        self.assertEqual(again["seq"], first["seq"])
        self.assertEqual(len(s.submissions()), 1)
        changed = self.feedback()
        changed["inputs"][0]["option_id"] = "broader"
        with self.assertRaises(store.StoreError) as cm:
            s.submit(changed)
        self.assertEqual(cm.exception.code, "submission-conflict")

    def test_end_with_inputs_then_final_revision(self):
        s = self.make_session()
        sub = s.submit({"id": "end-1", "revision": 1, "kind": "end", "inputs": [{"id": "m", "type": "message", "text": "Thanks, stopping here."}]})
        self.assertEqual(s.state(), "ended")
        self.assertEqual(s.pending_submission()["id"], "end-1")
        with self.assertRaises(store.StoreError) as cm:
            s.publish(self.with_dispositions(example_review(), sub, "noted"))
        self.assertEqual(cm.exception.code, "session-ended")
        final = s.publish(self.with_dispositions(example_review(), sub, "noted"), final=True)
        self.assertTrue(final["final"])
        self.assertEqual(s.state(), "ended")
        self.assertIsNone(s.pending_submission())
        with self.assertRaises(store.StoreError) as cm:
            s.submit(self.feedback("late", revision=2))
        self.assertEqual(cm.exception.code, "session-ended")

    def test_commander_end_and_record_notify(self):
        s = self.make_session()
        s.submit(self.feedback())
        stored = s.record_notify("sub-1", {"result": "refused", "code": "human-draft", "reason": "typing"})
        self.assertEqual(stored["notify"]["code"], "human-draft")
        stored = s.record_notify("sub-1", {"result": "queued", "message-id": "m-1"})
        self.assertEqual(stored["notify"]["result"], "queued")
        self.assertEqual(len(stored["notify_history"]), 2)
        meta = s.end(by="commander")
        self.assertEqual(meta["state"], "ended")
        self.assertEqual(meta["ended_by"], "commander")
        self.assertEqual(s.end()["state"], "ended")  # idempotent


class ContainmentTests(FrevTestCase):
    def test_open_and_resolve_stay_under_the_data_root(self):
        s = self.make_session(publish=False)
        self.assertEqual(store.Session.open(str(s.path)).path, s.path)
        self.assertEqual(store.Session.resolve("ns1", ROOT_ID, s.id).path, s.path)
        outside = self.tmp / "outside"
        outside.mkdir()
        (outside / "session.json").write_text("{}")
        with self.assertRaises(store.StoreError) as cm:
            store.Session.open(str(outside))
        self.assertEqual(cm.exception.code, "session-outside-data-root")
        link = self.data_root / "ns1" / ROOT_ID / "link"
        os.symlink(outside, link)
        with self.assertRaises(store.StoreError) as cm:
            store.Session.resolve("ns1", ROOT_ID, "link")
        self.assertEqual(cm.exception.code, "session-outside-data-root")
        for bad in ("..", "../x", "a/b", "", "x" * 81, ".hidden"):
            with self.assertRaises(store.StoreError) as cm:
                store.Session.resolve("ns1", ROOT_ID, bad)
            self.assertEqual(cm.exception.code, "bad-path-segment")
        with self.assertRaises(store.StoreError) as cm:
            store.Session.resolve("ns1", ROOT_ID, "20990101T000000-000000")
        self.assertEqual(cm.exception.code, "session-missing")
        with self.assertRaises(store.StoreError):
            s.submission_path("../evil")

    def test_digest_is_facts_only(self):
        text = store.render_digest(BEARINGS)
        self.assertIn("# Evidence — fleet `workshop`", text)
        self.assertIn("task `navigation` (change, id t1): lifecycle active, phase needs-decision, dashboard decision", text)
        self.assertIn("## Coverage", text)
        self.assertEqual(store.render_digest(None), "_no evidence_\n")


if __name__ == "__main__":
    unittest.main()
