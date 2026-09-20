# Fleet quickstart

Fleet is a persistent Emacs-native workspace for delegating project work to a team of ECA agents: one
**commander** per fleet talks to you; **operators** each do one task in their own native ECA chat and
systemd-owned process; **Emacs** owns state, scheduling and the dashboard.

## Prerequisites and install

1. An ordinary native ECA chat already works in your Emacs (`M-x eca`), `systemctl --user` works, and Emacs
   was built with SQLite (`(sqlite-available-p)` → `t`). Python 3.11+ at `/usr/bin/python3`, Git.
2. Fleet lives at `~/development/fleet`. Load it from the source tree with `use-package` (no copy or
   symlink under `~/.emacs.d/lisp`). Source edits do not replace loaded definitions; stale `.elc` files and
   cached schemas need attention. See [change loading](docs/development.md#source-changes-are-not-live-changes)
   before an owner-approved reload/restart. `C-c h f` is your binding, Fleet never installs one itself:

   ```elisp
   (use-package fleet
     :if (file-directory-p (expand-file-name "~/development/fleet/lisp"))
     :load-path "~/development/fleet/lisp"
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
     ;; your call, not a product default: report a wait that lasts, as a backstop against a task
     ;; parked on a completion that never arrives. One actionable event per 10-minute window per
     ;; live wait, and the supervising lieutenant/commander spends a model turn on each. Off by default:
     ;; (fleet-wait-watchdog-sec 600)
     )
   ```

   **Models.** Without any of the above, operators run on the `default` of your owner model policy
   (`~/.config/fleet/config.json`, `models.default`), commanders on `models.commander` and lieutenants on
   `models.lieutenant` (each an optional model id or `{"model", "variant"}`), and anything unset falls to
   the ECA default model. Once one
   Fleet runtime has started, Fleet knows ECA's model catalog: `M-x fleet-new` then offers completion for the
   commander's model and variant (accept the default with RET) — both when creating a fleet and whenever it
   starts a commander for an existing one (resume, or a fleet whose commander was stopped), where RET keeps
   the fleet's current pin. `M-x fleet-commander-replace` asks the same question, so switching a running
   fleet to another model is: replace, pick the model. `M-x fleet-commander-set-model` changes the pin
   without starting anything (it applies at the next commander start). You can steer operators per task just by
   telling the commander — "do this on gpt 5.6 terra medium". The commander resolves casual names against
   the catalog and Fleet refuses ids that are not in it. The dashboard shows each runtime's model next to the
   commander status and in the task rows (provider prefix dropped; `v` peek shows the full id).

   **Operator model policy.** To stop naming models by hand, write your standing preferences under
   `models` in `~/.config/fleet/config.json` (the owner configuration file, or `fleet-config-file`) as
   rules in your own words: `when` a
   description of the work applies, `use` this model (a single selection or a best-first chain), optionally
   with a `why`. The commander judges which rule a task falls under, passes that model and a one-line
   `model_reason`, and Fleet records both on the `task-created` event; with no applicable rule it omits
   `model` and gets `default`. Fleet keeps the mechanical parts: catalog validation, the ask-first gate and
   the fallback. Models under `ask_first` are refused until the commander has proposed model and reason to
   you and passes `owner_approved` — however they were chosen, so even "run it on astra" gets confirmed once.
   Put `"*"` in `ask_first` to be asked for **every** task while you shape the rules; narrow it to the
   expensive models once the proposals look right. `fallback` names the model a runtime moves to when its
   turn does nothing at all (typically a provider timeout or outage); Fleet applies that by itself and
   records a `model-fallback` event. All keys are optional; a missing file means no policy; a malformed one
   refuses task creation and is reported in the commander's boot message. Selections are
   `{"model": ..., "variant": ...}` or a bare id.

   ```json
   {
     "version": 1,
     "models": {
       "default": {"model": "openrouter/x-ai/grok-4.6"},
       "ask_first": ["*"],
       "fallback": {"openrouter/x-ai/grok-4.6": {"model": "openai/gpt-5.6-terra", "variant": "medium"}},
       "rules": [
         {"when": "non-simple technical or architecture design, planning, research, review, or an involved browser workflow",
          "use": [{"model": "openai/gpt-6-astra", "variant": "medium"},
                  {"model": "anthropic/claude-fable-5-1", "variant": "high"}, "openrouter/moonshotai/kimi-k3"]},
         {"when": "major or ambiguous feature implementation",
          "use": [{"model": "anthropic/claude-fable-5-1", "variant": "high"},
                  {"model": "openai/gpt-6-astra", "variant": "medium"}, "openrouter/moonshotai/kimi-k3"],
          "why": "coding-heavy work goes to fable first"},
         {"when": "simple bug fix whose root cause is understood, a documentation update, or a simple chore",
          "use": ["openrouter/deepseek/deepseek-v4.1-flash", "openrouter/x-ai/grok-4.6"]}
       ]
     },
     "fleets": {
       "workshop": {
         "lieutenants": {
           "frontend": {"charter": "UI, interaction design, accessibility and browser-facing implementation."},
           "backend":  {"charter": "Service APIs, persistence, data processing and server-side performance."}
         }
       }
     }
   }
   ```

   The policy `default` takes precedence over `fleet-operator-model` and routes operators only; the
   commander's own model is the fleet pin, else `fleet-commander-model`, else `models.commander`
   (`models.lieutenant` for a lieutenant), else the ECA default. `model_source` on the event is `explicit`, `policy-default`, `config`
   or `eca-default`; `model_reason` is the commander's stated ground, recorded verbatim.

   **Lieutenants.** The `fleets` section declares, per root fleet, long-lived domain supervisors between
   the commander and the operators ([design and status](docs/lieutenants.md)). Each lieutenant is a fleet
   of its own — own commander runtime, tasks, `commander/context.md` and inbox — whose commander's user is
   the root commander. A `charter` is prose the commander routes by; optional `model`/`variant` pin the
   lieutenant's runtime (default: the root's commander pin). Lieutenants are created and started when the
   root's commander starts (`fleet-new`, `fleet-commander-replace`); removing one from the file never
   deletes it. Everywhere a fleet is named, a lieutenant is `root/child`: `fleet-commander-stop
   workshop/frontend` replaces just that lieutenant's runtime, `fleet-new workshop/frontend` restarts a
   stopped one, `fleet-destroy workshop/frontend` retires an empty one. Park and resume are whole-fleet
   operations on the root. The commander delegates with `fleet_delegate` (a brief opens a durable
   request); the lieutenant runs its own operators and reports back with `fleet_report`
   (`question`/`progress`/`settled`), which wakes the commander like any other event. When a lieutenant's
   context runs long it writes its handoff and says so; the commander then calls
   `fleet_lieutenant_replace`, the tool form of `fleet-commander-replace root/child`.

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
   runtime dir, stale owner). It is a partial dependency check, not a full compatibility/safety preflight;
   store diagnostics require an already-open store. Read [known gaps](docs/known-gaps.md) before unattended
   use. `fleet-dashboard` is **not passive inspection**: it starts Fleet, may acquire ownership/migrate the
   store, and reconciles recorded runtimes. Use [offline inspection](docs/recovery.md) when startup is not
   authorized. The lazy command declaration above intentionally does not wait for ECA to be opened first.

