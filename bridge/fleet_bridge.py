#!/usr/bin/env python3
"""Fleet bridge: stdio MCP server, NDJSON socket client, and lease holder.

Standard library only.  Three modes:

  fleet_bridge.py [mcp]           MCP server on stdio (default).  Forwards tool
                                  calls to the Fleet socket named by $FLEET_SOCKET
                                  using the credential in $FLEET_CREDENTIAL_FILE.
                                  Without a valid credential it advertises no tools.
  fleet_bridge.py lease LOCKFILE  Hold an exclusive flock on LOCKFILE for the parent's
                                  lifetime.  Prints "acquired" or "busy"; exits on EOF.
  fleet_bridge.py rpc OP [JSON]   Diagnostic client: one request to the socket.

The bridge knows nothing about task state, Git gates, or wake scheduling; it
frames, forwards, and reports.  It never writes SQLite.
"""
import fcntl
import json
import os
import socket
import sys
import uuid

PROTOCOL_VERSION = 1
MAX_REQUEST_BYTES = 1024 * 1024
MCP_VERSIONS = ("2025-06-18", "2025-03-26", "2024-11-05")
BRIDGE_VERSION = "0.1.0"


def log(msg):
    sys.stderr.write("fleet-bridge: %s\n" % msg)
    sys.stderr.flush()


# ---------------------------------------------------------------- credential

def load_credential():
    """Return (token, runtime_id) from $FLEET_CREDENTIAL_FILE, or (None, None)."""
    path = os.environ.get("FLEET_CREDENTIAL_FILE")
    if not path or not os.path.isfile(path):
        return None, None
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        token = data.get("token")
        rid = data.get("runtimeId")
        if isinstance(token, str) and token:
            return token, rid
    except (OSError, ValueError) as e:
        log("credential unreadable: %s" % e)
    return None, None


# ------------------------------------------------------------------- socket

class RpcError(Exception):
    def __init__(self, code, message, evidence=None, retryable=False):
        super().__init__(message)
        self.code, self.message, self.evidence, self.retryable = code, message, evidence, retryable

    def to_dict(self):
        return {"code": self.code, "message": self.message, "evidence": self.evidence, "retryable": self.retryable}


def rpc_call(operation, params, credential=None, idempotency_key=None, timeout=60.0):
    """One request over a fresh connection; returns the result object or raises RpcError."""
    path = os.environ.get("FLEET_SOCKET")
    if not path:
        raise RpcError("unauthenticated", "FLEET_SOCKET is not set; not running under Fleet")
    req = {"protocolVersion": PROTOCOL_VERSION, "id": str(uuid.uuid4()), "operation": operation, "params": params or {}}
    if credential:
        req["credential"] = credential
    if idempotency_key:
        req["idempotencyKey"] = idempotency_key
    line = (json.dumps(req, ensure_ascii=False) + "\n").encode("utf-8")
    if len(line) > MAX_REQUEST_BYTES:
        raise RpcError("invalid-request", "request exceeds %d bytes" % MAX_REQUEST_BYTES)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        try:
            s.connect(path)
        except OSError as e:
            raise RpcError("unavailable", "Fleet socket unreachable: %s" % e, retryable=True)
        s.sendall(line)
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(65536)
            if not chunk:
                raise RpcError("unavailable", "Fleet closed the connection without a response", retryable=True)
            buf += chunk
            if len(buf) > MAX_REQUEST_BYTES * 4:
                raise RpcError("invalid-request", "response too large")
    finally:
        s.close()
    resp = json.loads(buf.split(b"\n", 1)[0].decode("utf-8"))
    if resp.get("id") != req["id"]:
        raise RpcError("protocol-error", "response id mismatch")
    if "error" in resp:
        e = resp["error"] or {}
        raise RpcError(e.get("code", "error"), e.get("message", "error"), e.get("evidence"), bool(e.get("retryable")))
    return resp.get("result", {})


# ---------------------------------------------------------------------- MCP

