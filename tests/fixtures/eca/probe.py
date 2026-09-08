#!/usr/bin/env python3
"""Raw Content-Length JSON-RPC probe against the native eca server.

Records every message with a monotonic timestamp so ordering of the
chat/prompt response vs statusChanged/progress can be established.
"""
import json, os, subprocess, sys, time, threading, uuid, tempfile

ECA = os.path.expanduser("~/.emacs.d/eca/eca")
root = tempfile.mkdtemp(prefix="fleet-probe-ws-")
cache = tempfile.mkdtemp(prefix="fleet-probe-cache-")
env = dict(os.environ)
env["XDG_CACHE_HOME"] = cache
# overlay: make sure ECA_CONFIG merges (we set a harmless key we can see in config/updated? not visible; instead disable nothing)
env["ECA_CONFIG"] = json.dumps({"toolCall": {"approval": {"byDefault": "ask"}}})

proc = subprocess.Popen([ECA, "server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=open(os.path.join(cache, "stderr.log"), "wb"), env=env, cwd=root)
t0 = time.monotonic()
log = []
lock = threading.Lock()
next_id = [0]
pending = {}

def send(obj):
    body = json.dumps(obj).encode()
    proc.stdin.write(b"Content-Length: %d\r\n\r\n" % (len(body) + 1) + body + b"\n")
    proc.stdin.flush()
    with lock:
        log.append({"t": round(time.monotonic() - t0, 4), "dir": "->", "msg": obj})

def request(method, params):
    next_id[0] += 1
    send({"jsonrpc": "2.0", "id": next_id[0], "method": method, "params": params})
    return next_id[0]

def notify(method, params=None):
    m = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        m["params"] = params
    send(m)

def reader():
    buf = b""
    while True:
        chunk = proc.stdout.read1(65536) if hasattr(proc.stdout, "read1") else proc.stdout.read(1)
        if not chunk:
            break
        buf += chunk
        while True:
            sep = buf.find(b"\r\n\r\n")
            if sep < 0:
                break
            headers = buf[:sep].decode()
            length = None
            for h in headers.split("\r\n"):
                if h.lower().startswith("content-length:"):
                    length = int(h.split(":", 1)[1].strip())
            if length is None or len(buf) < sep + 4 + length:
                break
            body = buf[sep + 4: sep + 4 + length]
            buf = buf[sep + 4 + length:]
            try:
                msg = json.loads(body)
            except Exception as e:
                msg = {"parse-error": str(e), "raw": body[:200].decode(errors="replace")}
            with lock:
                log.append({"t": round(time.monotonic() - t0, 4), "dir": "<-", "msg": msg})
            # answer server requests we know
            if "id" in msg and "method" in msg:
                if msg["method"] == "chat/askQuestion":
                    send({"jsonrpc": "2.0", "id": msg["id"], "result": {"answer": None, "cancelled": True}})
                else:
                    send({"jsonrpc": "2.0", "id": msg["id"], "result": None})

th = threading.Thread(target=reader, daemon=True)
th.start()

request("initialize", {
    "processId": os.getpid(),
    "clientInfo": {"name": "fleet-probe", "version": "0"},
    "capabilities": {"codeAssistant": {"chat": True, "chatCapabilities": {"askQuestion": True}, "editor": {"diagnostics": True}}},
    "initializationOptions": {},
    "workspaceFolders": [{"uri": "file://" + root, "name": os.path.basename(root)}],
})
# wait for initialize result
deadline = time.time() + 60
while time.time() < deadline:
    with lock:
        if any(m["dir"] == "<-" and m["msg"].get("id") == 1 for m in log):
            break
    time.sleep(0.05)
notify("initialized")
# wait for models to be loaded (config/updated carrying :models)
model = None
deadline = time.time() + 60
while time.time() < deadline and model is None:
    with lock:
        for m in log:
            msg = m["msg"]
            if m["dir"] == "<-" and msg.get("method") == "config/updated":
                chat = msg.get("params", {}).get("chat", {})
                if chat.get("models"):
                    model = chat.get("selectModel") or chat.get("defaultModel")
    time.sleep(0.1)
print("model ready:", model, "at", round(time.monotonic() - t0, 2))
chat_id = str(uuid.uuid4())
mode = sys.argv[1] if len(sys.argv) > 1 else "prompt"
base = {"chatId": chat_id, "contexts": [], "model": model, "agent": "agent"}
if mode == "prompt":
    rid = request("chat/prompt", dict(base, message="Reply with exactly the single word OK and nothing else.", **{"request-id": 1}))
    # wait until idle after running
    seen_running = False
    deadline = time.time() + 120
    while time.time() < deadline:
        with lock:
            for m in log:
                if m["dir"] == "<-" and m["msg"].get("method") == "chat/statusChanged":
                    st = m["msg"]["params"].get("status")
                    if st == "running":
                        seen_running = True
                    if st == "idle" and seen_running:
                        deadline = min(deadline, time.time() + 2.0)
        time.sleep(0.1)
elif mode == "badmodel":
    request("chat/prompt", dict(base, message="hi", model="nonexistent/does-not-exist", **{"request-id": 1}))
    time.sleep(6)
elif mode == "double":
    request("chat/prompt", dict(base, message="Reply with exactly the single word OK.", **{"request-id": 1}))
    time.sleep(0.3)
    request("chat/prompt", dict(base, message="Reply with exactly the single word YES.", **{"request-id": 2}))
    time.sleep(40)
elif mode == "stop":
    request("chat/prompt", dict(base, message="Count slowly from 1 to 300, one number per line, no other text.", **{"request-id": 1}))
    time.sleep(5)
    notify("chat/promptStop", {"chatId": chat_id})
    time.sleep(8)
elif mode == "question":
    request("chat/prompt", dict(base, message="Use your ask-user question tool to ask me 'red or blue?' with options red and blue. Do nothing else.", **{"request-id": 1}))
    time.sleep(45)

request("shutdown", None)
time.sleep(0.5)
notify("exit")
try:
    proc.wait(timeout=10)
except subprocess.TimeoutExpired:
    proc.kill()
out = {"eca_version": subprocess.run([ECA, "--version"], capture_output=True, text=True).stdout.strip(),
       "mode": mode, "root": root, "cache": cache, "exit": proc.returncode, "log": log}
path = f"/tmp/fleet-probe/trace-{mode}.json"
json.dump(out, open(path, "w"), indent=1)
print("wrote", path, "messages:", len(log), "exit", proc.returncode)
print("cache contents:", subprocess.run(["find", cache, "-maxdepth", "3"], capture_output=True, text=True).stdout)
