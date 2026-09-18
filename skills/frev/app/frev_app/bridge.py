"""Calls into the running Fleet owner Emacs through ``emacsclient``.

Two calls only, both defined in ``scripts/frev.el``: ``frev-collect-to-file``
(read-only evidence) and ``frev-notify-to-file`` (the fixed notice on Send).
Results travel through a private temp file as JSON, never by parsing
``emacsclient``'s printed string literal.  Arguments are passed as argv; no
shell.  ``FREV_EMACSCLIENT`` names an alternative executable (tests point it at
a spy).
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parent.parent.parent
"""skills/frev — resolved through symlinks so the Elisp file path is the checkout's."""

COLLECT_TIMEOUT = 60
NOTIFY_TIMEOUT = 30


class BridgeError(Exception):
    def __init__(self, code: str, message: str, **evidence):
        super().__init__(message)
        self.code = code
        self.evidence = evidence

    def to_dict(self) -> dict:
        return {"ok": False, "code": self.code, "message": str(self), **self.evidence}


def elisp_string(value: str) -> str:
    """VALUE as an Elisp string literal."""
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def emacsclient_argv(socket_name: str | None = None) -> list:
    argv = [os.environ.get("FREV_EMACSCLIENT") or "emacsclient", "--alternate-editor=false"]
    if socket_name:
        argv += ["--socket-name", socket_name]
    return argv


def _bridge_file(skill_dir: Path | None = None) -> Path:
    return (Path(skill_dir) if skill_dir else SKILL_DIR) / "scripts" / "frev.el"


def _eval(form: str, socket_name: str | None, timeout: int, skill_dir: Path | None = None) -> dict:
    """Run FORM (which must write its JSON result to the placeholder OUT) and return that JSON."""
    fd, out = tempfile.mkstemp(prefix="frev-bridge-", suffix=".json")
    os.close(fd)
    try:
        loader = f"(unless (featurep 'frev) (load {elisp_string(str(_bridge_file(skill_dir)))} nil t))"
        expr = f"(progn {loader} {form.replace('OUT', elisp_string(out))})"
        try:
            proc = subprocess.run(emacsclient_argv(socket_name) + ["--eval", expr], capture_output=True, text=True, timeout=timeout)
        except FileNotFoundError as e:
            raise BridgeError("emacsclient-missing", f"emacsclient not found: {e}")
        except subprocess.TimeoutExpired:
            raise BridgeError("emacsclient-timeout", f"emacsclient did not answer within {timeout}s")
        if proc.returncode != 0:
            raise BridgeError("emacsclient-failed", (proc.stderr or proc.stdout or "").strip()[:500] or f"exit {proc.returncode}")
        try:
            with open(out, encoding="utf-8") as fh:
                text = fh.read()
            if not text.strip():
                raise BridgeError("bridge-no-result", f"emacsclient returned {proc.stdout.strip()!r} but wrote no result")
            return json.loads(text)
        except json.JSONDecodeError as e:
            raise BridgeError("bridge-bad-result", f"bridge wrote invalid JSON: {e}")
    finally:
        try:
            os.unlink(out)
        except OSError:
            pass


def collect(*, fleet_id: str | None, runtime_id: str | None, selector: str | None = None,
            socket_name: str | None = None, skill_dir: Path | None = None) -> dict:
    """Fresh read-only evidence (``frev-collect``) for the session identity given."""
    args = []
    if fleet_id:
        args.append(f":session-fleet-id {elisp_string(fleet_id)}")
    if runtime_id:
        args.append(f":runtime-id {elisp_string(runtime_id)}")
    if selector:
        args.append(f":selector {elisp_string(selector)}")
    result = _eval(f"(frev-collect-to-file OUT {' '.join(args)})", socket_name, COLLECT_TIMEOUT, skill_dir)
    if not result.get("ok"):
        raise BridgeError(result.get("code", "collect-failed"), result.get("message", "collect failed"))
    return result


def notify(session_dir: Path, submission_id: str, *, socket_name: str | None = None, skill_dir: Path | None = None) -> dict:
    """Queue the notice for SUBMISSION_ID of SESSION_DIR.  Never raises for a refusal.

    Returns a dict with ``result`` in ``queued``/``replayed``/``refused``/``failed``
    plus ``code``/``reason`` when not queued.  The browser shows this verbatim.
    """
    try:
        result = _eval(f"(frev-notify-to-file OUT {elisp_string(str(session_dir))} {elisp_string(submission_id)})",
                       socket_name, NOTIFY_TIMEOUT, skill_dir)
    except BridgeError as e:
        return {"result": "failed", "code": e.code, "reason": str(e)}
    if not result.get("ok"):
        return {"result": "failed", "code": result.get("code", "bridge-error"), "reason": result.get("message", "")}
    out = {k: v for k, v in result.items() if k != "ok"}
    out.setdefault("result", "failed")
    return out


def open_browser(url: str, *, socket_name: str | None = None) -> bool:
    """Ask the owner's Emacs to browse URL (``browse-url``); fall back to ``xdg-open``."""
    if os.environ.get("FREV_NO_BROWSER"):
        return False
    try:
        proc = subprocess.run(emacsclient_argv(socket_name) + ["--eval", f"(progn (browse-url {elisp_string(url)}) t)"],
                              capture_output=True, text=True, timeout=15)
        if proc.returncode == 0:
            return True
    except (OSError, subprocess.TimeoutExpired):
        pass
    try:
        subprocess.Popen(["xdg-open", url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        return True
    except OSError:
        return False
