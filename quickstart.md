# Fleet quickstart

Fleet is a persistent Emacs-native workspace for delegating project work to a team of ECA agents: one
**commander** per fleet talks to you; **operators** each do one task in their own native ECA chat and
systemd-owned process; **Emacs** owns state, scheduling and the dashboard.

## Prerequisites and install

1. An ordinary native ECA chat already works in your Emacs (`M-x eca`), `systemctl --user` works, and Emacs
   was built with SQLite (`(sqlite-available-p)` → `t`). Python 3.11+ at `/usr/bin/python3`, Git.
2. Fleet lives at `~/development/fleet`. Minimal configuration:

   ```elisp
   (add-to-list 'load-path "~/development/fleet/lisp")
   (require 'fleet)
   ;; only if your clones do not live under ~/development:
   ;; (setq fleet-development-root "~/src")          ; worktrees go to <root>/.worktrees
   ;; only if discovery cannot find the native executable / you want fixed models:
   ;; (setq fleet-eca-command '("/home/you/.emacs.d/eca/eca" "server"))
   ;; (setq fleet-commander-model "openai/gpt-5" fleet-operator-model "openai/gpt-5")
   (global-set-key (kbd "C-c h f") #'fleet-dashboard)   ; optional; Fleet never binds it itself
   ```

3. Fleet runtimes receive the Fleet MCP bridge automatically through a per-runtime `ECA_CONFIG` overlay;
   your `~/.config/eca/config.json` is not modified. `M-x fleet-install-mcp` can additionally merge the one
   entry into your global config (with a backup and a diff you confirm) if you want it visible there. Fleet
   never enables blanket trust; your `toolCall.approval` policy stays yours.
4. `M-x fleet-doctor`. Fix anything marked `✗` (unsupported ECA pair, missing SQLite/systemd, unsafe
   runtime dir, stale owner) before unattended work.

## M-x reference

| Command | When |
|---|---|
| `fleet-dashboard` | Show the live grouped view; starts Fleet in this Emacs (owner, or read-only if another Emacs owns the data root). `C-c h f` if you bound it. |
| `fleet-new` | Create a named fleet and its commander, or resume/visit an existing one. A live commander is visited, never duplicated. A parked fleet asks *resume* vs *visit only*. |
| `fleet-park` | Stop every operator with verified service evidence; keep the commander and all durable work. Confirms with live-operator/tool/external-job counts. |
| `fleet-destroy` | Retire an **empty** fleet (all tasks archived): archive-move its artifact tree and release the name. No dashboard key, no commander tool. |
| `fleet-watch-start` / `fleet-watch-stop` | Enable / pause automatic commander wakes for a fleet. Pausing never stops processes or event recording. |
| `fleet-doctor` | Compatibility, ownership, storage, runtime and unit evidence. Read-only. |
| `fleet-commander-stop` | Verified stop of the commander only; operators keep running. |
| `fleet-commander-replace` | Verified stop, then a fresh commander booted with the durable snapshot and `commander/context.md`. |
| `fleet-install-mcp` | Optional: merge the single Fleet MCP entry into ECA's global config with backup + diff. |

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

Tear down or close every task, then `M-x fleet-destroy`. The name is reusable after the archive commits.

## Troubleshooting

- **queued / accepted / delivery-unknown**: queued = durable in Fleet, not sent; accepted = the server
  responded `prompting`; delivery-unknown = neither response nor execution evidence within the bound. Fleet
  never resends unknown text; inspect the chat (`RET`) and the operation in `fleet-doctor`.
- **cancellation requested vs stopped**: `i` asks the server to stop; only a systemd verdict proves a stop.
- **stays parking**: some service could not be proven stopped. `fleet-doctor` prints the unit and verdict;
  `systemctl --user status <unit>`; never `rm` the lock or worktree directories by guesswork.
- **adopted workspace retained**: by design; dirty content is reported as left in place.
- **unsupported ECA pair**: see `docs/eca-compatibility.md`; read-only inspection still works.
- **outstanding permission/question**: shown as `decision`; answer it in the chat (`RET`) or with `s`.
- **stale owner**: another Emacs (or a crashed one) holds `owner.json`. If that Emacs is truly gone, Fleet
  takes over automatically (pid + start time are checked); if it is alive, act there.
- **external jobs**: park lists them; Fleet cannot stop what it did not start.

Evidence lives in `~/.local/share/fleet/fleets/<uuid>/…/runs/<runtime>/{launch.json,transcript.jsonl}`,
the `operations` table (`fleet-doctor`), and `journalctl --user -u fleet-eca-<uuid>.service`.