## M-x reference

| Command | When |
|---|---|
| `fleet-dashboard` | Show the live grouped view; starts Fleet in this Emacs (owner, or read-only if another Emacs owns the data root). `C-c h f` if you bound it. |
| `fleet-new` | Create a named fleet and its commander, or resume/visit an existing one. A live commander is visited, never duplicated. A parked fleet asks *resume* vs *visit only*. |
| `fleet-park` | Stop every operator of a root fleet **and its lieutenants** with verified service evidence; keep the commanders and all durable work. Confirms with live-operator/tool/external-job counts across the whole fleet. |
| `fleet-task-close` | Archive one task on your authority, without the teardown evidence gate: failed or abandoned work, or done work that can no longer be verified. Needs a reason, a stopped operator (park first) and, for change tasks, an already-removed worktree. Nothing is deleted. |
| `fleet-destroy` | Retire an **empty** fleet (all tasks archived, no lieutenants, no open requests): archive-move its artifact tree and release the name. Lieutenants retire one by one (`root/child`) before their root. No dashboard key, no commander tool. |
| `fleet-watch-start` / `fleet-watch-stop` | Enable / pause automatic commander wakes for a fleet. Pausing never stops processes or event recording. |
| `fleet-doctor` | Partial dependency probe; ownership/storage/runtime diagnostics when the store is already open. Does not start the supervisor. |
| `fleet-commander-stop` | Verified stop of one supervisor only (a root's commander, or a lieutenant by `root/child`); operators and other supervisors keep running. |
| `fleet-commander-replace` | Verified stop, then a fresh commander booted with the durable snapshot and `commander/context.md`. Offers to change the commander's model/variant first. On a root, also applies configured lieutenants and starts any without a live runtime; `root/child` replaces just that lieutenant. |
| `fleet-commander-set-model` | Pin the model/variant the fleet's *next* commander launches with (RET keeps the current one). A live commander is untouched. |
| `fleet-install-mcp` | Optional: merge the single Fleet MCP entry into ECA's global config with backup + diff. |
| `fleet-timeline` / `fleet-stats` | Read-only telemetry from an already-open store, including archived fleets: event→wake/ack latencies, tools/refusals, turns, tokens/cost, operations. Refuses if Fleet is not started; use offline SQL when startup is not authorized. |

## Dashboard keys

Buffer `fleet:*`. Rows: `glyph task state·source kind repo age detail`. Sorted alphabetically; urgency comes
from `a`, not reordering. A root fleet's header and tasks are followed by each of its lieutenants as an
indented `↳ name - lieutenant …` header with its own tasks; the header shows open requests.

| Key | Action |
|---|---|
| `n` / `p` | next / previous entry (fleet and lieutenant headers included); no wrap. `p` is *previous*, not peek. |
| `N` / `P` | next / previous fleet or lieutenant header |
| `j` | jump to a fleet or lieutenant by selector (`root`, `root/child`) |
| `a` | next entry needing you (decision, blocked, failed, dead, unknown, stop/delivery problems); wraps. If only the commander has a problem, its header. |
| `RET` | header → the commander's real ECA chat; task → the operator's chat. Unavailable sessions show recovery info and the retained transcript, never an empty new chat. |
| `v` (also `?`) | read-only peek: last 40 lines, in `fleet-peek*` |
| `s` | one minibuffer message to the commander (header) or operator (task). Shows queued/accepted/unknown truthfully. If the target has a pending question, `s` answers exactly that question. |
| `i` | operator only: request cancellation of the current turn (confirm). Requested ≠ stopped. |
| `t` | operator only: normal teardown with the full evidence gate (confirm) |
| `b` / `r` | view brief / report read-only (`view-mode`; `q` leaves, `e` edits — editing does not change dispatched scope) |
| `w` | dired into the task's worktree (change tasks with an existing worktree) |
| `X` | park the root fleet of the row at point, lieutenants included (same confirmation as `M-x fleet-park`) |
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

## Quick bearings: `/fsum`

Type `/fsum` in the root commander's chat (once the [fsum skill](skills/fsum/README.md) is wired into your
ECA skills directory) for one screen of read-only bearings: a supervisor table (commander and lieutenants,
session live/stopped/parked, pending events), a work table with moving work first, and a **Needs you**
list limited to human-authority decisions, native approvals and lost sessions. `/fsum FLEET` names a root
explicitly and refuses if it is not the session's fleet. It reads the store Fleet already has open in this
Emacs and nothing else: no acks, sends, starts, Git or GitHub probes. If Fleet is not started it says so
instead of starting it. Labels are conservative — "Working (reported; idle now)" is a status, not proof of
execution; "Reported done · verification pending" until the commander verifies.

