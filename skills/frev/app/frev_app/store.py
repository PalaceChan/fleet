"""Session store: plain files under ``$XDG_DATA_HOME/frev/<namespace>/<root-uuid>/<session-id>/``.

    session.json           identity, bound commander runtime, state, head revision
    snapshot.json          fsum evidence the first revision was authored from
    digest.md              short Markdown rendering of the snapshot (for the commander)
    revisions/0001.json    immutable published review revisions (validated)
    submissions/<id>.json  rounds sent from the browser (validated), with notify result
    events.jsonl           append-only log of what happened

States: ``authoring`` (created, nothing published) -> ``awaiting-user`` (revision
visible, no round pending) <-> ``awaiting-commander`` (a round is pending) ->
``ended``.  Every ``/frev`` creates a new session directory; nothing here resumes.

All mutations take the session's ``flock`` and write files atomically
(temp + ``os.replace``), so the CLI (commander) and the server (browser) can
share a session without a database.  No lock is held across ``emacsclient``.
"""

from __future__ import annotations

import datetime as _dt
import fcntl
import json
import os
import re
import secrets
from contextlib import contextmanager
from pathlib import Path

from . import schema

SCHEMA = 1
STATES = ("authoring", "awaiting-user", "awaiting-commander", "ended")
SEGMENT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$")
"""Namespace, root id and session id path segments must match this before any path is built."""


class StoreError(Exception):
    """A refused store operation; ``code`` is stable, ``status`` a suggested HTTP status."""

    def __init__(self, code: str, message: str, status: int = 400, **evidence):
        super().__init__(message)
        self.code = code
        self.status = status
        self.evidence = evidence

    def to_dict(self) -> dict:
        return {"ok": False, "code": self.code, "message": str(self), **self.evidence}


def now() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def data_root() -> Path:
    """The frev data root (``FREV_DATA_ROOT`` overrides; else XDG data home)."""
    override = os.environ.get("FREV_DATA_ROOT")
    if override:
        return Path(override).expanduser().resolve()
    xdg = os.environ.get("XDG_DATA_HOME")
    base = Path(xdg) if xdg else Path.home() / ".local" / "share"
    return (base / "frev").resolve()


def runtime_root() -> Path:
    """Private directory for server records (``FREV_RUNTIME_ROOT``, else ``$XDG_RUNTIME_DIR/frev``)."""
    override = os.environ.get("FREV_RUNTIME_ROOT")
    if override:
        return Path(override).expanduser().resolve()
    xdg = os.environ.get("XDG_RUNTIME_DIR")
    if xdg and Path(xdg).is_dir():
        return (Path(xdg) / "frev").resolve()
    return data_root() / "runtime"


