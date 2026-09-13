# Fleet quickstart

Fleet is a persistent Emacs-native workspace for delegating project work to a team of ECA agents: one
**commander** per fleet talks to you; **operators** each do one task in their own native ECA chat and
systemd-owned process; **Emacs** owns state, scheduling and the dashboard.

## Prerequisites and install

1. An ordinary native ECA chat already works in your Emacs (`M-x eca`), `systemctl --user` works, and Emacs
   was built with SQLite (`(sqlite-available-p)` → `t`). Python 3.11+ at `/usr/bin/python3`, Git.
2. Fleet lives at `~/development/fleet`. Load it from the source tree with `use-package` (no copy or
   symlink under `~/.emacs.d/lisp`; edits are live after a reload). `C-c h f` is your binding, Fleet never
   installs one itself:

   ```elisp
   (use-package fleet
     :load-path "~/development/fleet/lisp"
     :after eca
     :commands (fleet-dashboard fleet-new fleet-park fleet-task-close fleet-destroy fleet-doctor
                fleet-watch-start fleet-watch-stop
                fleet-commander-stop fleet-commander-replace fleet-commander-set-model
                fleet-install-mcp)
     :bind (("C-c h f" . fleet-dashboard))
     :custom
     (fleet-development-root "~/development")       ; worktrees go to <root>/.worktrees
     ;; only if discovery cannot find the native executable / you want fixed models:
     ;; (fleet-eca-command '("/home/you/.emacs.d/eca/eca" "server"))
     ;; (fleet-commander-model "openai/gpt-5") (fleet-operator-model "openai/gpt-5")
     ;; (fleet-commander-variant "high") (fleet-operator-variant "medium")
     )
   ```

   **Models.** Without any of the above, commanders and operators run on the ECA default model. Once one
   Fleet runtime has started, Fleet knows ECA's model catalog: `M-x fleet-new` then offers completion for the
   commander's model and variant (accept the default with RET) — both when creating a fleet and whenever it
   starts a commander for an existing one (resume, or a fleet whose commander was stopped), where RET keeps
   the fleet's current pin. `M-x fleet-commander-replace` asks the same question, so switching a running
   fleet to another model is: replace, pick the model. `M-x fleet-commander-set-model` changes the pin
   without starting anything (it applies at the next commander start). You can steer operators per task just by
   telling the commander — "do this on gpt 5.6 terra medium", "study tasks on a cheap model" (put standing
   policy in the fleet's `about.md`). The commander resolves casual names against the catalog and Fleet refuses
   ids that are not in it. The dashboard shows each runtime's model next to the commander status and in the
   task rows (provider prefix dropped; `v` peek shows the full id).

3. (Optional) Fleet runtimes receive the Fleet MCP bridge automatically through a per-runtime `ECA_CONFIG` overlay;
   your `~/.config/eca/config.json` is not modified. `M-x fleet-install-mcp` can additionally merge the one
   entry into your global config (with a backup and a diff you confirm) if you want it visible there. Fleet
   never enables blanket trust; your `toolCall.approval` policy stays yours.

   **Approvals.** ECA always asks before a native file or shell tool touches a path outside the session's
   workspace roots, regardless of `toolCall.approval` (`allow` rules cannot override that built-in check).
   Fleet sets each runtime's roots to what its brief covers (task directory plus the studied repository or
   the change worktree; the fleet directory for the commander), so a well-scoped operator rarely prompts.
   When it does, only you can answer: in the operator's chat (`C-c C-a`, or `C-c C-y` to remember for the
   session), or by running operators in trust mode. Trust follows your normal ECA settings — Fleet chats
   honor `eca-chat-trust-enable` / `C-c C-t` like any other chat, and the server-side
   `"chat": {"defaultTrust": true}` in `~/.config/eca/config.json` makes every new chat trusted. The
   commander is not woken for approvals; the dashboard shows them as attention.
4. `M-x fleet-doctor`. Fix anything marked `✗` (ECA not loadable/found, missing SQLite/systemd, unsafe
   runtime dir, stale owner) before unattended work.

## M-x reference

