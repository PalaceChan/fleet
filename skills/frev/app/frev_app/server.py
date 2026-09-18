"""Loopback review server: static UI plus session read/submit/status endpoints.

One server per frev namespace (Fleet data root), bound to ``127.0.0.1`` on an
OS-assigned port, recorded in ``<runtime root>/<namespace>/server.json`` with a
random instance id.  Reuse and stop verify that record against ``/api/ping``:
a port answered by anything else is *foreign* and left alone.

Endpoints (no execute/eval/Fleet-mutation route exists):

    GET  /api/ping
    GET  /s/<ns>/<root>/<sid>/                       the UI
    GET  /static/<file>
    GET  /api/s/<ns>/<root>/<sid>/session            status view (session, revisions, submissions)
    GET  /api/s/<ns>/<root>/<sid>/revision/<n>
    GET  /api/s/<ns>/<root>/<sid>/state              small poll target
    POST /api/s/<ns>/<root>/<sid>/submit             persist a round, then notify the commander
    POST /api/s/<ns>/<root>/<sid>/notify/<sub-id>    retry a held/failed notify

The submit path persists first, then calls the Emacs bridge; the notify result
is stored on the submission and returned in the receipt.
"""

from __future__ import annotations

import http.client
import json
import os
import re
import secrets
import signal
import subprocess
import sys
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from . import bridge, store
from .schema import ValidationError

STATIC_DIR = Path(__file__).resolve().parent.parent / "static"
STATIC_TYPES = {".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8",
                ".js": "text/javascript; charset=utf-8", ".svg": "image/svg+xml", ".ico": "image/x-icon"}
