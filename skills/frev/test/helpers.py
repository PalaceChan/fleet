"""Shared fixtures for the frev Python tests: temp roots, a fake emacsclient spy, sessions.

Nothing here touches the owner's Emacs, Fleet store or real XDG directories:
``FREV_DATA_ROOT``/``FREV_RUNTIME_ROOT`` point at a temp dir and
``FREV_EMACSCLIENT`` at a spy script that records its argv and writes a canned
JSON answer into the OUT file named in the Elisp form.
"""

from __future__ import annotations

import copy
import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parent.parent
APP_DIR = SKILL_DIR / "app"
sys.path.insert(0, str(APP_DIR))

from frev_app import bridge, schema, server, store  # noqa: E402,F401

ROOT_ID = "11111111-1111-1111-1111-111111111111"
RUNTIME_ID = "rt-current"

BEARINGS = {
    "schema": 1, "observed-at": "2026-09-18T10:00:00+0000",
    "root": {"id": ROOT_ID, "name": "workshop"},
    "caller": {"runtime-id": RUNTIME_ID, "current-commander-p": True},
    "config": {"status": "ok", "declared": ["frontend"]},
    "members": [
        {"id": ROOT_ID, "name": "workshop", "selector": "workshop", "role": "root", "status": "observed", "lifecycle": "active",
         "supervision": True, "commander-label": "live/idle", "pending-events": 0, "open-requests": [],
         "tasks": [{"id": "t1", "name": "navigation", "kind": "change", "lifecycle": "active", "phase": "needs-decision",
                    "detail": "Which threshold?", "runtime": None, "wait": None, "artifacts": [], "external-jobs": [], "failed-operations": [],
                    "decisions": [{"id": "d1", "question": "Which threshold?", "authority": "human", "state": "open"}],
                    "newer-instructions": 0, "derived": {"state": "decision", "source": "decision"}}]},
        {"id": "3333", "name": "frontend", "selector": "workshop/frontend", "role": "lieutenant", "status": "read-failed", "error": "database is locked"},
    ],
    "requests": [], "diagnostics": ["workshop/frontend: read failed (database is locked)"],
    "counts": {"members-declared": 1, "members-existing": 2, "members-observed": 1, "tasks": 1},
}

SPY_SCRIPT = r'''#!/usr/bin/env python3
import json, os, re, sys
argv = sys.argv[1:]
form = argv[argv.index("--eval") + 1] if "--eval" in argv else ""
with open(os.environ["FREV_SPY_LOG"], "a") as fh:
    fh.write(json.dumps(argv) + "\n")
m = re.search(r'\(frev-(collect|notify)-to-file "((?:[^"\\]|\\.)+)"', form)
if not m:
    print("t"); sys.exit(0)
out = m.group(2).encode().decode("unicode_escape")
mode = os.environ.get("FREV_SPY_MODE", "ok")
if mode == "exit-error":
    sys.stderr.write("*ERROR*: server not responding\n"); sys.exit(1)
if m.group(1) == "collect":
    answer = json.load(open(os.environ["FREV_SPY_COLLECT"]))
elif mode == "refuse":
    answer = {"ok": True, "result": "refused", "code": "human-draft", "reason": "Someone is typing", "target": "rt-current", "current": "rt-current"}
elif mode == "bridge-error":
    answer = {"ok": False, "code": "session-outside-data-root", "message": "not under root"}
else:
    answer = {"ok": True, "result": "queued", "message-id": "m-1", "state": "queued", "target": "rt-current", "warnings": []}
json.dump(answer, open(out, "w"))
print('"ok"')
'''


def example_review() -> dict:
    return copy.deepcopy(schema.EXAMPLE_REVIEW)


class FrevTestCase(unittest.TestCase):
    """Temp roots + spy emacsclient for every test; restores the environment afterwards."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="frev-test-"))
        self.data_root = self.tmp / "data"
        self.runtime_root = self.tmp / "run"
        self.spy_log = self.tmp / "spy.log"
        self.spy = self.tmp / "emacsclient"
        self.spy.write_text(SPY_SCRIPT, encoding="utf-8")
        self.spy.chmod(self.spy.stat().st_mode | stat.S_IXUSR)
        collect = self.tmp / "collect.json"
        collect.write_text(json.dumps({"ok": True, "schema": 1, "namespace": "ns1", "data-root": str(self.data_root),
                                       "skill_dir": str(SKILL_DIR), "bearings": BEARINGS}), encoding="utf-8")
        self._env = dict(os.environ)
        os.environ.update({
            "FREV_DATA_ROOT": str(self.data_root), "FREV_RUNTIME_ROOT": str(self.runtime_root),
            "FREV_EMACSCLIENT": str(self.spy), "FREV_SPY_LOG": str(self.spy_log), "FREV_SPY_COLLECT": str(collect),
            "FREV_SPY_MODE": "ok", "FREV_NO_BROWSER": "1", "PYTHONDONTWRITEBYTECODE": "1",
        })

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self._env)
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    # helpers

    def make_session(self, *, publish: bool = True, review: dict | None = None) -> store.Session:
        s = store.Session.create(namespace="ns1", root={"id": ROOT_ID, "name": "workshop"}, commander_runtime_id=RUNTIME_ID,
                                 snapshot=BEARINGS, digest=store.render_digest(BEARINGS), skill_dir=str(SKILL_DIR))
        if publish:
            s.publish(review or example_review())
        return s

    def spy_calls(self) -> list:
        if not self.spy_log.exists():
            return []
        return [json.loads(line) for line in self.spy_log.read_text(encoding="utf-8").splitlines() if line.strip()]

    @staticmethod
    def feedback(sub_id="sub-1", revision=1, inputs=None) -> dict:
        return {"id": sub_id, "revision": revision, "kind": "feedback", "inputs": inputs if inputs is not None else [
            {"id": "i1", "type": "choice", "choice_id": "navigation-tests", "option_id": "focused"},
            {"id": "i2", "type": "comment", "anchor_id": "release-note", "text": "Shorter opening."},
            {"id": "i3", "type": "message", "text": "Thanks."}]}

    @staticmethod
    def with_dispositions(review: dict, submission: dict, status="applied") -> dict:
        r = copy.deepcopy(review)
        r["dispositions"] = [{"input_id": i["id"], "status": status, "note": f"handled {i['id']}"} for i in submission["inputs"]]
        return r
