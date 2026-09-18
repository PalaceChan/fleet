#!/usr/bin/env python3
"""Tests for bridge/fleet_bridge.py: MCP framing, forwarding, lease semantics."""
import fcntl
import json
import os
import select
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRIDGE = os.path.join(ROOT, "bridge", "fleet_bridge.py")
PY = sys.executable


class FakeFleetSocket:
    """NDJSON server standing in for fleet-rpc.el."""

    def __init__(self, path, tools=None, fail=None):
        self.path = path
        self.tools = tools or [{"name": "fleet_snapshot", "description": "d", "inputSchema": {"type": "object"}, "roles": ["operator"]}]
        self.requests = []
        self.fail = fail
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.srv.bind(path)
        self.srv.listen(8)
        self.thread = threading.Thread(target=self.loop, daemon=True)
        self.thread.start()

    def loop(self):
        while True:
            try:
                conn, _ = self.srv.accept()
            except OSError:
                return
            threading.Thread(target=self.handle, args=(conn,), daemon=True).start()

    def handle(self, conn):
        buf = b""
        while b"\n" not in buf:
            chunk = conn.recv(65536)
            if not chunk:
                conn.close()
                return
            buf += chunk
        req = json.loads(buf.split(b"\n", 1)[0])
        self.requests.append(req)
        if self.fail == "disconnect":
            conn.close()
            return
        if req.get("credential") != "secret-token":
            resp = {"id": req["id"], "error": {"code": "unauthenticated", "message": "unknown credential", "evidence": None, "retryable": False}}
        elif req["operation"] == "tools_list":
            resp = {"id": req["id"], "result": {"tools": self.tools}}
        elif req["operation"] == "fleet_snapshot":
            resp = {"id": req["id"], "result": {"revision": 7, "echo": req["params"], "key": req.get("idempotencyKey")}}
        else:
            resp = {"id": req["id"], "error": {"code": "forbidden", "message": "nope", "evidence": {"x": 1}, "retryable": False}}
        conn.sendall((json.dumps(resp, ensure_ascii=False) + "\n").encode("utf-8"))
        conn.close()

    def close(self):
        self.srv.close()