BODY_LIMIT = 512 * 1024
CSP = ("default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; "
       "font-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
SESSION_ROUTE = re.compile(r"^/api/s/([^/]+)/([^/]+)/([^/]+)/(session|state|revision/(\d{1,6})|submit|notify/([^/]+))$")
UI_ROUTE = re.compile(r"^/s/([^/]+)/([^/]+)/([^/]+)/$")


class ReviewHandler(BaseHTTPRequestHandler):
    server_version = "frev/1"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    # ------------------------------------------------------------ plumbing

    def log_message(self, fmt, *args):  # quiet by default; the server keeps its own log
        if self.server.verbose:
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _headers(self, status: int, ctype: str, length: int, cache: str = "no-store") -> None:
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(length))
        self.send_header("Content-Security-Policy", CSP)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cache-Control", cache)
        self.end_headers()

    def _json(self, status: int, value) -> None:
        body = json.dumps(value, ensure_ascii=False).encode("utf-8")
        self._headers(status, "application/json; charset=utf-8", len(body))
        self.wfile.write(body)

    def _error(self, status: int, code: str, message: str, **extra) -> None:
        self._json(status, {"ok": False, "code": code, "message": message, **extra})

    def _host_ok(self) -> bool:
        host = (self.headers.get("Host") or "").strip().lower()
        port = self.server.server_address[1]
        return host in {f"127.0.0.1:{port}", f"localhost:{port}", f"[::1]:{port}"}

    def _origin_ok(self) -> bool:
        origin = self.headers.get("Origin")
        if origin is None:
            return True
        port = self.server.server_address[1]
        return origin.strip().lower() in {f"http://127.0.0.1:{port}", f"http://localhost:{port}"}

    def _read_json_body(self):
        ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        if ctype != "application/json":
            raise store.StoreError("bad-content-type", "Content-Type must be application/json", 415)
        try:
            length = int(self.headers.get("Content-Length") or "0")
        except ValueError:
            raise store.StoreError("bad-length", "Content-Length required", 411)
        if length <= 0 or length > BODY_LIMIT:
            raise store.StoreError("body-too-large", f"body must be 1..{BODY_LIMIT} bytes", 413)
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as e:
            raise store.StoreError("bad-json", f"body is not valid JSON: {e}", 400)

    def _session(self, ns: str, root_id: str, sid: str) -> store.Session:
        if ns != self.server.namespace:
            raise store.StoreError("wrong-namespace", "this server serves another Fleet data root", 404)
        return store.Session.resolve(ns, root_id, sid)

    # ------------------------------------------------------------ GET

    def do_GET(self):  # noqa: N802
        try:
            if not self._host_ok():
                return self._error(421, "bad-host", "unexpected Host header")
            path = self.path.split("?", 1)[0]
            if path == "/api/ping":
                return self._json(200, {"app": "frev", "instance": self.server.instance, "namespace": self.server.namespace, "pid": os.getpid()})
            if path == "/":
                body = f"frev review server · namespace {self.server.namespace}\n".encode()
                self._headers(200, "text/plain; charset=utf-8", len(body))
                return self.wfile.write(body)
            if path.startswith("/static/"):
                return self._static(path[len("/static/"):])
            m = UI_ROUTE.match(path)
            if m:
                self._session(*m.groups())  # 404 before serving the shell for a nonexistent session
                return self._static("index.html")
            m = SESSION_ROUTE.match(path)
            if m and (m.group(4) in ("session", "state") or m.group(4).startswith("revision/")):
                session = self._session(m.group(1), m.group(2), m.group(3))
                what = m.group(4)
                if what == "session":
                    return self._json(200, session.status())
                if what == "state":
                    st = session.status()
                    return self._json(200, {"state": st["session"]["state"], "head": st["session"]["head"],
                                            "pending_submission_id": st["pending_submission_id"],
                                            "submissions": [{"id": s["id"], "seq": s["seq"], "kind": s["kind"], "notify": s["notify"]} for s in st["submissions"]]})
                return self._json(200, session.revision(int(m.group(5))))
            return self._error(404, "not-found", "no such route")
        except store.StoreError as e:
            return self._json(e.status, e.to_dict())
        except Exception as e:  # keep the server up; the detail goes to the log
            self.server.log(f"GET {self.path}: {type(e).__name__}: {e}")
            return self._error(500, "internal", "internal error")

    def _static(self, name: str) -> None:
        if not re.match(r"^[A-Za-z0-9_-]+\.[a-z]+$", name):
            return self._error(404, "not-found", "no such file")
        path = STATIC_DIR / name
        ctype = STATIC_TYPES.get(path.suffix)
        if not ctype or not path.is_file():
            return self._error(404, "not-found", "no such file")
        body = path.read_bytes()
        self._headers(200, ctype, len(body), "no-cache")
        self.wfile.write(body)

    # ------------------------------------------------------------ POST

    def do_POST(self):  # noqa: N802
        try:
            if not self._host_ok():
                return self._error(421, "bad-host", "unexpected Host header")
            if not self._origin_ok():
                return self._error(403, "bad-origin", "cross-origin writes are refused")
            path = self.path.split("?", 1)[0]
            m = SESSION_ROUTE.match(path)
            if not m or not (m.group(4) == "submit" or m.group(4).startswith("notify/")):
                return self._error(404, "not-found", "no such route")
            session = self._session(m.group(1), m.group(2), m.group(3))
            if m.group(4) == "submit":
                body = self._read_json_body()
                try:
                    stored = session.submit(body)
                except ValidationError as e:
                    return self._error(400, "invalid-submission", "the round did not validate", errors=e.errors)
                if not stored.get("replayed") or stored.get("notify") is None:
                    stored = self._notify(session, stored)
                return self._json(200, {"ok": True, "replayed": bool(stored.get("replayed")), "submission": _public(stored),
                                        "state": session.state(), "head": session.head()})
            submission_id = m.group(6)
            stored = session.submission(submission_id)
            if (stored.get("notify") or {}).get("result") in ("queued", "replayed"):
                return self._json(200, {"ok": True, "submission": _public(stored), "state": session.state(), "head": session.head()})
            stored = self._notify(session, stored)
            return self._json(200, {"ok": True, "submission": _public(stored), "state": session.state(), "head": session.head()})
        except store.StoreError as e:
            return self._json(e.status, e.to_dict())
        except Exception as e:
            self.server.log(f"POST {self.path}: {type(e).__name__}: {e}")
            return self._error(500, "internal", "internal error")

    def _notify(self, session: store.Session, stored: dict) -> dict:
        meta = session.meta()
        result = self.server.notifier(session.path, stored["id"], socket_name=meta.get("socket_name"),
                                      skill_dir=meta.get("skill_dir"))
        return session.record_notify(stored["id"], result)


def _public(stored: dict) -> dict:
    return {k: stored.get(k) for k in ("id", "seq", "kind", "revision", "received_at", "notify")}


class ReviewServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False

    def __init__(self, namespace: str, port: int = 0, *, notifier=None, verbose: bool = False, log_path: Path | None = None):
        super().__init__(("127.0.0.1", port), ReviewHandler)
        self.namespace = namespace
        self.instance = secrets.token_hex(8)
        self.notifier = notifier or bridge.notify
        self.verbose = verbose
        self.log_path = log_path
        self._log_lock = threading.Lock()

    @property
    def port(self) -> int:
        return self.server_address[1]

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def log(self, line: str) -> None:
        with self._log_lock:
            if self.log_path:
                with open(self.log_path, "a", encoding="utf-8") as fh:
                    fh.write(f"{store.now()} {line}\n")
            elif self.verbose:
                sys.stderr.write(line + "\n")

    def record(self) -> dict:
        return {"app": "frev", "namespace": self.namespace, "instance": self.instance, "pid": os.getpid(),
                "port": self.port, "url": self.url, "started_at": store.now(), "data_root": str(store.data_root())}


# ---------------------------------------------------------------- records, reuse, stop


def record_path(namespace: str) -> Path:
    store.check_segment(namespace, "namespace")
    return store.runtime_root() / namespace / "server.json"


def read_record(namespace: str):
    path = record_path(namespace)
    try:
        return store.read_json(path)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None


