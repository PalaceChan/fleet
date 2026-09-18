"""Command line used by the commander (see SKILL.md for the loop).

    frev.py start   --fleet-id UUID --runtime-id UUID [--selector FLEET] [--socket-name NAME]
    frev.py publish --session DIR --review FILE [--final] [--no-browser] [--open]
    frev.py status  --session DIR [--json]
    frev.py end     --session DIR
    frev.py validate FILE
    frev.py example
    frev.py serve   --namespace NS          (foreground; normally spawned by publish)
    frev.py server  status|stop [--namespace NS]

Exit status 0 on success, 2 on a refused operation (details as JSON on stdout).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from . import bridge, schema, server, store


def _out(value) -> None:
    print(json.dumps(value, ensure_ascii=False, indent=2))


def _refuse(code: str, message: str, **extra) -> int:
    _out({"ok": False, "code": code, "message": message, **extra})
    return 2


def cmd_start(args) -> int:
    if not args.fleet_id and not args.selector:
        return _refuse("no-fleet-identity", "pass --fleet-id (from your boot message) and --runtime-id; --selector is optional")
    try:
        collected = bridge.collect(fleet_id=args.fleet_id, runtime_id=args.runtime_id, selector=args.selector,
                                   socket_name=args.socket_name)
    except bridge.BridgeError as e:
        return _refuse(e.code, str(e), hint="Fleet must be started in the owner's Emacs; /frev never starts it")
    bearings = collected.get("bearings") or {}
    root = bearings.get("root") or {}
    caller = bearings.get("caller") or {}
    if args.runtime_id and caller.get("current-commander-p") is not True:
        return _refuse("not-current-commander", "your runtime is not the root's current commander runtime; a stale session cannot host a review",
                       runtime_id=args.runtime_id, diagnostics=bearings.get("diagnostics"))
    digest = store.render_digest(bearings)
    session = store.Session.create(namespace=collected.get("namespace", "default"), root={"id": root.get("id"), "name": root.get("name")},
                                   commander_runtime_id=args.runtime_id, snapshot=bearings, digest=digest,
                                   socket_name=args.socket_name, skill_dir=collected.get("skill_dir"))
    print(digest)
    print("---")
    _out({"ok": True, "session": str(session.path), "session_id": session.id, "root": root, "observed_at": bearings.get("observed-at"),
          "diagnostics": bearings.get("diagnostics") or [], "counts": bearings.get("counts"),
          "next": f"write review JSON (frev.py example), then: frev.py publish --session {session.path} --review FILE"})
    return 0


def _load_review(path: str):
    text = Path(path).read_text(encoding="utf-8")
    return schema.parse_strict(text)


def cmd_validate(args) -> int:
    try:
        review = _load_review(args.file)
    except (OSError, ValueError) as e:
        return _refuse("unreadable-review", f"{args.file}: {e}")
    errors = schema.validate_review(review)
    if errors:
        return _refuse("invalid-review", "review did not validate", errors=errors)
    _out({"ok": True, "items": len(review["items"]), "needs_you": [i["id"] for i in review["items"] if schema.needs_you(i)]})
    return 0


def cmd_publish(args) -> int:
    try:
        session = store.Session.open(args.session)
        review = _load_review(args.review)
    except store.StoreError as e:
        return _refuse(e.code, str(e), **e.evidence)
    except (OSError, ValueError) as e:
        return _refuse("unreadable-review", f"{args.review}: {e}")
    try:
        stored = session.publish(review, final=args.final)
    except schema.ValidationError as e:
        return _refuse("invalid-review", "review did not validate; nothing published", errors=e.errors)
    except store.StoreError as e:
        return _refuse(e.code, str(e), **e.evidence)
    meta = session.meta()
    result = {"ok": True, "session": str(session.path), "revision": stored["revision"], "in_reply_to": stored["in_reply_to"],
              "state": meta["state"], "final": stored["final"]}
    if meta["state"] == "ended":
        result["note"] = "session ended; the closing revision is readable in the browser but takes no new rounds"
    try:
        rec = server.ensure_server(meta["namespace"])
        url = rec["url"] + store.url_path(session)
        result["url"] = url
        first = stored["revision"] == 1
        if (first or args.open) and not args.no_browser:
            result["browser_opened"] = bridge.open_browser(url, socket_name=meta.get("socket_name"))
    except store.StoreError as e:
        result["server"] = e.to_dict()
    _out(result)
    return 0


def cmd_status(args) -> int:
    try:
        session = store.Session.open(args.session)
    except store.StoreError as e:
        return _refuse(e.code, str(e), **e.evidence)
    st = session.status()
    if args.json:
        _out(st)
        return 0
    s = st["session"]
    print(f"session {s['id']} · fleet {s['root']['name']} ({s['root']['id']}) · state {s['state']} · head revision {s['head']}")
    print(f"dir {st['path']}")
    try:
        rec = server.ensure_server(s["namespace"], spawn=False)
        print(f"url {rec['url']}{store.url_path(session)}")
    except store.StoreError as e:
        print(f"server: {e}")
    for r in st["revisions"]:
        print(f"- revision {r['revision']} published {r['published_at']}" + (f" in reply to {r['in_reply_to']}" if r["in_reply_to"] else "") + (" (final)" if r.get("final") else ""))
    if not st["submissions"]:
        print("no rounds received yet")
    for sub in st["submissions"]:
        pending = " · PENDING (needs a revision with dispositions)" if sub["id"] == st["pending_submission_id"] else ""
        n = sub.get("notify") or {}
        print(f"\n## round {sub['seq']} · {sub['kind']} · id {sub['id']} · against revision {sub['revision']} · received {sub['received_at']}{pending}")
        print(f"notify: {n.get('result', 'not attempted')}" + (f" ({n.get('code')}: {n.get('reason')})" if n.get("code") else "") + (f" message {n.get('message-id')} {n.get('state')}" if n.get("message-id") else ""))
        rev = session.revision(sub["revision"]) if sub["revision"] else {}
        index = schema.review_index(rev) if rev else {"items": {}, "choices": {}}
        for inp in sub["inputs"]:
            if inp["type"] == "choice":
                item_id, _ = index["choices"].get(inp["choice_id"], (None, set()))
                label = _option_label(rev, inp["choice_id"], inp["option_id"])
                print(f"- input `{inp['id']}` choice `{inp['choice_id']}` (item `{item_id}`) → option `{inp['option_id']}`: {label}")
                if inp.get("text"):
                    print(f"    note: {inp['text']}")
            elif inp["type"] == "comment":
                print(f"- input `{inp['id']}` comment on item `{inp['anchor_id']}`:\n    {inp['text']}")
            else:
                print(f"- input `{inp['id']}` message:\n    {inp['text']}")
    return 0


def _option_label(review: dict, choice_id: str, option_id: str) -> str:
    for item in review.get("items", []):
        for choice in item.get("choices", []):
            if choice["id"] == choice_id:
                for opt in choice["options"]:
                    if opt["id"] == option_id:
                        return f"{opt['label']}  (question: {choice['question']})"
    return "?"


def cmd_end(args) -> int:
    try:
        session = store.Session.open(args.session)
        meta = session.end(by="commander")
    except store.StoreError as e:
        return _refuse(e.code, str(e), **e.evidence)
    pending = session.pending_submission()
    _out({"ok": True, "state": meta["state"], "ended_at": meta.get("ended_at"),
          "pending_submission_id": pending["id"] if pending else None,
          "note": "a pending round still needs a final revision with dispositions (publish --final)" if pending else "no rounds owed"})
    return 0


def cmd_example(_args) -> int:
    _out(schema.EXAMPLE_REVIEW)
    return 0


def cmd_serve(args) -> int:
    try:
        server.serve_forever(args.namespace, verbose=args.verbose)
    except store.StoreError as e:
        return _refuse(e.code, str(e), **e.evidence)
    return 0


def cmd_server(args) -> int:
    ns = args.namespace or "default"
    if args.action == "status":
        _out(server.server_status(ns))
        return 0
    try:
        _out(server.stop_server(ns))
    except store.StoreError as e:
        return _refuse(e.code, str(e), **e.evidence)
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="frev.py", description="frev executive review: fresh session, publish, rounds")
    sub = p.add_subparsers(dest="command", required=True)

    s = sub.add_parser("start", help="collect fresh evidence and create a new session directory")
    s.add_argument("--fleet-id", help="fleet UUID from the commander's boot message")
    s.add_argument("--runtime-id", help="runtime UUID from the commander's boot message (bound as notify target)")
    s.add_argument("--selector", help="optional explicit /frev FLEET selector; must agree with --fleet-id")
    s.add_argument("--socket-name", help="emacsclient --socket-name, only for a non-default Fleet server")
    s.set_defaults(func=cmd_start)

    s = sub.add_parser("publish", help="validate and publish the next revision; ensure the server; open the browser on revision 1")
    s.add_argument("--session", required=True)
    s.add_argument("--review", required=True, help="review JSON file")
    s.add_argument("--final", action="store_true", help="closing revision after the session ended")
    s.add_argument("--no-browser", action="store_true")
    s.add_argument("--open", action="store_true", help="open the browser even after revision 1")
    s.set_defaults(func=cmd_publish)

    s = sub.add_parser("status", help="show the session, its revisions and every round (inputs in full)")
    s.add_argument("--session", required=True)
    s.add_argument("--json", action="store_true")
    s.set_defaults(func=cmd_status)

    s = sub.add_parser("end", help="close the session from the commander's side")
    s.add_argument("--session", required=True)
    s.set_defaults(func=cmd_end)

    s = sub.add_parser("validate", help="validate a review JSON file")
    s.add_argument("file")
    s.set_defaults(func=cmd_validate)

    s = sub.add_parser("example", help="print an example review JSON")
    s.set_defaults(func=cmd_example)

    s = sub.add_parser("serve", help="run the loopback server in the foreground (publish spawns it for you)")
    s.add_argument("--namespace", required=True)
    s.add_argument("--verbose", action="store_true")
    s.set_defaults(func=cmd_serve)

    s = sub.add_parser("server", help="status or stop of the owned server")
    s.add_argument("action", choices=["status", "stop"])
    s.add_argument("--namespace")
    s.set_defaults(func=cmd_server)
    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