| Command | When |
|---|---|
| `fleet-dashboard` | Show the live grouped view; starts Fleet in this Emacs (owner, or read-only if another Emacs owns the data root). `C-c h f` if you bound it. |
| `fleet-new` | Create a named fleet and its commander, or resume/visit an existing one. A live commander is visited, never duplicated. A parked fleet asks *resume* vs *visit only*. |
| `fleet-park` | Stop every operator with verified service evidence; keep the commander and all durable work. Confirms with live-operator/tool/external-job counts. |
| `fleet-task-close` | Archive one task on your authority, without the teardown evidence gate: failed or abandoned work, or done work that can no longer be verified. Needs a reason, a stopped operator (park first) and, for change tasks, an already-removed worktree. Nothing is deleted. |
| `fleet-destroy` | Retire an **empty** fleet (all tasks archived): archive-move its artifact tree and release the name. No dashboard key, no commander tool. |
| `fleet-watch-start` / `fleet-watch-stop` | Enable / pause automatic commander wakes for a fleet. Pausing never stops processes or event recording. |
| `fleet-doctor` | Compatibility, ownership, storage, runtime and unit evidence. Read-only. |
| `fleet-commander-stop` | Verified stop of the commander only; operators keep running. |
| `fleet-commander-replace` | Verified stop, then a fresh commander booted with the durable snapshot and `commander/context.md`. Offers to change the commander's model/variant first. |
| `fleet-commander-set-model` | Pin the model/variant the fleet's *next* commander launches with (RET keeps the current one). A live commander is untouched. |
| `fleet-install-mcp` | Optional: merge the single Fleet MCP entry into ECA's global config with backup + diff. |
| `fleet-timeline` / `fleet-stats` | Retrospective telemetry for a fleet: chronological events with event→wake/ack latencies; counts of tool calls and refusals, turn durations, tokens/cost, operation durations. Read-only; works on archived fleets too. |

## Dashboard keys

Buffer `fleet:*`. Rows: `glyph task state·source kind repo age detail`. Sorted alphabetically; urgency comes
from `a`, not reordering.

| Key | Action |
|---|---|
| `n` / `p` | next / previous entry (fleet headers included); no wrap. `p` is *previous*, not peek. |
| `N` / `P` | next / previous fleet header |
| `j` | jump to a fleet by name |
| `a` | next entry needing you (decision, blocked, failed, dead, unknown, stop/delivery problems); wraps. If only the commander has a problem, its header. |
| `RET` | header → the commander's real ECA chat; task → the operator's chat. Unavailable sessions show recovery info and the retained transcript, never an empty new chat. |
| `v` (also `?`) | read-only peek: last 40 lines, in `fleet-peek*` |
| `s` | one minibuffer message to the commander (header) or operator (task). Shows queued/accepted/unknown truthfully. If the target has a pending question, `s` answers exactly that question. |
| `i` | operator only: request cancellation of the current turn (confirm). Requested ≠ stopped. |
| `t` | operator only: normal teardown with the full evidence gate (confirm) |
| `b` / `r` | view brief / report read-only (`view-mode`; `q` leaves, `e` edits — editing does not change dispatched scope) |
| `w` | dired into the task's worktree (change tasks with an existing worktree) |
| `X` | park the fleet at point (same confirmation as `M-x fleet-park`) |
| `g` | refresh (no mutation) |
| `q` | bury the dashboard; stops nothing |

There is deliberately no drain, kill, or destroy key.