def ping(port: int, timeout: float = 2.0):
    """The ``/api/ping`` answer of whatever listens on 127.0.0.1:PORT, or None."""
    try:
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
        conn.request("GET", "/api/ping", headers={"Host": f"127.0.0.1:{port}"})
        resp = conn.getresponse()
        body = resp.read()
        conn.close()
        if resp.status != 200:
            return {"_foreign": True, "status": resp.status}
        data = json.loads(body.decode("utf-8"))
        if not isinstance(data, dict):
            return {"_foreign": True}
        return data
    except (OSError, ValueError, http.client.HTTPException):
        return None


def _pid_alive(pid) -> bool:
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, TypeError, ValueError):
        return False


def server_status(namespace: str) -> dict:
    """``running`` (ours, verified), ``absent``, ``stale`` (record but nothing answers) or ``foreign``."""
    rec = read_record(namespace)
    if not rec:
        return {"state": "absent", "record": None}
    answer = ping(rec.get("port", 0)) if isinstance(rec.get("port"), int) else None
    if answer is None:
        return {"state": "stale", "record": rec, "pid_alive": _pid_alive(rec.get("pid"))}
    if answer.get("app") == "frev" and answer.get("instance") == rec.get("instance") and answer.get("namespace") == namespace:
        return {"state": "running", "record": rec, "ping": answer}
    return {"state": "foreign", "record": rec, "ping": answer}


def ensure_server(namespace: str, *, spawn: bool = True, wait: float = 8.0) -> dict:
    """The verified running server record for NAMESPACE, starting one when needed.

    A foreign answer on the recorded port is never reused or stopped; the stale
    record is replaced by the new server's own record.  With ``spawn=False`` a
    missing server raises instead of starting one.
    """
    st = server_status(namespace)
    if st["state"] == "running":
        return st["record"]
    if not spawn:
        raise store.StoreError("server-not-running", f"no verified frev server for namespace {namespace} ({st['state']})", 503, server_state=st["state"])
    if st["state"] == "stale":
        try:
            record_path(namespace).unlink()
        except OSError:
            pass
    previous = st.get("record") or {}
    log_path = record_path(namespace).with_name("server.log")
    log_path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(log_path.parent, 0o700)
    entry = Path(__file__).resolve().parent.parent / "frev.py"
    with open(log_path, "a", encoding="utf-8") as log:
        child = subprocess.Popen([sys.executable, "-B", str(entry), "serve", "--namespace", namespace],
                                 stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True,
                                 env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})
    # The server outlives this process by design; it is not waited for.  Marking the handle
    # keeps Python from warning about a "still running" child when the handle is collected.
    child.returncode = 0
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        st = server_status(namespace)
        if st["state"] == "running" and st["record"].get("instance") != previous.get("instance"):
            return st["record"]
        time.sleep(0.15)
    raise store.StoreError("server-start-failed", f"the review server did not come up within {wait}s; see {log_path}", 503)


def stop_server(namespace: str) -> dict:
    """SIGTERM the verified server for NAMESPACE; refuse anything not proven ours."""
    st = server_status(namespace)
    if st["state"] == "running":
        os.kill(int(st["record"]["pid"]), signal.SIGTERM)
        for _ in range(40):
            if ping(st["record"]["port"]) is None:
                break
            time.sleep(0.1)
        try:
            record_path(namespace).unlink()
        except OSError:
            pass
        return {"stopped": True, "pid": st["record"]["pid"]}
    if st["state"] == "foreign":
        raise store.StoreError("foreign-server", "the recorded port is answered by something that is not this frev instance; not stopping it", 409,
                               record=st["record"], ping=st.get("ping"))
    if st["state"] == "stale":
        try:
            record_path(namespace).unlink()
        except OSError:
            pass
        return {"stopped": False, "cleared_stale_record": True, "record": st["record"]}
    return {"stopped": False, "state": "absent"}


def serve_forever(namespace: str, *, verbose: bool = False) -> None:
    """Run a server for NAMESPACE in this process until SIGTERM/SIGINT."""
    path = record_path(namespace)
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    existing = server_status(namespace)
    if existing["state"] == "running":
        raise store.StoreError("server-already-running", f"a verified frev server already serves {namespace}", 409, record=existing["record"])
    if existing["state"] == "foreign":
        raise store.StoreError("foreign-server", "the recorded port is answered by something else; refusing to overwrite its record", 409,
                               record=existing["record"])
    srv = ReviewServer(namespace, verbose=verbose, log_path=path.with_name("server.log"))
    store.write_json_atomic(path, srv.record())
    srv.log(f"listening on {srv.url} instance {srv.instance}")

    def _stop(*_):
        threading.Thread(target=srv.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    try:
        srv.serve_forever(poll_interval=0.5)
    finally:
        rec = read_record(namespace)
        if rec and rec.get("instance") == srv.instance:
            try:
                path.unlink()
            except OSError:
                pass
        srv.server_close()
        srv.log("stopped")
