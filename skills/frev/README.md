# frev skill

Fresh executive review of a Fleet in the browser: the root commander collects evidence (through the
`fsum` reader), authors a compact structured review, and the user works through it on a loopback web
page — choices, comments, messages, **Send round** — which automatically queues a short notice on the
commander's runtime. `SKILL.md` is the ECA skill (the commander's loop); this file covers layout,
installation, tests, and the honest limits of the notify hop.

## Layout

| Path | Role |
|---|---|
| `SKILL.md` | ECA skill loaded by the root commander |
| `scripts/frev.el` | Emacs bridge: `frev-collect-to-file` (evidence via fsum's `fleet-read.el`, plus the data-root namespace), `frev-notify-to-file` (fixed-format notice through `fleet-supervisor-send`) and `frev-result-review-to-file` / `frev-result-apply-to-file` (deep unresolved-result pass and the only write path into fsum's `fleet-result.el` checkpoint) |
| `app/frev.py` | CLI entry: `start`, `publish`, `status`, `end`, `validate`, `example`, `serve`, `server status|stop` |
| `app/frev_app/schema.py` | Review/submission shapes (v1) and validation; the example review |
| `app/frev_app/store.py` | Session directories, atomic writes, `flock`, publish/submit state machine, evidence digest |
| `app/frev_app/bridge.py` | `emacsclient` calls (argv only; results through a temp file) and `browse-url` |
| `app/frev_app/server.py` | Loopback `ThreadingHTTPServer`, routes, security headers, server records and owned stop |
| `app/static/` | `index.html`, `app.css`, `app.js`, `md.js` (safe Markdown → DOM via `textContent`) |
| `test/` | `frev-tests.el` (ERT, faked store, send spy), `test_*.py` (unittest), `md.test.mjs` (node), `ui_cdp.mjs` (headless Chromium sequence) |

## How it fits together

```
/frev ──► frev.py start ──emacsclient──► frev.el ──► fleet-read-bearings (fsum)   read-only
              │                                          (owner Emacs, open store)
              ▼
        <data>/frev/<ns>/<root-uuid>/<session>/   session.json snapshot.json digest.md
              │                                    revisions/0001.json …  submissions/<id>.json  events.jsonl
frev.py publish ──► validates, writes revision, ensures loopback server, browse-url
              │
        browser ◄──── http://127.0.0.1:PORT/s/<ns>/<root>/<session>/  (poll /state every 5 s + on focus)
              │  Send round
              ▼
        POST /submit ──► persist submission ──emacsclient──► frev-notify-to-file ──► fleet-supervisor-send
                                                             (bound runtime, idempotency key = submission)
commander ◄── one notice on its lane ──► frev.py status … ──► normal Fleet tools ──► frev.py publish (dispositions)
```

- **Namespace** `<ns>` is `(fleet-paths-root-hash)` — a short hash of Fleet's data root — so two Fleet
  data roots on one machine never share sessions or servers.
- **Sessions are files.** No database; the CLI (commander) and the server (browser) share a session
  through atomic writes under a per-session `flock`. No lock is held across `emacsclient`.
- **One server per namespace**, loopback only, OS-assigned port, recorded in
  `$XDG_RUNTIME_DIR/frev/<ns>/server.json` with a random instance id. Reuse and stop verify the record
  against `GET /api/ping`; a port answered by anything else is *foreign* and is never reused or killed.
  Ending a session does not stop the server; `frev.py server stop` does, only for a verified own instance.
- **Endpoints:** `GET /api/ping`, the UI, `/static/*`, `GET …/session|state|revision/N`,
  `POST …/submit`, `POST …/notify/<id>` (retry). No execute, eval or Fleet-mutation route exists.
- **Fresh only.** Every `start` allocates a new directory. Nothing resumes, migrates or supersedes.
- **Unresolved results are the exception to "fresh only", and they are not session files.** They live in
  the shared checkpoint `$XDG_DATA_HOME/fleet-result-review/<ns>/<root-uuid>/`, owned by fsum's
  `fleet-result.el` and keyed by root fleet, so they outlive both the session and the commander.
  `frev-result-review-to-file` reads it and scans every retained commander transcript incrementally
  (5 MiB / 500 turns per pass, per-file cursors); `frev-result-apply-to-file` is the **only** way a
  `/frev` adjudication reaches it. The Python app and the browser never write it: they carry the user's
  picks and words to the commander, which decides what each means and states it through Emacs
  (`AGENTS.md`: *Emacs alone writes state*). Cursors are committed only together with an adjudication,
  so an unreviewed candidate is re-offered rather than skipped.

