#!/usr/bin/env python3
"""Fake native ECA server for deterministic adapter tests.

Speaks the Content-Length JSON-RPC framing of the real server and replays the
orderings recorded in tests/fixtures/eca (see docs/eca-compatibility.md).
Behaviour is selected by keywords in the prompt text:

  (default)   normal turn -> assistant "OK", idle, finished, metadata
  ERRORMODEL  accepted (status prompting), then system "Error:" text, idle, finished
  NOMODEL     system error text, idle, finished, then response status "error"
  QUESTION    ask_user tool -> chat/askQuestion server request; waits for the answer
  APPROVAL    tool needing manual approval; waits for chat/toolCallApprove|Reject
  SLOW        streams until chat/promptStop -> statusChanged stopping + finished (no idle)
  NOACK       running observed but the response never comes (until promptStop)
  SILENT      nothing at all: no events, no response
  SUBAGENT    child-chat events carrying parentChatId before finishing
  DUPIDLE     idle/finished emitted twice
  CRASH       accepted, then the server process exits abruptly

Every inbound message is appended as JSON to $FAKE_ECA_LOG when set, so tests
can assert what the client actually sent.
"""
import json
import os
import sys
import threading
import time
import uuid

LOG = os.environ.get("FAKE_ECA_LOG")
_out_lock = threading.Lock()
_stdout = sys.stdout.buffer
_state = {"turn": None, "chat": None, "pending_question": None, "pending_approval": None, "stop": threading.Event()}


def send(obj):
    body = json.dumps(obj).encode("utf-8")
    with _out_lock:
        _stdout.write(b"Content-Length: %d\r\n\r\n" % (len(body) + 1))
        _stdout.write(body + b"\n")
        _stdout.flush()


def notify(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})


def content(chat_id, role, c, parent=None):
    p = {"chatId": chat_id, "role": role, "content": c}
    if parent:
        p["parentChatId"] = parent
    notify("chat/contentReceived", p)


def status(chat_id, st):
    notify("chat/statusChanged", {"chatId": chat_id, "status": st})


def log(msg):
    if LOG:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(json.dumps(msg) + "\n")


def tick():
    time.sleep(0.02)


def finish(chat_id, dup=False):
    content(chat_id, "system", {"type": "usage", "sessionTokens": 10, "limit": {"context": 1000, "output": 100}})
    status(chat_id, "idle")
    content(chat_id, "system", {"type": "progress", "state": "finished"})
    if dup:
        status(chat_id, "idle")
        content(chat_id, "system", {"type": "progress", "state": "finished"})
    tick()
    content(chat_id, "system", {"type": "metadata", "title": "fake title"})
    _state["turn"] = None


def run_prompt(msg):
    p = msg["params"]
    chat_id = p["chatId"]
    text = p.get("message", "")
    rid = msg["id"]
    first = _state["chat"] != chat_id
    _state["chat"] = chat_id
    _state["turn"] = rid
    _state["stop"].clear()

    def respond(st="prompting", model=None):
        send({"jsonrpc": "2.0", "id": rid, "result": {"chatId": chat_id, "model": model or p.get("model") or "fake/model", "status": st}})

    if "SILENT" in text:
        return
    if first:
        notify("chat/opened", {"chatId": chat_id})
    content(chat_id, "user", {"type": "text", "text": text + "\n", "contentId": str(uuid.uuid4())})
    content(chat_id, "system", {"type": "progress", "state": "running", "text": "Loading config"})
    if "NOMODEL" in text:
        content(chat_id, "system", {"type": "text", "text": "Error: No available model found. Configure a provider."})
        status(chat_id, "idle")
        content(chat_id, "system", {"type": "progress", "state": "finished"})
        respond("error", "error")
        _state["turn"] = None
        return
    tick()
    status(chat_id, "running")
    content(chat_id, "system", {"type": "progress", "state": "running", "text": "Waiting model"})
    if "NOACK" in text:
        _state["stop"].wait()
        status(chat_id, "stopping")
        content(chat_id, "system", {"type": "progress", "state": "finished"})
        _state["turn"] = None
        return
    respond()
    if "CRASH" in text:
        tick()
        os._exit(3)
    tick()
    if "ERRORMODEL" in text:
        content(chat_id, "system", {"type": "text", "text": "\n\nError: API url not found.\nMake sure you have provider configured."})
        status(chat_id, "idle")
        content(chat_id, "system", {"type": "progress", "state": "finished"})
        _state["turn"] = None
        return
    content(chat_id, "system", {"type": "progress", "state": "running", "text": "Generating"})
    if "QUESTION" in text:
        tid = "call_q1"
        content(chat_id, "assistant", {"type": "toolCallPrepare", "id": tid, "name": "ask_user", "server": "eca", "argumentsText": "{"})
        content(chat_id, "assistant", {"type": "toolCallRun", "id": tid, "name": "ask_user", "server": "eca", "manualApproval": False,
                                       "arguments": {"question": "Red or blue?"}, "details": {}})
        content(chat_id, "assistant", {"type": "toolCallRunning", "id": tid, "name": "ask_user", "server": "eca", "arguments": {}, "details": {}})
        content(chat_id, "system", {"type": "progress", "state": "running", "text": "Waiting answer"})
        qid = 1000 + rid
        _state["pending_question"] = (qid, chat_id, tid)
        send({"jsonrpc": "2.0", "id": qid, "method": "chat/askQuestion",
              "params": {"chatId": chat_id, "question": "Red or blue?", "options": [{"label": "Red"}, {"label": "Blue"}],
                         "toolCallId": tid, "allowFreeform": True}})
        return  # continues in on_question_answer
    if "APPROVAL" in text:
        tid = "call_a1"
        content(chat_id, "assistant", {"type": "toolCallRun", "id": tid, "name": "shell_command", "server": "eca", "manualApproval": True,
                                       "arguments": {"command": "rm -rf build"}, "details": {}, "summary": "Run rm -rf build"})
        _state["pending_approval"] = (chat_id, tid)
        return  # continues in on_approval
    if "SUBAGENT" in text:
        tid = "call_s1"
        child = str(uuid.uuid4())
        content(chat_id, "assistant", {"type": "toolCallRun", "id": tid, "name": "spawn_agent", "server": "eca", "manualApproval": False,
                                       "arguments": {}, "details": {"type": "subagent", "subagentChatId": child}})
        content(chat_id, "assistant", {"type": "toolCallRunning", "id": tid, "name": "spawn_agent", "server": "eca", "arguments": {},
                                       "details": {"type": "subagent", "subagentChatId": child}})
        for i in range(3):
            content(child, "assistant", {"type": "text", "text": "child %d " % i}, parent=chat_id)
            notify("chat/statusChanged", {"chatId": child, "status": "idle"})  # child idle must not finish parent
        content(child, "system", {"type": "progress", "state": "finished"}, parent=chat_id)
        tick()
        content(chat_id, "assistant", {"type": "toolCalled", "id": tid, "name": "spawn_agent", "server": "eca", "arguments": {},
                                       "outputs": [{"type": "text", "text": "child done"}], "details": {"type": "subagent", "subagentChatId": child},
                                       "totalTimeMs": 5})
    if "SLOW" in text:
        n = 0
        while not _state["stop"].wait(0.05):
            n += 1
            content(chat_id, "assistant", {"type": "text", "text": "%d\n" % n})
        status(chat_id, "stopping")
        content(chat_id, "system", {"type": "progress", "state": "finished"})
        _state["turn"] = None
        return
    content(chat_id, "assistant", {"type": "text", "text": "OK"})
    finish(chat_id, dup="DUPIDLE" in text)