def _mkdir_private(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(path, 0o700)
    except OSError:
        pass
    return path


def write_json_atomic(path: Path, value) -> None:
    """Write VALUE as JSON to PATH via a temp file and ``os.replace``; mode 0600."""
    tmp = path.with_name(path.name + f".tmp-{os.getpid()}-{secrets.token_hex(4)}")
    data = json.dumps(value, ensure_ascii=False, indent=2, sort_keys=False) + "\n"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def read_json(path: Path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def check_segment(value, what: str) -> str:
    if not isinstance(value, str) or not SEGMENT_RE.match(value):
        raise StoreError("bad-path-segment", f"{what} has an unexpected shape", 404)
    return value


def new_session_id() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y%m%dT%H%M%S") + "-" + secrets.token_hex(3)


class Session:
    """One review session directory.  Construct through ``create`` or ``open``."""

    def __init__(self, path: Path):
        self.path = Path(path)

    # ------------------------------------------------------------ paths

    @property
    def meta_path(self) -> Path:
        return self.path / "session.json"

    @property
    def revisions_dir(self) -> Path:
        return self.path / "revisions"

    @property
    def submissions_dir(self) -> Path:
        return self.path / "submissions"

    def revision_path(self, n: int) -> Path:
        return self.revisions_dir / f"{int(n):04d}.json"

    def submission_path(self, submission_id: str) -> Path:
        check_segment(submission_id, "submission id")
        return self.submissions_dir / f"{submission_id}.json"

    # ------------------------------------------------------------ lock

    @contextmanager
    def locked(self):
        """Exclusive advisory lock over the session's mutations (CLI and server share it)."""
        fd = os.open(self.path / ".lock", os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)

    # ------------------------------------------------------------ reads

    def meta(self) -> dict:
        try:
            return read_json(self.meta_path)
        except FileNotFoundError:
            raise StoreError("session-missing", "session.json is missing", 404, path=str(self.path))
        except json.JSONDecodeError as e:
            raise StoreError("session-corrupt", f"session.json is not valid JSON: {e}", 500, path=str(self.path))

    @property
    def id(self) -> str:
        return self.meta()["id"]

    def head(self) -> int:
        return int(self.meta().get("head", 0))

    def state(self) -> str:
        return self.meta().get("state", "authoring")

    def revision(self, n: int) -> dict:
        path = self.revision_path(n)
        if not path.is_file():
            raise StoreError("no-such-revision", f"revision {n} does not exist", 404)
        return read_json(path)

    def current_review(self):
        head = self.head()
        return self.revision(head) if head > 0 else None

    def revisions(self) -> list:
        out = []
        if self.revisions_dir.is_dir():
            for p in sorted(self.revisions_dir.glob("[0-9][0-9][0-9][0-9].json")):
                r = read_json(p)
                out.append({"revision": r.get("revision"), "published_at": r.get("published_at"),
                            "in_reply_to": r.get("in_reply_to"), "final": r.get("final", False),
                            "note": r.get("note", ""), "dispositions": r.get("dispositions", []),
                            "title": r.get("title")})
        return out

    def submissions(self) -> list:
        out = []
        if self.submissions_dir.is_dir():
            for p in self.submissions_dir.glob("*.json"):
                if p.name.startswith("."):
                    continue
                out.append(read_json(p))
        out.sort(key=lambda s: (s.get("seq", 0), s.get("received_at", "")))
        return out

    def submission(self, submission_id: str) -> dict:
        path = self.submission_path(submission_id)
        if not path.is_file():
            raise StoreError("no-such-submission", f"submission {submission_id} does not exist", 404)
        return read_json(path)

    def pending_submission(self):
        """The latest round no revision has replied to yet, or None."""
        answered = {r["in_reply_to"] for r in self.revisions() if r.get("in_reply_to")}
        # An empty `end' is closure only: nothing in it needs a disposition.
        pending = [s for s in self.submissions() if s["id"] not in answered and (s.get("inputs") or s.get("kind") != "end")]
        return pending[-1] if pending else None

    def status(self) -> dict:
        """Everything the CLI and the browser need to show the session (no evidence dump)."""
        meta = self.meta()
        subs = [{"id": s["id"], "seq": s["seq"], "kind": s["kind"], "revision": s["revision"],
                 "received_at": s["received_at"], "inputs": s["inputs"], "notify": s.get("notify")}
                for s in self.submissions()]
        pending = self.pending_submission()
        return {
            "session": {k: meta.get(k) for k in ("schema", "id", "namespace", "root", "commander_runtime_id",
                                                  "created_at", "state", "head", "ended_at", "observed_at")},
            "path": str(self.path),
            "revisions": self.revisions(),
            "submissions": subs,
            "pending_submission_id": pending["id"] if pending else None,
        }

    # ------------------------------------------------------------ events

    def append_event(self, _event: str, **payload) -> None:
        line = json.dumps({"at": now(), "event": _event, **payload}, ensure_ascii=False)
        fd = os.open(self.path / "events.jsonl", os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            os.write(fd, (line + "\n").encode("utf-8"))
        finally:
            os.close(fd)

    def _update_meta(self, **changes) -> dict:
        meta = self.meta()
        meta.update(changes)
        meta["updated_at"] = now()
        write_json_atomic(self.meta_path, meta)
        return meta

    # ------------------------------------------------------------ mutations

    def publish(self, review: dict, *, final: bool = False) -> dict:
        """Validate REVIEW and publish it as the next immutable revision.

        While a round is pending, the review must carry a disposition for every
        input of that round (accounting is not optional).  After ``ended`` only
        ``final`` read-only revisions may follow (a closing note, or the owed
        dispositions).  Returns the stored revision.
        """
        schema.validate_review_or_raise(review)
        with self.locked():
            meta = self.meta()
            state = meta.get("state", "authoring")
            pending = self.pending_submission()
            if state == "ended" and not final:
                raise StoreError("session-ended", "the session has ended; pass final=True to append a read-only closing revision", 409)
            if pending is not None:
                missing = schema.missing_dispositions(review, pending)
                if missing:
                    raise StoreError("inputs-unaccounted", "every input of the pending round needs a disposition", 409,
                                     submission_id=pending["id"], missing=missing)
            elif review.get("dispositions"):
                raise StoreError("no-pending-round", "dispositions given but no round is pending", 409)
            n = int(meta.get("head", 0)) + 1
            stored = dict(review)
            stored.update({"revision": n, "published_at": now(),
                           "in_reply_to": pending["id"] if pending else None, "final": bool(final or state == "ended")})
            self.revisions_dir.mkdir(exist_ok=True)
            path = self.revision_path(n)
            if path.exists():
                raise StoreError("revision-exists", f"revision {n} already exists", 500)
            write_json_atomic(path, stored)
            new_state = "ended" if state == "ended" else "awaiting-user"
            self._update_meta(head=n, state=new_state)
            self.append_event("revision-published", revision=n, in_reply_to=stored["in_reply_to"], final=stored["final"])
            return stored

    def submit(self, submission: dict) -> dict:
        """Persist one round from the browser.  Returns the stored submission.

        Idempotent on ``id``: the exact same payload returns the stored record
        (``replayed`` marker set by the caller); a different payload under the same
        id is a conflict.  A round targets the head revision; anything else is
        stale.  ``feedback`` needs state ``awaiting-user``; ``end`` is accepted in
        ``awaiting-user`` (with or without inputs) and in ``awaiting-commander``
        (closure only, no inputs).
        """
        with self.locked():
            meta = self.meta()
            head = int(meta.get("head", 0))
            state = meta.get("state", "authoring")
            if head == 0:
                raise StoreError("no-revision", "nothing has been published yet", 409)
            review = self.revision(head)
            schema.validate_submission_or_raise(submission, review)
            path = self.submission_path(submission["id"])
            if path.exists():
                stored = read_json(path)
                same = all(stored.get(k) == submission.get(k) for k in ("revision", "kind")) and stored.get("inputs") == submission.get("inputs")
                if not same:
                    raise StoreError("submission-conflict", "a different round was already stored under this id", 409, submission_id=submission["id"])
                stored["replayed"] = True
                return stored
            kind = submission.get("kind", "feedback")
            if state == "ended":
                raise StoreError("session-ended", "the session has ended; run /frev again for a fresh one", 409)
            if submission["revision"] != head:
                raise StoreError("stale-revision", f"the round targets revision {submission['revision']} but {head} is current; review the update, then Send again",
                                 409, head=head)
            if kind == "feedback" and state != "awaiting-user":
                raise StoreError("round-pending", "a round is already awaiting the commander; wait for the next revision", 409)
            if kind == "end" and state == "awaiting-commander" and submission.get("inputs"):
                raise StoreError("round-pending", "a round is awaiting the commander; End can only close (no new inputs) until it is answered", 409)
            self.submissions_dir.mkdir(exist_ok=True)
            seq = len(self.submissions()) + 1
            stored = {"id": submission["id"], "seq": seq, "kind": kind, "revision": head,
                      "inputs": submission.get("inputs", []), "client": submission.get("client"),
                      "received_at": now(), "notify": None}
            write_json_atomic(path, stored)
            changes = {"state": "ended" if kind == "end" else "awaiting-commander"}
            if kind == "end":
                changes["ended_at"] = stored["received_at"]
            self._update_meta(**changes)
            self.append_event("submission-received", submission_id=stored["id"], seq=seq, kind=kind,
                              revision=head, inputs=len(stored["inputs"]))
            return stored

    def record_notify(self, submission_id: str, result: dict) -> dict:
        """Attach the bridge's notify RESULT to the stored submission (append to its history)."""
        with self.locked():
            path = self.submission_path(submission_id)
            stored = self.submission(submission_id)
            entry = {"at": now(), **result}
            stored["notify"] = entry
            stored.setdefault("notify_history", []).append(entry)
            write_json_atomic(path, stored)
            self.append_event("notify", submission_id=submission_id, result=result.get("result"), code=result.get("code"))
            return stored

    def end(self, *, by: str = "commander") -> dict:
        """Close the session from the commander's side.  Rounds already sent stay owed."""
        with self.locked():
            meta = self.meta()
            if meta.get("state") == "ended":
                return meta
            meta = self._update_meta(state="ended", ended_at=now(), ended_by=by)
            self.append_event("session-ended", by=by)
            return meta

    # ------------------------------------------------------------ construction

    @classmethod
    def create(cls, *, namespace: str, root: dict, commander_runtime_id: str, snapshot, digest: str,
               socket_name=None, skill_dir=None, root_dir: Path | None = None) -> "Session":
        """A fresh session directory for ROOT (``{"id","name"}``); never reuses one."""
        base = (root_dir or data_root())
        check_segment(namespace, "namespace")
        check_segment(root["id"], "root id")
        parent = _mkdir_private(_mkdir_private(_mkdir_private(base) / namespace) / root["id"])
        for _ in range(5):
            sid = new_session_id()
            path = parent / sid
            try:
                path.mkdir(mode=0o700)
                break
            except FileExistsError:
                continue
        else:
            raise StoreError("session-id-collision", "could not allocate a fresh session id", 500)
        session = cls(path)
        write_json_atomic(session.meta_path, {
            "schema": SCHEMA, "id": sid, "namespace": namespace, "root": {"id": root["id"], "name": root.get("name")},
            "commander_runtime_id": commander_runtime_id, "socket_name": socket_name, "skill_dir": skill_dir,
            "created_at": now(), "observed_at": (snapshot or {}).get("observed-at") if isinstance(snapshot, dict) else None,
            "state": "authoring", "head": 0, "ended_at": None,
        })
        write_json_atomic(session.path / "snapshot.json", snapshot)
        (session.path / "digest.md").write_text(digest, encoding="utf-8")
        os.chmod(session.path / "digest.md", 0o600)
        session.append_event("session-created", root=root.get("name"), commander_runtime_id=commander_runtime_id)
        return session

    @classmethod
    def open(cls, path) -> "Session":
        """Open an existing session directory; it must lie under the data root."""
        candidate = Path(path).expanduser()
        if not candidate.is_dir():
            raise StoreError("session-missing", "session directory does not exist", 404, path=str(path))
        real = candidate.resolve()
        root = data_root()
        if root not in real.parents:
            raise StoreError("session-outside-data-root", "session directory is not under the frev data root", 404,
                             path=str(real), root=str(root))
        session = cls(real)
        session.meta()
        return session

    @classmethod
    def resolve(cls, namespace: str, root_id: str, session_id: str) -> "Session":
        """Open ``<data root>/<namespace>/<root_id>/<session_id>`` after validating every segment."""
        for value, what in ((namespace, "namespace"), (root_id, "root id"), (session_id, "session id")):
            check_segment(value, what)
        return cls.open(data_root() / namespace / root_id / session_id)


def url_path(session: Session) -> str:
    meta = session.meta()
    return f"/s/{meta['namespace']}/{meta['root']['id']}/{meta['id']}/"


def render_digest(bearings: dict) -> str:
    """Short Markdown digest of a ``fleet-read-bearings`` result, for the authoring commander.

    Facts only, no judgement: members, their tasks with phase/detail, open
    decisions with authority, waits, artifacts, diagnostics.
    """
    if not isinstance(bearings, dict):
        return "_no evidence_\n"
    root = bearings.get("root") or {}
    lines = [f"# Evidence — fleet `{root.get('name')}` observed {bearings.get('observed-at')}", ""]
    caller = bearings.get("caller") or {}
    if caller.get("current-commander-p") is not True and caller.get("runtime-id"):
        lines.append(f"> Caller runtime {caller.get('runtime-id')} is not the root's current commander runtime.")
        lines.append("")
    for m in bearings.get("members") or []:
        role = "commander" if m.get("role") == "root" else "lieutenant"
        lines.append(f"## {m.get('selector')} ({role}) — {m.get('status')}")
        if m.get("status") != "observed":
            if m.get("error"):
                lines.append(f"- read failed: {m['error']}")
            lines.append("")
            continue
        c = m.get("commander") or {}
        lines.append(f"- session: {m.get('commander-label') or c.get('lifecycle') or 'none'}; fleet lifecycle {m.get('lifecycle')}; "
                     f"supervision {'on' if m.get('supervision') else 'paused'}; pending events {m.get('pending-events', 0)}")
        if m.get("charter"):
            lines.append(f"- charter: {m['charter']}")
        for r in m.get("open-requests") or []:
            lines.append(f"- open request `{r.get('id')}`: {r.get('subject')} ({r.get('state')})")
        tasks = m.get("tasks") or []
        if not tasks:
            lines.append("- tasks: none")
        for t in tasks:
            rt = t.get("runtime") or {}
            derived = (t.get("derived") or {}).get("state")
            bits = [f"lifecycle {t.get('lifecycle')}", f"phase {t.get('phase')}"]
            if derived:
                bits.append(f"dashboard {derived}")
            if rt:
                bits.append(f"runtime {rt.get('lifecycle')}/{rt.get('turn-state')}" + (f" tool {rt.get('active-tool')}" if rt.get("active-tool") else ""))
            if t.get("newer-instructions"):
                bits.append(f"{t['newer-instructions']} newer instruction(s) sent")
            lines.append(f"- task `{t.get('name')}` ({t.get('kind')}, id {t.get('id')}): " + ", ".join(bits))
            if t.get("detail"):
                lines.append(f"    - status: {t['detail']}")
            w = t.get("wait")
            if w:
                lines.append(f"    - wait: {w.get('reason')} until {w.get('deadline')}")
            for d in t.get("decisions") or []:
                lines.append(f"    - decision `{d.get('id')}` ({d.get('state')}, authority {d.get('authority')}): {d.get('question')}")
            for a in t.get("artifacts") or []:
                lines.append(f"    - artifact {a.get('kind')}: {a.get('ref')}{' (verified)' if a.get('verified') else ''}")
            for j in t.get("external-jobs") or []:
                lines.append(f"    - external job {j.get('system')} {j.get('state')}: {j.get('ref')}")
            for op in t.get("failed-operations") or []:
                lines.append(f"    - failed operation: {op}")
        lines.append("")
    diags = bearings.get("diagnostics") or []
    if diags:
        lines.append("## Coverage")
        lines.extend(f"- {d}" for d in diags)
        lines.append("")
    return "\n".join(lines)
