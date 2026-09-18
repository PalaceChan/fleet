"""Loopback server: routes, headers, refusals, notify hop, server records and ownership."""

import http.client
import json
import os
import subprocess
import sys
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

from helpers import APP_DIR, ROOT_ID, SKILL_DIR, FrevTestCase, bridge, example_review, server, store


class SpyNotifier:
    def __init__(self, result=None):
        self.calls = []
        self.result = result or {"result": "queued", "message-id": "m-1", "state": "queued", "target": "rt-current"}

    def __call__(self, session_dir, submission_id, *, socket_name=None, skill_dir=None):
        self.calls.append({"session_dir": str(session_dir), "submission_id": submission_id, "socket_name": socket_name, "skill_dir": skill_dir})
        return dict(self.result)


class ServerTestCase(FrevTestCase):
    def setUp(self):
        super().setUp()
        self.notifier = SpyNotifier()
        self.srv = server.ReviewServer("ns1", notifier=self.notifier)
        self.thread = threading.Thread(target=self.srv.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        self.thread.start()
        self.port = self.srv.port

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()
        super().tearDown()

    def request(self, method, path, body=None, headers=None, host=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        h = {"Host": host or f"127.0.0.1:{self.port}"}
        if body is not None:
            data = body if isinstance(body, (bytes, str)) else json.dumps(body)
            h.setdefault("Content-Type", "application/json")
            h["Content-Length"] = str(len(data.encode() if isinstance(data, str) else data))
        else:
            data = None
        h.update(headers or {})
        conn.request(method, path, body=data, headers=h)
        resp = conn.getresponse()
        raw = resp.read()
        conn.close()
        ctype = resp.getheader("Content-Type") or ""
        parsed = json.loads(raw) if ctype.startswith("application/json") else raw
        return resp.status, dict(resp.getheaders()), parsed

    def api(self, session):
        m = session.meta()
        return f"/api/s/{m['namespace']}/{ROOT_ID}/{m['id']}"


class RouteTests(ServerTestCase):
    def test_ping_ui_and_static_with_security_headers(self):
        s = self.make_session()
        status, headers, body = self.request("GET", "/api/ping")
        self.assertEqual((status, body["app"], body["instance"]), (200, "frev", self.srv.instance))
        status, headers, body = self.request("GET", store.url_path(s))
        self.assertEqual(status, 200)
        self.assertIn(b"<title>frev", body)
        self.assertIn("script-src 'self'", headers["Content-Security-Policy"])
        self.assertIn("img-src 'self'", headers["Content-Security-Policy"])
        self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
        self.assertEqual(headers["Referrer-Policy"], "no-referrer")
        for name, ctype in (("app.js", "text/javascript"), ("md.js", "text/javascript"), ("app.css", "text/css")):
            status, headers, _ = self.request("GET", f"/static/{name}")
            self.assertEqual(status, 200)
            self.assertTrue(headers["Content-Type"].startswith(ctype))
        for bad in ("/static/../frev.py", "/static/frev_app/cli.py", "/static/x.py", "/static/", "/static/.env"):
            self.assertEqual(self.request("GET", bad)[0], 404, bad)

    def test_session_reads_and_containment(self):
        s = self.make_session()
        status, _, body = self.request("GET", self.api(s) + "/session")
        self.assertEqual(status, 200)
        self.assertEqual(body["session"]["state"], "awaiting-user")
        self.assertNotIn("snapshot", body)
        status, _, body = self.request("GET", self.api(s) + "/revision/1")
        self.assertEqual((status, body["title"]), (200, example_review()["title"]))
        self.assertEqual(self.request("GET", self.api(s) + "/revision/2")[0], 404)
        status, _, body = self.request("GET", self.api(s) + "/state")
        self.assertEqual((status, body["head"], body["state"]), (200, 1, "awaiting-user"))
        # other namespace, other root, nonexistent or malformed session ids: 404 and no path use
        self.assertEqual(self.request("GET", f"/api/s/other/{ROOT_ID}/{s.id}/state")[0], 404)
        self.assertEqual(self.request("GET", f"/api/s/ns1/{ROOT_ID}/nope/state")[0], 404)
        self.assertEqual(self.request("GET", f"/api/s/ns1/{ROOT_ID}/../{s.id}/state")[0], 404)
        self.assertEqual(self.request("GET", f"/api/s/ns1/%2e%2e/{s.id}/state")[0], 404)
        self.assertEqual(self.request("GET", f"/s/ns1/{ROOT_ID}/nope/")[0], 404)
        self.assertEqual(self.request("GET", "/api/nothing")[0], 404)

    def test_host_origin_content_type_and_size_refusals(self):
        s = self.make_session()
        self.assertEqual(self.request("GET", "/api/ping", host="evil.example")[0], 421)
        self.assertEqual(self.request("GET", "/api/ping", host=f"localhost:{self.port}")[0], 200)
        status, _, body = self.request("POST", self.api(s) + "/submit", self.feedback(), headers={"Origin": "http://evil.example"})
        self.assertEqual((status, body["code"]), (403, "bad-origin"))
        status, _, body = self.request("POST", self.api(s) + "/submit", self.feedback(), headers={"Origin": f"http://127.0.0.1:{self.port}"})
        self.assertEqual(status, 200)
        status, _, body = self.request("POST", self.api(s) + "/notify/sub-1", "x=1", headers={"Content-Type": "text/plain"})
        self.assertEqual(status, 200)  # notify retry ignores the body; a fresh session below checks content-type on submit
        s2 = self.make_session()
        status, _, body = self.request("POST", self.api(s2) + "/submit", "x=1", headers={"Content-Type": "application/x-www-form-urlencoded"})
        self.assertEqual((status, body["code"]), (415, "bad-content-type"))
        status, _, body = self.request("POST", self.api(s2) + "/submit", "{" + "x" * server.BODY_LIMIT)
        self.assertEqual((status, body["code"]), (413, "body-too-large"))
        status, _, body = self.request("POST", self.api(s2) + "/submit", "{not json")
        self.assertEqual((status, body["code"]), (400, "bad-json"))
        self.assertEqual(self.request("POST", "/api/ping")[0], 404)
        self.assertEqual(self.request("POST", self.api(s2) + "/state")[0], 404)


class SubmitTests(ServerTestCase):
    def test_submit_persists_then_notifies_the_fixed_target(self):
        s = self.make_session()
        status, _, body = self.request("POST", self.api(s) + "/submit", self.feedback())
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        self.assertFalse(body["replayed"])
        self.assertEqual(body["submission"]["notify"]["result"], "queued")
        self.assertEqual(body["state"], "awaiting-commander")
        self.assertEqual(len(self.notifier.calls), 1)
        call = self.notifier.calls[0]
        self.assertEqual(call["session_dir"], str(s.path))
        self.assertEqual(call["submission_id"], "sub-1")
        self.assertEqual(call["skill_dir"], str(SKILL_DIR))
        stored = s.submission("sub-1")
        self.assertEqual(stored["notify"]["message-id"], "m-1")
        self.assertEqual(stored["inputs"][1]["text"], "Shorter opening.")
        # exact replay: same receipt, no second notice
        status, _, body = self.request("POST", self.api(s) + "/submit", self.feedback())
        self.assertEqual((status, body["replayed"]), (200, True))
        self.assertEqual(len(self.notifier.calls), 1)
        # a second round while the first is pending
        status, _, body = self.request("POST", self.api(s) + "/submit", self.feedback("sub-2"))
        self.assertEqual((status, body["code"]), (409, "round-pending"))

    def test_invalid_and_stale_rounds_keep_nothing(self):
        s = self.make_session()
        bad = self.feedback(inputs=[{"id": "x", "type": "choice", "choice_id": "navigation-tests", "option_id": "nope"}])
        status, _, body = self.request("POST", self.api(s) + "/submit", bad)
        self.assertEqual((status, body["code"]), (400, "invalid-submission"))
        self.assertTrue(any("'nope' is not an option" in e for e in body["errors"]))
        status, _, body = self.request("POST", self.api(s) + "/submit", self.feedback(revision=3))
        self.assertEqual((status, body["code"], body["head"]), (409, "stale-revision", 1))
        self.assertEqual(s.submissions(), [])
        self.assertEqual(self.notifier.calls, [])

    def test_refused_notify_is_shown_and_retryable(self):
        s = self.make_session()
        self.notifier.result = {"result": "refused", "code": "human-draft", "reason": "Someone is typing", "target": "rt-current"}
        status, _, body = self.request("POST", self.api(s) + "/submit", self.feedback())
        self.assertEqual(status, 200)
        self.assertEqual(body["submission"]["notify"]["code"], "human-draft")
        self.assertEqual(s.state(), "awaiting-commander")  # the round is safe even when the notice is held
        self.notifier.result = {"result": "queued", "message-id": "m-2", "state": "queued", "target": "rt-current"}
        status, _, body = self.request("POST", self.api(s) + "/notify/sub-1", {})
        self.assertEqual((status, body["submission"]["notify"]["result"]), (200, "queued"))
        self.assertEqual(len(self.notifier.calls), 2)
        # once queued, a retry is a no-op
        self.request("POST", self.api(s) + "/notify/sub-1", {})
        self.assertEqual(len(self.notifier.calls), 2)
        self.assertEqual(self.request("POST", self.api(s) + "/notify/ghost", {})[0], 404)

    def test_end_from_browser(self):
        s = self.make_session()
        status, _, body = self.request("POST", self.api(s) + "/submit", {"id": "e1", "revision": 1, "kind": "end", "inputs": []})
        self.assertEqual((status, body["state"]), (200, "ended"))
        self.assertEqual(self.notifier.calls[0]["submission_id"], "e1")
        status, _, body = self.request("POST", self.api(s) + "/submit", self.feedback("late"))
        self.assertEqual((status, body["code"]), (409, "session-ended"))


class BridgeHopTests(ServerTestCase):
    """The real bridge.notify path with the spy emacsclient (argv, load form, result file)."""

    def setUp(self):
        super().setUp()
        self.srv.notifier = bridge.notify

    def test_notify_argv_names_frev_el_session_and_submission(self):
        s = self.make_session()
        status, _, body = self.request("POST", self.api(s) + "/submit", self.feedback())
        self.assertEqual(status, 200)
        self.assertEqual(body["submission"]["notify"]["result"], "queued")
        calls = self.spy_calls()
        self.assertEqual(len(calls), 1)
        argv = calls[0]
        self.assertEqual(argv[0], "--alternate-editor=false")
        self.assertEqual(argv[1], "--eval")
        form = argv[2]
        self.assertIn(f'(load "{SKILL_DIR / "scripts" / "frev.el"}" nil t)', form)
        self.assertIn(f'(frev-notify-to-file "', form)
        self.assertIn(f'" "{s.path}" "sub-1")', form)
        self.assertNotIn("Shorter opening", form)  # user text never travels through argv
        self.assertNotIn("--socket-name", argv)

    def test_bridge_failures_become_held_results(self):
        s = self.make_session()
        os.environ["FREV_SPY_MODE"] = "exit-error"
        status, _, body = self.request("POST", self.api(s) + "/submit", self.feedback())
        self.assertEqual(status, 200)
        n = body["submission"]["notify"]
        self.assertEqual((n["result"], n["code"]), ("failed", "emacsclient-failed"))
        self.assertIn("server not responding", n["reason"])
        os.environ["FREV_SPY_MODE"] = "bridge-error"
        status, _, body = self.request("POST", self.api(s) + "/notify/sub-1", {})
        n = body["submission"]["notify"]
        self.assertEqual((n["result"], n["code"]), ("failed", "session-outside-data-root"))
        os.environ["FREV_SPY_MODE"] = "refuse"
        status, _, body = self.request("POST", self.api(s) + "/notify/sub-1", {})
        n = body["submission"]["notify"]
        self.assertEqual((n["result"], n["code"]), ("refused", "human-draft"))
        os.environ["FREV_EMACSCLIENT"] = str(self.tmp / "missing-emacsclient")
        status, _, body = self.request("POST", self.api(s) + "/notify/sub-1", {})
        self.assertEqual(body["submission"]["notify"]["code"], "emacsclient-missing")


class _ForeignHandler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        body = b'{"app":"something-else"}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


class ServerRecordTests(FrevTestCase):
    def test_absent_stale_foreign_running(self):
        self.assertEqual(server.server_status("ns1")["state"], "absent")
        self.assertEqual(server.stop_server("ns1"), {"stopped": False, "state": "absent"})
        with self.assertRaises(store.StoreError) as cm:
            server.ensure_server("ns1", spawn=False)
        self.assertEqual(cm.exception.code, "server-not-running")
        # stale: a record whose port nobody answers
        path = server.record_path("ns1")
        path.parent.mkdir(parents=True)
        probe = HTTPServer(("127.0.0.1", 0), _ForeignHandler)
        dead_port = probe.server_address[1]
        probe.server_close()
        store.write_json_atomic(path, {"app": "frev", "namespace": "ns1", "instance": "old", "pid": 999999, "port": dead_port})
        self.assertEqual(server.server_status("ns1")["state"], "stale")
        self.assertTrue(server.stop_server("ns1")["cleared_stale_record"])
        self.assertFalse(path.exists())
        # foreign: something else answers on the recorded port -> never stopped, never reused
        foreign = HTTPServer(("127.0.0.1", 0), _ForeignHandler)
        t = threading.Thread(target=foreign.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        t.start()
        try:
            store.write_json_atomic(path, {"app": "frev", "namespace": "ns1", "instance": "x", "pid": os.getpid(), "port": foreign.server_address[1]})
            st = server.server_status("ns1")
            self.assertEqual(st["state"], "foreign")
            with self.assertRaises(store.StoreError) as cm:
                server.stop_server("ns1")
            self.assertEqual(cm.exception.code, "foreign-server")
            with self.assertRaises(store.StoreError) as cm:
                server.ensure_server("ns1", spawn=False)
            self.assertEqual(cm.exception.code, "server-not-running")
            with self.assertRaises(store.StoreError) as cm:
                server.serve_forever("ns1")
            self.assertEqual(cm.exception.code, "foreign-server")
            self.assertTrue(path.exists())
        finally:
            foreign.shutdown()
            foreign.server_close()
        # running: our own instance, verified by ping
        ours = server.ReviewServer("ns1", notifier=SpyNotifier())
        t = threading.Thread(target=ours.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        t.start()
        try:
            store.write_json_atomic(path, ours.record())
            st = server.server_status("ns1")
            self.assertEqual((st["state"], st["ping"]["instance"]), ("running", ours.instance))
            self.assertEqual(server.ensure_server("ns1", spawn=False)["port"], ours.port)
            with self.assertRaises(store.StoreError) as cm:
                server.serve_forever("ns1")
            self.assertEqual(cm.exception.code, "server-already-running")
        finally:
            ours.shutdown()
            ours.server_close()

    def test_spawned_server_is_verified_and_stopped_only_when_ours(self):
        rec = server.ensure_server("ns1", wait=15)
        try:
            self.assertEqual(rec["namespace"], "ns1")
            self.assertEqual(server.server_status("ns1")["state"], "running")
            self.assertEqual(server.ensure_server("ns1")["instance"], rec["instance"])  # reused, not respawned
            self.assertTrue((self.runtime_root / "ns1" / "server.log").exists())
        finally:
            result = server.stop_server("ns1")
        self.assertTrue(result["stopped"])
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and server.ping(rec["port"]) is not None:
            time.sleep(0.1)
        self.assertIsNone(server.ping(rec["port"]))
        self.assertEqual(server.server_status("ns1")["state"], "absent")


class CliTests(FrevTestCase):
    def run_cli(self, *args):
        proc = subprocess.run([sys.executable, "-B", str(APP_DIR / "frev.py"), *args], capture_output=True, text=True, timeout=60)
        return proc.returncode, proc.stdout, proc.stderr

    def test_start_publish_status_end_loop(self):
        code, out, err = self.run_cli("start", "--fleet-id", ROOT_ID, "--runtime-id", "rt-current")
        self.assertEqual(code, 0, err)
        self.assertIn("# Evidence — fleet `workshop`", out)
        result = json.loads(out.split("---\n", 1)[1])
        self.assertTrue(result["ok"])
        session_dir = result["session"]
        collect_call = self.spy_calls()[0]
        self.assertIn(f':session-fleet-id "{ROOT_ID}" :runtime-id "rt-current"', collect_call[2])
        review = self.tmp / "review.json"
        review.write_text(json.dumps(example_review()))
        code, out, _ = self.run_cli("validate", str(review))
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)["needs_you"], ["navigation", "release-note"])
        try:
            code, out, err = self.run_cli("publish", "--session", session_dir, "--review", str(review), "--no-browser")
            self.assertEqual(code, 0, err)
            pub = json.loads(out)
            self.assertEqual((pub["revision"], pub["state"]), (1, "awaiting-user"))
            self.assertIn("/s/ns1/" + ROOT_ID + "/", pub["url"])
            s = store.Session.open(session_dir)
            s.submit(self.feedback())
            code, out, _ = self.run_cli("status", "--session", session_dir)
            self.assertEqual(code, 0)
            self.assertIn("PENDING (needs a revision with dispositions)", out)
            self.assertIn("option `focused`: Settings tests only", out)
            self.assertIn("comment on item `release-note`:\n    Shorter opening.", out)
            code, out, _ = self.run_cli("publish", "--session", session_dir, "--review", str(review), "--no-browser")
            self.assertEqual(code, 2)
            self.assertEqual(json.loads(out)["code"], "inputs-unaccounted")
            review.write_text(json.dumps(self.with_dispositions(example_review(), self.feedback())))
            code, out, _ = self.run_cli("publish", "--session", session_dir, "--review", str(review), "--no-browser")
            self.assertEqual(json.loads(out)["revision"], 2)
            code, out, _ = self.run_cli("end", "--session", session_dir)
            self.assertEqual(json.loads(out)["state"], "ended")
            self.assertEqual(self.spy_calls()[-1][1], "--eval")  # no browse-url call happened with FREV_NO_BROWSER
        finally:
            server.stop_server("ns1")

    def test_start_refuses_without_identity_or_current_commander(self):
        code, out, _ = self.run_cli("start")
        self.assertEqual((code, json.loads(out)["code"]), (2, "no-fleet-identity"))
        # the reader reports whether the caller runtime is the root's current commander; a stale one cannot host a review
        with open(os.environ["FREV_SPY_COLLECT"], encoding="utf-8") as fh:
            collect = json.load(fh)
        collect["bearings"]["caller"] = {"runtime-id": "rt-stale", "current-commander-p": False}
        with open(os.environ["FREV_SPY_COLLECT"], "w", encoding="utf-8") as fh:
            json.dump(collect, fh)
        code, out, _ = self.run_cli("start", "--fleet-id", ROOT_ID, "--runtime-id", "rt-stale")
        self.assertEqual(code, 2)
        self.assertEqual(json.loads(out)["code"], "not-current-commander")
        self.assertFalse(self.data_root.exists() and any((self.data_root / "ns1").rglob("session.json")))
        os.environ["FREV_SPY_MODE"] = "exit-error"
        code, out, _ = self.run_cli("start", "--fleet-id", ROOT_ID, "--runtime-id", "rt-current")
        self.assertEqual(json.loads(out)["code"], "emacsclient-failed")


if __name__ == "__main__":
    unittest.main()