## Install (owner step, separate from merging)

Skills on this host are symlinks into a checkout. `frev` needs `fsum` next to it (it loads
`../fsum/scripts/fleet-read.el` and `../fsum/scripts/fleet-result.el`, resolved first beside the
checkout, then beside the install):

```bash
ln -s ~/development/fleet/skills/fsum ~/.config/eca/skills/fsum   # if not already
ln -s ~/development/fleet/skills/frev ~/.config/eca/skills/frev
```

ECA discovers `SKILL.md` on its next skill scan; a running commander sees a new skill only after its
skills are reloaded (a new commander boot does). Python 3.10+ (standard library only) and `emacsclient`
must be on `PATH`. The browser is opened through the owner's Emacs (`browse-url`), with `xdg-open` as the
fallback; `FREV_NO_BROWSER=1` disables opening (tests).

Storage: `$XDG_DATA_HOME/frev/` (default `~/.local/share/frev/`), 0700 directories, 0600 files. Server
records: `$XDG_RUNTIME_DIR/frev/`. Overrides for tests: `FREV_DATA_ROOT`, `FREV_RUNTIME_ROOT`,
`FREV_EMACSCLIENT`.

## Notify: what the Send hop does and does not do

`frev-notify` refuses to queue (the round stays saved; the browser shows why and offers **Retry notify**):

| Refusal | Check | Why |
|---|---|---|
| `commander-replaced` | root's `commander-runtime-id` ≠ the runtime bound at `start` | Never notify a successor from a stale session; the user runs `/frev` again |
| `fleet-not-active` | fleet lifecycle ≠ `active` (parked, parking, retiring, archived) | Don't yell while parked |
| `runtime-not-ready` | runtime lifecycle ≠ `ready` | Nothing restarts a commander implicitly |
| `human-draft` | `fleet-eca-draft` non-empty on the commander's chat | Don't clobber someone typing |
| `session-outside-data-root` / `invalid-submission-id` / `submission-missing` | path and id containment | The notice is built from files the bridge validated, never from browser text |

What it deliberately does **not** do — it is a message on the commander's lane, not
`fleet-supervisor-wake-admission`:

- **Lane busy / pending native prompt / queued messages:** the notice is queued and Fleet's lane delivers it
  when the lane frees; `fleet-supervisor--dispatch-lane` already refuses to prompt over a pending
  question/approval. The browser reports "commander is notified (message queued)"; delivery may lag.
- **Supervision (watch) paused** is a warning in the result, not a refusal: a Send is a user action.
- **No retry loop, no respawn, no repair.** `fleet-supervisor-send` may itself refuse
  (`runtime-not-ready`, `no-such-runtime`); that becomes `send-failed`. Delivery states (`queued`,
  `accepted`, `delivery-unknown`, …) are Fleet's; `status` shows the message id and state at queue time only.
- Idempotency key `frev:<session>:<submission>` and sender `frev`: an exact resend of the same round
  replays the same message row rather than queuing a second notice.

## Browser keys and states

| Where | Key / control | Effect |
|---|---|---|
| Composer | `Enter` | Queue the text as a **message** (not sent yet) |
| Composer | `Shift+Enter` | Newline |
| Composer / anywhere in it | `Ctrl+Enter` / `⌘+Enter` | **Send round**: queued items plus non-empty composer text |
| Item | option button | Queue a pick (one per choice; clicking the picked option again removes it) |
| Item | **Comment** → editor | `Enter` queues the comment anchored to the item; `Esc` closes |
| Rail | `✕` on a queued item / **Clear** | Remove before sending |
| Rail | **Send round (N)** | Same as `Ctrl+Enter` |
| Rail | **End session** | Confirm dialog; sends queued items with the closure when the commander is not mid-round |
| Top bar | **Check for updates** | Re-read this session's state now (no model call); the page also polls every 5 s and on focus |
| Top bar | `◐` | Theme auto → light → dark (remembered) |
| Top bar | **Rail** | Hide/show the conversation rail |