States: `working·eca` (server says a turn is running), `working·status` (operator's last status, idle now),
`decision` (question, permission, or needs-decision), `paused` (declared wait), `blocked`, `failed`,
`done`, `dead` (connection lost, service not proven stopped), `unknown` (no execution evidence or stop
verdict unknown), `suspended`/`stopping` (parked/parking).

## First project

`M-x fleet-dashboard`, then `M-x fleet-new` → `myproj` → confirm. The commander's chat opens once the
native server is ready and booted with the canonical doctrine, your fleet's `about.md`, and the current
snapshot. Tell it what to achieve, which repository (under `~/development`), and the delivery mode
(`remote-review` pull request, `local-ready` branch, or explicitly `integrated`). Operators start silently
in the background; watch them on the dashboard.

## During the day

`a` for decisions and failures, `v` for a quick look, `RET` for the real conversation, `b`/`r` for the
brief and report, `w` for the files. Send scope changes to the commander. Use `s` for short answers and `i`
only after `v` tells you what would be interrupted. A pending native permission prompt is answered in the
operator's own chat (`RET`), not by a message.

## When a task finishes

The operator publishes `done` with registered artifacts; the commander verifies the actual files/branch and
requests teardown — or you press `t`. Teardown proves the runtime stopped, collects one Git evidence pass
and removes **only** a clean, Fleet-owned, preserved worktree with `git worktree remove`. A refusal lists
the HEAD/branch, dirtiness, remote/target OIDs, preservation/integration verdicts and retained refs. Pushed
means *preserved*, not merged. "branch retained" is a warning, not a failure. Adopted worktrees and
branches are never removed. Fleet never `rm -rf`s or `branch -D`s anything.

## End of day / week

On the fleet header press `X`, confirm, and wait for the header to read **parked** (not *parking*). Review
any external jobs it lists as still running. Use the still-live commander to write a handoff in
`commander/context.md`, then `M-x fleet-commander-stop` and wait for the verified stop. Hiding or killing a
chat buffer is not a shutdown (Fleet refuses to kill live Fleet chats and buries them instead). Worktrees,
briefs, reports, transcripts and events remain under `~/.local/share/fleet/`.

## Resume / Emacs restart

`M-x fleet-dashboard` reconciles every recorded runtime against its exact systemd unit first (stopping
survivors, suspending their tasks). `M-x fleet-new` → existing name → *resume*. A fresh commander boots with
a deterministic recovery summary and your handoff note and may start unfinished tasks under their existing
scope. Done tasks are verified/finalized, not rerun. Held messages are re-queued; attempted/unknown ones are
reconciled, never resent.

## Commander context exhausted

Ask it to write `commander/context.md`, then `M-x fleet-commander-replace`. Never create a second live
commander by renaming a buffer.

## Mistyped name / finished fleet

Tear down every task (or `M-x fleet-task-close` the ones teardown will never admit), then
`M-x fleet-destroy`. The name is reusable after the archive commits.

## Troubleshooting

- **queued / accepted / delivery-unknown**: queued = durable in Fleet, not sent; accepted = the server
  responded `prompting`; delivery-unknown = neither response nor execution evidence within the bound. Fleet
  never resends unknown text; inspect the chat (`RET`) and the operation in `fleet-doctor`.
- **cancellation requested vs stopped**: `i` asks the server to stop; only a systemd verdict proves a stop.
- **stays parking**: some service could not be proven stopped. `fleet-doctor` prints the unit and verdict;
  `systemctl --user status <unit>`; never `rm` the lock or worktree directories by guesswork.
- **adopted workspace retained**: by design; dirty content is reported as left in place.
- **`ECA` marked ✗ in fleet-doctor**: the frontend lost a symbol Fleet uses (or eca is not installed); see
  `docs/eca-compatibility.md`; read-only inspection still works.
- **outstanding permission/question**: shown as `decision`; answer it in the chat (`RET`) or with `s`.
- **stale owner**: another Emacs (or a crashed one) holds `owner.json`. If that Emacs is truly gone, Fleet
  takes over automatically (pid + start time are checked); if it is alive, act there.
- **external jobs**: park lists them; Fleet cannot stop what it did not start.

Evidence lives in `~/.local/share/fleet/fleets/<uuid>/…/runs/<runtime>/{launch.json,transcript.jsonl}`,
the `operations` table (`fleet-doctor`), and `journalctl --user -u fleet-eca-<uuid>.service`. For a
retrospective, `M-x fleet-timeline` and `M-x fleet-stats` read the durable record: every tool call (with
outcome/refusal code and duration), every finished turn (duration, tokens, cost), and wake/ack latencies per
actionable event. The raw tables are plain SQLite (`sqlite3 ~/.local/share/fleet/fleet.sqlite3`).
