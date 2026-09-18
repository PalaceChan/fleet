"""Browser check through ui_cdp.mjs (headless Chromium + Node WebSocket).  Skipped without both."""

import copy
import json
import os
import shutil
import subprocess
import threading
import unittest

from helpers import FrevTestCase, SKILL_DIR, example_review, server, store
from test_server import SpyNotifier

CHROMIUM = os.environ.get("FREV_CHROMIUM") or shutil.which("chromium") or shutil.which("chromium-browser") or shutil.which("google-chrome")
NODE = shutil.which("node")


@unittest.skipUnless(CHROMIUM and NODE, "needs chromium and node")
class BrowserTests(FrevTestCase):
    def test_pick_queue_reload_send_sequence(self):
        review = example_review()
        review["items"][1]["body"] = "Draft <script>alert(1)</script> [evil](javascript:alert(2)) <img src=x onerror=alert(3)>"
        s = self.make_session(review=review)
        notifier = SpyNotifier()
        srv = server.ReviewServer("ns1", notifier=notifier)
        t = threading.Thread(target=srv.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        t.start()
        try:
            url = srv.url + store.url_path(s)
            shots = self.tmp / "shots"
            shots.mkdir()
            env = {**os.environ, "FREV_CHROMIUM": CHROMIUM}
            proc = subprocess.run([NODE, str(SKILL_DIR / "test" / "ui_cdp.mjs"), url, str(shots)], capture_output=True, text=True, timeout=120, env=env)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            r = json.loads(proc.stdout.strip().splitlines()[-1])
        finally:
            srv.shutdown()
            srv.server_close()
        self.assertEqual(r.get("failure"), None, r)
        self.assertEqual(r["errorsOnLoad"], 0)
        self.assertEqual(r["errorsTotal"], 0)
        self.assertEqual(r["badgeInitial"], "Your turn")
        self.assertTrue(r["needsYouFirst"])
        self.assertTrue(r["rawHtmlEscaped"])
        self.assertTrue(r["pickQueued"])
        self.assertTrue(r["composerClearedAfterQueue"])
        self.assertEqual(r["badgeDraft"], "Draft · 2 queued, not sent")
        self.assertEqual(r["queueAfterReload"], 3)
        self.assertEqual(r["composerAfterReload"], "half-typed thought")
        self.assertTrue(r["pickStillShownAfterReload"])
        self.assertEqual(r["badgeSent"], "Sent · awaiting commander")
        self.assertEqual(r["queueAfterSend"], 0)
        self.assertEqual(r["composerAfterSend"], "")
        self.assertEqual(r["roundInputs"], 4)  # pick, message, comment, and the composer text sent with Ctrl+Enter
        self.assertIn("the commander is notified", r["notifyLine"])
        self.assertTrue(r["sendDisabledWhilePending"])
        self.assertEqual(len(notifier.calls), 1)
        stored = s.submissions()[0]
        self.assertEqual([i["type"] for i in stored["inputs"]], ["choice", "message", "comment", "message"])
        self.assertEqual(stored["inputs"][3]["text"], "half-typed thought")
        self.assertTrue((shots / "draft.png").exists() and (shots / "sent.png").exists())


if __name__ == "__main__":
    unittest.main()