class McpClient:
    def __init__(self, env):
        self.proc = subprocess.Popen([PY, BRIDGE, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        self.n = 0

    def raw(self, data):
        self.proc.stdin.write(data)
        self.proc.stdin.flush()

    def send(self, method, params=None, notify=False):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        if not notify:
            self.n += 1
            msg["id"] = self.n
        self.raw((json.dumps(msg, ensure_ascii=False) + "\n").encode("utf-8"))
        return None if notify else self.n

    def read(self):
        line = self.proc.stdout.readline()
        return json.loads(line)

    def read_within(self, timeout):
        """Read one reply, or return None if none arrives within `timeout` seconds (never hangs)."""
        ready, _, _ = select.select([self.proc.stdout], [], [], timeout)
        return self.read() if ready else None

    def close(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=5)


class BridgeMcpTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="fleet-bridge-test-")
        self.sock = os.path.join(self.tmp, "control.sock")
        self.cred = os.path.join(self.tmp, "cred.json")
        with open(self.cred, "w") as f:
            json.dump({"runtimeId": "rt-1", "token": "secret-token"}, f)
        self.env = dict(os.environ, FLEET_SOCKET=self.sock, FLEET_CREDENTIAL_FILE=self.cred)
        self.server = None

    def tearDown(self):
        if self.server:
            self.server.close()

    def test_initialize_negotiates_known_version_and_ping(self):
        c = McpClient(self.env)
        c.send("initialize", {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}})
        r = c.read()
        self.assertEqual(r["result"]["protocolVersion"], "2024-11-05")
        self.assertIn("tools", r["result"]["capabilities"])
        c.send("notifications/initialized", {}, notify=True)
        c.send("initialize", {"protocolVersion": "1999-01-01"})
        self.assertEqual(c.read()["result"]["protocolVersion"], "2025-06-18")
        c.send("ping")
        self.assertEqual(c.read()["result"], {})
        c.send("bogus/method")
        self.assertEqual(c.read()["error"]["code"], -32601)
        c.close()

    def test_no_credential_advertises_no_tools(self):
        env = dict(os.environ, FLEET_SOCKET=self.sock)
        env.pop("FLEET_CREDENTIAL_FILE", None)
        c = McpClient(env)
        c.send("initialize", {"protocolVersion": "2025-06-18"})
        self.assertIn("No Fleet credential", c.read()["result"]["instructions"])
        c.send("tools/list")
        self.assertEqual(c.read()["result"]["tools"], [])
        c.send("tools/call", {"name": "fleet_snapshot", "arguments": {}})
        r = c.read()
        self.assertTrue(r["result"]["isError"])
        c.close()

    def test_tools_forwarded_with_credential_and_idempotency_key(self):
        self.server = FakeFleetSocket(self.sock)
        c = McpClient(self.env)
        c.send("initialize", {"protocolVersion": "2025-06-18"})
        c.read()
        c.send("tools/list")
        tools = c.read()["result"]["tools"]
        self.assertEqual([t["name"] for t in tools], ["fleet_snapshot"])
        self.assertNotIn("roles", tools[0])  # role visibility is server-side; not leaked to the model
        args = {"idempotency_key": "k-1", "text": "multi\nline — ünicode —dash-leading"}
        c.send("tools/call", {"name": "fleet_snapshot", "arguments": args})
        r = c.read()
        self.assertFalse(r["result"]["isError"])
        payload = json.loads(r["result"]["content"][0]["text"])
        self.assertEqual(payload["echo"], args)
        self.assertEqual(payload["key"], "k-1")
        req = self.server.requests[-1]
        self.assertEqual(req["credential"], "secret-token")
        self.assertEqual(req["idempotencyKey"], "k-1")
        self.assertEqual(req["protocolVersion"], 1)
        # unknown tool -> JSON-RPC error, nothing forwarded
        n = len(self.server.requests)
        c.send("tools/call", {"name": "fleet_unknown", "arguments": {}})
        self.assertEqual(c.read()["error"]["code"], -32602)
        self.assertEqual(len(self.server.requests), n)
        c.close()

    def test_fleet_errors_become_isError_results(self):
        self.server = FakeFleetSocket(self.sock, tools=[{"name": "fleet_task_create", "description": "d", "inputSchema": {"type": "object"}}])
        c = McpClient(self.env)
        c.send("initialize", {"protocolVersion": "2025-06-18"})
        c.read()
        c.send("tools/list")
        c.read()
        c.send("tools/call", {"name": "fleet_task_create", "arguments": {"idempotency_key": "x"}})
        r = c.read()
        self.assertTrue(r["result"]["isError"])
        err = json.loads(r["result"]["content"][0]["text"])["error"]
        self.assertEqual(err["code"], "forbidden")
        self.assertEqual(err["evidence"], {"x": 1})
        c.close()

    def test_split_frames_malformed_and_oversize(self):
        c = McpClient(self.env)
        msg = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "ping"}) + "\n"
        c.raw(msg[:5].encode())
        time.sleep(0.1)
        c.raw(msg[5:].encode())
        self.assertEqual(c.read()["result"], {})
        c.raw(b"{not json\n")
        self.assertEqual(c.read()["error"]["code"], -32700)
        c.raw(b"x" * (1024 * 1024 + 10) + b"\n")
        self.assertEqual(c.read()["error"]["code"], -32700)
        c.send("ping")
        self.assertEqual(c.read()["result"], {})
        c.close()

    def test_oversized_unterminated_input_is_rejected_before_newline(self):
        c = McpClient(self.env)
        limit = 1024 * 1024
        # A request just under the bound, delivered in several chunks with no
        # newline yet, must not be rejected: the bound is on the line, not the chunk.
        c.raw(b"{" + b" " * (limit - 8))
        time.sleep(0.1)
        self.assertIsNone(c.read_within(0.3))
        # Crossing the bound while still unterminated triggers the error at once.
        c.raw(b" " * 64)
        r = c.read_within(3)
        self.assertIsNotNone(r, "no rejection before newline: bound is not enforced incrementally")
        self.assertEqual(r["error"]["code"], -32700)
        self.assertEqual(r["error"]["message"], "message too large")
        self.assertIsNone(r["id"])
        # Further bytes of the same rejected line are swallowed silently: no second error.
        c.raw(b"y" * (2 * limit))
        self.assertIsNone(c.read_within(0.5))
        # The rejected line ends at the next newline; framing resumes right after it.
        c.raw(b"tail\n")
        c.send("ping")
        self.assertEqual(c.read_within(3)["result"], {})
        c.close()

    def test_oversized_unterminated_input_then_eof_terminates_cleanly(self):
        c = McpClient(self.env)
        c.raw(b"x" * (1024 * 1024 + 1))
        r = c.read_within(3)
        self.assertIsNotNone(r)
        self.assertEqual(r["error"]["code"], -32700)
        c.proc.stdin.close()
        # EOF inside the rejected line: exactly one error was emitted, exit is orderly.
        out, _ = c.proc.communicate(timeout=5)
        self.assertEqual(out, b"")
        self.assertEqual(c.proc.returncode, 0)

    def test_large_valid_request_split_across_chunks_is_not_truncated(self):
        c = McpClient(self.env)
        pad = "p" * (900 * 1024)
        msg = (json.dumps({"jsonrpc": "2.0", "id": 7, "method": "ping", "params": {"pad": pad}}) + "\n").encode()
        for i in range(0, len(msg), 200 * 1024):
            c.raw(msg[i:i + 200 * 1024])
            time.sleep(0.05)
        r = c.read_within(3)
        self.assertEqual(r, {"jsonrpc": "2.0", "id": 7, "result": {}})
        c.send("ping")
        self.assertEqual(c.read_within(3)["result"], {})
        c.close()

    def test_disconnected_fleet_reports_retryable_error(self):
        self.server = FakeFleetSocket(self.sock, fail="disconnect")
        c = McpClient(self.env)
        c.send("initialize", {"protocolVersion": "2025-06-18"})
        c.read()
        c.send("tools/list")
        self.assertEqual(c.read()["result"]["tools"], [])  # tools_list failed -> no tools, no crash
        c.send("ping")
        self.assertEqual(c.read()["result"], {})
        c.close()

    def test_socket_unreachable_is_unavailable(self):
        c = McpClient(self.env)
        c.send("initialize", {"protocolVersion": "2025-06-18"})
        c.read()
        c.send("tools/list")
        self.assertEqual(c.read()["result"]["tools"], [])
        c.close()

    def test_rpc_cli_mode(self):
        self.server = FakeFleetSocket(self.sock)
        out = subprocess.run([PY, BRIDGE, "rpc", "fleet_snapshot", json.dumps({"idempotency_key": "cli"})], env=self.env, capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(json.loads(out.stdout)["revision"], 7)
        out = subprocess.run([PY, BRIDGE, "rpc", "fleet_other"], env=self.env, capture_output=True, text=True)
        self.assertEqual(out.returncode, 1)
        self.assertEqual(json.loads(out.stdout)["error"]["code"], "forbidden")


class LeaseTests(unittest.TestCase):
    def test_lease_exclusive_and_released_on_eof(self):
        tmp = tempfile.mkdtemp(prefix="fleet-lease-test-")
        lock = os.path.join(tmp, "owner.lock")
        p1 = subprocess.Popen([PY, BRIDGE, "lease", lock], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.assertEqual(p1.stdout.readline().strip(), "acquired")
        p2 = subprocess.run([PY, BRIDGE, "lease", lock], input="", capture_output=True, text=True, timeout=10)
        self.assertEqual(p2.stdout.strip(), "busy")
        self.assertEqual(p2.returncode, 1)
        # the lock file itself is never renamed/unlinked
        self.assertTrue(os.path.exists(lock))
        p1.stdin.close()
        self.assertEqual(p1.wait(timeout=10), 0)
        fd = os.open(lock, os.O_RDWR)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)  # now free
        os.close(fd)


if __name__ == "__main__":
    unittest.main()