Badge states: `Your turn` · `Draft · N queued, not sent` · `Sending…` · `Sent · awaiting commander` ·
`Session ended`; a toast announces `Updated: the commander published revision N`. Under the queue, a line
says whether the last round was delivered to Fleet or why the notice was held, with **Retry notify**.

Drafts (queue, composer text, open comment editors, an unconfirmed outbox) live in `localStorage` per
session and survive reload; a round prepared before a lost server answer is retried with the **same
submission id** (the server replays the receipt instead of storing a duplicate). A round against an older
revision is refused (`stale-revision`) and the queue is kept for the user to re-check.

## Tests

Python and node tests need no Emacs and no fleet; run them from anywhere:

```bash
cd ~/development/fleet/skills/frev
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -B -m unittest discover -s test -p 'test_*.py' -v
node --test test/md.test.mjs
```

`test_ui.py` drives headless Chromium through pick → queue → reload → send with `test/ui_cdp.mjs`
(Node ≥ 22's built-in WebSocket; skipped when `chromium` or `node` is missing; `FREV_CHROMIUM` names another
binary). The spawned-server test starts a real `frev.py serve` under temp roots and stops it through the
verified-owner path. Screenshots land in the temp dir; for a keepable set run
`node test/ui_cdp.mjs URL DIR` against a session you published.

ERT (the Emacs bridge) runs in a **disposable** Emacs server only — never the editing server, never with
owner fleets (see `docs/testing.md`; convention `emacs -Q --daemon=fleet-test`, started by the owner):

```bash
timeout 120 emacsclient --alternate-editor=false --socket-name=fleet-test --eval '
(progn
  (load "/home/avelazqu/development/fleet/skills/frev/test/frev-tests.el" nil t)
  (let ((stats (ert-run-tests-batch "^frev-test-")))
    (format "PASSED %d FAILED %d SKIPPED %d TOTAL %d"
            (ert-stats-completed-expected stats) (ert-stats-completed-unexpected stats)
            (ert-stats-skipped stats) (ert-stats-total stats))))'
```

The suite fakes `fleet-store-get`, `fleet-supervisor-send` (spy), `fleet-eca-conn`/`fleet-eca-draft` and
`fleet-paths-root-hash`, arms a mutation denylist, and uses a temp frev data root. It covers the fixed
target/key/text of the notice, every refusal, path containment, the file protocol, and that the reader is
found beside `fsum`. Do not chain a `byte-compile-file` into the same eval as a test run on a shared daemon.

## Manual UX checklist (for the reviewer)

1. `/frev` in the root commander → digest printed → review authored → `publish` opens the page.
2. Needs-you first: an item with choices and a done item with an `attention` ask both appear at the top.
3. Click an option: it shows as picked; the rail shows `PICK …`; badge `Draft · 1 queued, not sent`.
4. Type a message, press `Enter`: it moves to the queue; composer clears; toast says how to send.
5. Comment on the second item, `Enter`: queued with its anchor; `Esc` closes an open editor.
6. Reload: queue and half-typed composer text are still there.
7. `Ctrl+Enter`: badge `Sent · awaiting commander`; the round appears as a blue bubble; Send is disabled;
   the notify line reads "delivered to Fleet: the commander is notified".
8. In the commander's chat: the `## /frev round …` notice arrives without the user typing anything.
9. Commander runs `status`, publishes revision 2 with dispositions → within 5 s the page shows
   `Updated: … revision 2`, disposition tags next to each input, the commander's note in the rail.
10. Park the fleet (dashboard `X`) and Send again → notify line says held (`fleet-not-active`) with
    **Retry notify**; resume, retry → delivered.
11. End session → confirm → badge `Session ended`; a `(end)` notice reaches the commander.
12. Toggle theme; narrow the window below 900 px: the rail stacks under the report.

## Caveats

- One meeting per `/frev`; no supersession graph, historical pins, multi-tab merging or export bundle.
  Duplicate tabs share the same `localStorage` draft; the last writer wins (no loss of sent rounds).
- Human-only decisions are recorded as dispositions, not resolved: Fleet refuses commander resolution
  (known gap F08). Say so in the disposition.
- The notice is a hint that a round exists; the session files are the truth. A late or lost notice never
  loses a round: `status` shows every pending submission.
- Server records are per data-root namespace; a foreign port owner is reported, not fought.