## Executive review in the browser: `/frev`

Type `/frev` in the root commander's chat (with the [frev skill](skills/frev/README.md) and `fsum` wired
into your ECA skills directory) for a **fresh** review session: the commander collects the same read-only
evidence as `/fsum`, authors a compact review (workstreams, choices, asks) and opens a local page. Stay in
the browser: **Needs you** comes first; pick options, add comments per item, type messages (`Enter` queues,
`Shift+Enter` newline, `Ctrl+Enter` sends). Nothing leaves the page until you press **Send round**; the
badge says `Draft · N queued, not sent` until then and your draft survives a reload.

**Send** saves the round and automatically queues one short notice on the commander's lane — you do not
return to the chat to say "sent". The commander handles it with normal Fleet tools, publishes the next
revision with a disposition per input (`applied` / `noted` / `needs-clarification` / `waiting` / `declined`),
and the page updates by itself within seconds. **End** closes the session (with any queued items); it grants
no approval and cancels no work. A later `/frev` is always a new session — there is no resume.

What the notice does *not* do: it is not a wake. A parked fleet, a stopped runtime, a replaced commander or
a half-typed message in the commander's composer make it **hold** (the page says why and offers **Retry
notify**; your round is saved either way). A busy commander receives it when its lane frees. Human-only
decisions are recorded in the round, not resolved by the browser.

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
scope. Done tasks are verified/finalized, not rerun. Held messages change back to queued, but operator
messages can still target the stopped predecessor; do not assume delivery to a replacement. Attempted/unknown
messages must not be blindly resent. Startup journal recovery also has known gaps when no runtimes need
reconciliation or a retask was interrupted. Review [recovery](docs/recovery.md) before relying on either path.

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
- **native permission/question**: permissions need the native chat approval controls; `s` can answer a
  pending native question but cannot approve a tool. A Fleet `needs-decision` record is separate; chat text
  does not resolve it. Human-authority decision resolution has no public command yet; see
  [interface limitations](docs/known-gaps.md#authority-and-interface).
- **empty reply / provider error with nothing done**: Fleet resends an observed empty turn once as is, then
  once on your policy's `fallback` model (the runtime stays on it; `model-fallback` event), then records
  `turn-empty` (no error) or `turn-failed` (error text) and reports give-up in the minibuffer. Rephrase,
  retask on another model, or investigate rather than repeatedly resending. A turn that did work before
  failing is never resent. Missing output or usage does not establish zero external effects or zero cost.
- **stale owner**: another Emacs (or a crashed one) holds `owner.json`. If that Emacs is truly gone, Fleet
  takes over automatically (pid + start time are checked); if it is alive, act there.
- **external jobs**: park lists them; Fleet cannot stop what it did not start.

Evidence lives in `~/.local/share/fleet/fleets/<uuid>/…/runs/<runtime>/{launch.json,transcript.jsonl}`,
the `operations` table (`fleet-doctor`), and `journalctl --user -u fleet-eca-<uuid>.service`. For a
retrospective, `M-x fleet-timeline` and `M-x fleet-stats` read the durable record: every tool call (with
outcome/refusal code and duration), every finished turn (duration, tokens, cost), and wake/ack latencies per
actionable event (missing provider usage can undercount cost). For nonactivating reads use SQLite read-only
mode on the configured data root; see [recovery](docs/recovery.md), including archived artifact locations.