class McpServer:
    """Minimal MCP stdio server: initialize, initialized, ping, tools/list, tools/call."""

    def __init__(self):
        self.token, self.runtime_id = load_credential()
        self.tools = None
        self.out = sys.stdout.buffer

    def send(self, obj):
        self.out.write((json.dumps(obj, ensure_ascii=False) + "\n").encode("utf-8"))
        self.out.flush()

    def result(self, mid, result):
        self.send({"jsonrpc": "2.0", "id": mid, "result": result})

    def error(self, mid, code, message, data=None):
        err = {"code": code, "message": message}
        if data is not None:
            err["data"] = data
        self.send({"jsonrpc": "2.0", "id": mid, "error": err})

    def list_tools(self):
        if not self.token:
            return []
        if self.tools is None:
            try:
                self.tools = rpc_call("tools_list", {}, credential=self.token).get("tools", [])
            except RpcError as e:
                log("tools_list failed: %s" % e.message)
                return []
        return self.tools

    def handle(self, msg):
        method = msg.get("method")
        mid = msg.get("id")
        if method == "initialize":
            requested = (msg.get("params") or {}).get("protocolVersion")
            version = requested if requested in MCP_VERSIONS else MCP_VERSIONS[0]
            self.result(mid, {"protocolVersion": version,
                              "capabilities": {"tools": {"listChanged": False}},
                              "serverInfo": {"name": "fleet", "version": BRIDGE_VERSION},
                              "instructions": ("Fleet tools are scoped to this runtime's fleet/task. Mutations take idempotency_key."
                                               if self.token else "No Fleet credential in this environment; no Fleet tools are available.")})
        elif method == "notifications/initialized":
            return
        elif method == "ping":
            self.result(mid, {})
        elif method == "tools/list":
            self.result(mid, {"tools": [{k: t[k] for k in ("name", "description", "inputSchema") if k in t} for t in self.list_tools()]})
        elif method == "tools/call":
            params = msg.get("params") or {}
            name = params.get("name")
            args = params.get("arguments") or {}
            if not self.token:
                self.result(mid, {"content": [{"type": "text", "text": "No Fleet credential; tool unavailable."}], "isError": True})
                return
            if name not in {t["name"] for t in self.list_tools()}:
                self.error(mid, -32602, "Unknown tool: %s" % name)
                return
            try:
                res = rpc_call(name, args, credential=self.token, idempotency_key=args.get("idempotency_key"))
                self.result(mid, {"content": [{"type": "text", "text": json.dumps(res, ensure_ascii=False, indent=1)}], "isError": False})
            except RpcError as e:
                self.result(mid, {"content": [{"type": "text", "text": json.dumps({"error": e.to_dict()}, ensure_ascii=False, indent=1)}], "isError": True})
        elif method and method.startswith("notifications/"):
            return
        elif mid is not None and method:
            self.error(mid, -32601, "Method not found: %s" % method)

    def serve(self):
        stdin = sys.stdin.buffer
        buf = b""
        while True:
            chunk = stdin.read1(65536)
            if not chunk:
                return 0
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                line = line.strip()
                if not line:
                    continue
                if len(line) > MAX_REQUEST_BYTES:
                    self.error(None, -32700, "message too large")
                    continue
                try:
                    msg = json.loads(line.decode("utf-8"))
                except ValueError as e:
                    self.error(None, -32700, "parse error: %s" % e)
                    continue
                if isinstance(msg, list):
                    for m in msg:
                        self.handle(m)
                elif isinstance(msg, dict):
                    self.handle(msg)
                else:
                    self.error(None, -32600, "invalid request")


# -------------------------------------------------------------------- lease

def lease(lockfile):
    """Hold an exclusive non-blocking flock for as long as stdin stays open."""
    fd = os.open(lockfile, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.stdout.write("busy\n")
        sys.stdout.flush()
        return 1
    sys.stdout.write("acquired\n")
    sys.stdout.flush()
    # Block until the parent closes our stdin (or dies).  The descriptor, and
    # therefore the kernel lock, is released only when this process exits.
    while True:
        data = sys.stdin.buffer.read(4096)
        if not data:
            return 0


# ---------------------------------------------------------------------- rpc

def rpc_cli(argv):
    if not argv:
        log("usage: fleet_bridge.py rpc OPERATION [JSON-PARAMS]")
        return 2
    token, _ = load_credential()
    params = json.loads(argv[1]) if len(argv) > 1 else {}
    try:
        res = rpc_call(argv[0], params, credential=token, idempotency_key=params.get("idempotency_key"))
        print(json.dumps(res, ensure_ascii=False, indent=1))
        return 0
    except RpcError as e:
        print(json.dumps({"error": e.to_dict()}, ensure_ascii=False, indent=1))
        return 1


def main(argv):
    mode = argv[0] if argv else "mcp"
    if mode == "mcp":
        return McpServer().serve()
    if mode == "lease":
        if len(argv) < 2:
            log("usage: fleet_bridge.py lease LOCKFILE")
            return 2
        return lease(argv[1])
    if mode == "rpc":
        return rpc_cli(argv[1:])
    log("unknown mode %r" % mode)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