def on_question_answer(msg):
    qid, chat_id, tid = _state["pending_question"]
    _state["pending_question"] = None
    res = msg.get("result") or {}
    cancelled = bool(res.get("cancelled"))
    content(chat_id, "assistant", {"type": "toolCalled", "id": tid, "name": "ask_user", "server": "eca", "arguments": {},
                                   "outputs": [{"type": "text", "text": "cancelled" if cancelled else res.get("answer")}],
                                   "error": cancelled, "details": {}, "totalTimeMs": 1})
    content(chat_id, "system", {"type": "progress", "state": "running", "text": "Generating"})
    content(chat_id, "assistant", {"type": "text", "text": "answered: %s" % ("cancelled" if cancelled else res.get("answer"))})
    finish(chat_id)


def on_approval(msg, approved):
    chat_id, tid = _state["pending_approval"]
    _state["pending_approval"] = None
    if approved:
        content(chat_id, "assistant", {"type": "toolCallRunning", "id": tid, "name": "shell_command", "server": "eca", "arguments": {}, "details": {}})
        content(chat_id, "assistant", {"type": "toolCalled", "id": tid, "name": "shell_command", "server": "eca", "arguments": {},
                                       "outputs": [{"type": "text", "text": "done"}], "details": {}, "totalTimeMs": 2})
    else:
        content(chat_id, "assistant", {"type": "toolCallRejected", "id": tid, "name": "shell_command", "server": "eca", "arguments": {}, "details": {}})
    content(chat_id, "assistant", {"type": "text", "text": "OK"})
    finish(chat_id)


def handle(msg):
    log(msg)
    method = msg.get("method")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": msg["id"], "result": {"chatWelcomeMessage": "# fake welcome\n"}})
    elif method == "initialized":
        notify("config/updated", {"chat": {"models": ["fake/model"], "selectModel": "fake/model", "defaultModel": "fake/model",
                                           "agents": ["agent"], "selectAgent": "agent", "variants": []}})
        notify("tool/serverUpdated", {"name": "fleet", "status": "running", "command": "bridge", "args": [], "tools": []})
    elif method == "chat/prompt":
        threading.Thread(target=run_prompt, args=(msg,), daemon=True).start()
    elif method == "chat/promptStop":
        _state["stop"].set()
    elif method == "chat/toolCallApprove":
        if _state["pending_approval"]:
            threading.Thread(target=on_approval, args=(msg, True), daemon=True).start()
    elif method == "chat/toolCallReject":
        if _state["pending_approval"]:
            threading.Thread(target=on_approval, args=(msg, False), daemon=True).start()
    elif method == "shutdown":
        send({"jsonrpc": "2.0", "id": msg["id"], "result": None})
    elif method == "exit":
        os._exit(0)
    elif method is None and "id" in msg and _state["pending_question"] and msg["id"] == _state["pending_question"][0]:
        threading.Thread(target=on_question_answer, args=(msg,), daemon=True).start()
    elif "id" in msg and method:
        send({"jsonrpc": "2.0", "id": msg["id"], "result": None})


def main():
    buf = b""
    stdin = sys.stdin.buffer
    while True:
        chunk = stdin.read1(65536)
        if not chunk:
            os._exit(0)
        buf += chunk
        while True:
            sep = buf.find(b"\r\n\r\n")
            if sep < 0:
                break
            length = None
            for h in buf[:sep].decode().split("\r\n"):
                if h.lower().startswith("content-length:"):
                    length = int(h.split(":", 1)[1])
            if length is None or len(buf) < sep + 4 + length:
                break
            body = buf[sep + 4: sep + 4 + length]
            buf = buf[sep + 4 + length:]
            try:
                handle(json.loads(body))
            except Exception as e:  # keep serving; tests inspect the log
                log({"fake-error": str(e)})


if __name__ == "__main__":
    main()
