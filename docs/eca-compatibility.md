# ECA compatibility profile

Fleet's adapter (`lisp/fleet-eca.el`) is verified against exactly one frontend/server pair. On any other pair
`fleet-eca-probe` reports `:supported nil`, `M-x fleet-doctor` names the mismatch, and autonomous dispatch
(starting commanders/operators, sending prompts) is refused with `unsupported-eca-contract`. Read-only
dashboard, artifact viewing, doctor, and independent `systemctl --user stop` of Fleet units keep working.

## Verified pair

| Component | Version | Evidence |
|---|---|---|
| eca-emacs (frontend) | MELPA `20260529.1500`, revision `f700be30f1e5` | `~/.emacs.d/elpa/eca-20260529.1500/eca.el` header |
| eca (native server) | `0.158.1` | `eca --version`; `~/.emacs.d/eca/eca-version` |
| Emacs | 30.2 with SQLite | reference host |
| systemd | 260 (Arch), cgroup v2 | `tests/fixtures/eca/systemd-spike.sh` |

Traces recorded on 2026-09-08 with `tests/fixtures/eca/probe.py` (raw Content-Length JSON-RPC against the
native server, one real model turn each): `trace-prompt.json`, `trace-double.json`, `trace-badmodel.json`,
`trace-stop.json`, `trace-question.json`. Welcome text and config payloads are redacted; ordering and shapes
are intact.

## Transition table (observed, not assumed)

| Observation | Wire fact on this pair | Fleet policy |
|---|---|---|
| Positive prompt acknowledgment | `chat/prompt` **response** `{"chatId","model","status":"prompting"}` | mark `accepted` only on this response |
| Running/content before acknowledgment | `chat/opened`, user echo, `progress running`, `chat/statusChanged running` all precede the response by ~50–80 ms | record `turn-started` immediately; acceptance stays unconfirmed; never resend |
| Definite pre-submission rejection | response `{"status":"error","model":"error"}` after a `system` text `Error: ...`, `idle`, `finished` (no model configured) | `rejected`; lane freed |
| Accepted but the turn errors | response `prompting`, then `system` text starting `Error:`, then `idle` + `finished` (bad model id) | `accepted`, then `turn-idle-observed` with `:error-text`; lane freed; event surfaces the text |
| Transport error | `eca-api--send!` catches `process-send-string` errors and only `message`s them; the error callback is **not** invoked | Fleet checks `process-live-p` before sending and runs its own acknowledgment watchdog (`fleet-eca-ack-timeout-sec`, 45 s) |
| No acceptance evidence by deadline | no response and no `running` | `delivery-unknown`; lane frozen; no automatic resend |
| Running seen but no response by deadline | | `observed-unacknowledged`; lane stays held until the terminal event |
| Terminal activity event | `chat/statusChanged idle` immediately followed by `progress state=finished` (same instant); after `chat/promptStop`: `statusChanged stopping` then `progress finished` and **no `idle`** | consume the first of the two once; the second is `turn-idle-duplicate`; UI-synthetic finish is never observed because Fleet reads the wire |
| Late `metadata` (title) | arrives 0.6–1 s after `finished` | not activity |
| Second prompt while running | **accepted** (`prompting`), server emits a second `running`, then a single `idle`; the first prompt's answer is dropped (`trace-double.json`) | Fleet admits at most one in-flight prompt per chat; a second submission is refused with `lane-busy` |
| Question | `chat/askQuestion` is a **server request** (has `id`) after `toolCallRun/Running` of `ask_user` and `progress "Waiting answer"`; answered with `{answer, cancelled}` | captured before the UI renders it; `fleet-eca-answer-question` replies to the exact request id |
| Tool approval | `toolCallRun` with `manualApproval: true`; `chat/toolCallApprove` / `chat/toolCallReject` notifications; `toolCallRunning` follows an approval | captured as `tool-approval-required` (dashboard attention, not a commander wake); cleared on `toolCallRunning`/`toolCalled`/`toolCallRejected`; never auto-approved by Fleet |
| Subagent activity | `chat/contentReceived` with `parentChatId`; child `statusChanged` | recorded as `subagent-activity`; can never finish the parent turn |
| Models | first `config/updated` with non-empty `chat.models` arrives ~6 s after `initialized` | connection readiness waits for it (`fleet-eca-models-timeout-sec`, 90 s) |
| Cancellation | `chat/promptStop` is a notification; frontend has a 10 s UI-only fallback to idle | `cancel-requested` only; stop proof comes from systemd |
| `jobs/list`, `jobs/kill` | supported by the frontend (`eca-jobs.el`) | not used; full service stop owns cleanup |

## Public seams used

- `eca-create-session`, `eca-process-start` (with `eca-custom-command` let-bound to the systemd-run argv and
  `eca-process-wrapper-function` nil), `eca-process-running-p`
- `eca-api-request-async`, `eca-api-notify`, `eca-api-send-request-response`
- `eca-chat-mode`, `eca-chat--model/agent/variant/trust` (buffer-local selections)

## Private access (listed by symbol, verified shape)

| Symbol | Why | Shape verified |
|---|---|---|
| `eca--handle-message` | the frontend's only message dispatcher; Fleet wraps the `handle-msg` callback of `eca-process-start` and calls it after observing | `(session json-plist)` |
| `eca--session-*` struct accessors and `setf` (`status`, `chats`, `last-chat-buffer`, `chat-welcome-message`, `process`, `workspace-folders`, `id`) | initialize and silent chat registration mirror `eca--initialize` + the buffer half of `eca-chat-open` | `cl-defstruct eca--session` in `eca-util.el` |
| `eca--chat-init-session`, `eca--session-id-cache`, `eca-chat--id`, `eca-chat--selected-*`, `eca-chat--last-request-id`, `eca-chat--chat-loading`, `eca-chat--pending-question`, `eca-chat--queued-prompt`, `eca-chat--steered-prompt`, `eca-chat--context` | chat buffer state | `defvar-local` in `eca-chat.el` / `eca-chat-context.el` |
| `eca-chat--send-prompt`, `eca-chat--steer-prompt`, `eca-chat--queue-prompt`, `eca-chat--send-queued-prompt`, `eca-chat--send-steered-prompt` | advised on Fleet chats only to own human submission before the composer is cleared, and to disable native auto-dispatch | `eca-chat.el` lines ~1386–1560 |
| `eca-chat--answer-question`, `eca-chat--cancel-question`, `eca-chat--stop-prompt`, `eca-chat--set-prompt`, `eca-chat--prompt-content`, `eca-chat--extract-contexts-from-prompt`, `eca-chat--refine-context`, `eca-chat--normalize-prompt`, `eca-chat--set-chat-loading` | control replies and envelope capture | `eca-chat.el` |
| `eca-chat-new`, `eca-chat-select`, `eca-chat-resume`, `eca-chat-reset`, `eca-chat-clear`, `eca-stop`, `eca-restart` | guarded with `user-error` on Fleet sessions; original path elsewhere | autoloaded commands |

Advice is installed idempotently by `fleet-eca-install-advice`, removed by `fleet-eca-uninstall-advice`
and on `unload-feature`. Non-Fleet buffers/sessions take the original code path unchanged.

## Configuration and environment facts

- Config waterfall (verified against docs and behavior): `ECA_CONFIG` env > `~/.config/eca/config.json` >
  `.eca/config.json` > `extraConfigs`, deep-merged. `--config-file` **replaces** discovery and is not used.
- Fleet passes a per-runtime `ECA_CONFIG` overlay: `mcpServers.fleet` (the bridge) and
  `disabledTools: ["eca__spawn_agent"]`. The MCP entry is therefore invisible to ordinary sessions;
  `M-x fleet-install-mcp` is optional.
- `XDG_CACHE_HOME` is honored: the server writes `<cache>/eca/<workspace-hash>/chats` and `models-dev.json`.
  Fleet sets it to `~/.cache/fleet/eca/<runtime-uuid>`.
- The server logs `[MCP] Started MCP server fleet` on stderr when the overlay is applied (native test).
- Agent names on this pair are `code`/`plan`; an unknown name falls back with a warning. `fleet-agent`
  defaults to nil (server default).
- **Tool approval precedence (server source `eca.features.tools/approval-decision`, verified 0.158.1 and
  0.159.0):** config `deny` > session "approve and remember" > **tool built-in check** > config `ask` >
  config `allow` > legacy `manualApproval` > `byDefault`. The built-in check makes every filesystem tool ask
  for a `path` outside the session's workspace roots and `shell_command` ask for a `working_directory`
  outside them, so `toolCall.approval.byDefault: "allow"` cannot suppress those prompts. Only trust mode
  does (it promotes `ask` to allow and never overrides `deny`): `chat/prompt` `trust: true`,
  `chat/update {chatId, trust}` (frontend `C-c C-t`, applies to the next tool call), or server config
  `chat.defaultTrust`. Consequences for Fleet (rehearsal 1, 2026-09-09):
  - workspace roots must cover everything the brief entitles an operator to touch: the task directory
    (progress, report, artifacts, Fleet workspace) plus the studied repository or the change worktree;
    the commander gets the fleet directory (`fleet-core-operator-roots`);
  - Fleet chat buffers seed `eca-chat--selected-trust` from `eca-chat--last-known-trust` exactly like
    `eca-chat-open`, and `fleet-eca-submit` forwards it as `trust`, so the user's `eca-chat-trust-enable`
    governs Fleet chats too. Fleet itself never turns trust on.
  - `tool-approval-required` is recorded but not actionable: only a human can answer it.
- **Usage notifications** on `openai/gpt-5.6-*` (openai-responses) carry `sessionTokens` and `sessionCost`
  (a string) but null `messageInputTokens`/`messageOutputTokens`; telemetry derives per-turn deltas.
- **ECA UI on Fleet sessions:** `eca-chat--handle-init-progress` and `eca-chat--handle-mcp-server-updated`
  call `(with-current-buffer (eca-chat--get-last-buffer session))`, which is nil until Fleet's silent chat
  exists, raising `Wrong type argument: stringp, nil` (logged to `<eca:emacs-errors[…]>`). Harmless, but
  `eca-process--make-filter` maps `handle-msg` over a whole chunk, so Fleet guards its call to
  `eca--handle-message` to keep observing the rest of the chunk.
- **Unverified:** whether `disabledTools` fully prevents `eca__spawn_agent` on this server version. Until a
  trace confirms it, treat native subagent spawning inside Fleet runtimes as possible; the bridge still binds
  authority to the runtime credential, so a child would share its parent's scope (never more).

## Stop evidence (systemd 260)

`systemd-run --user --quiet --pipe --wait --collect --service-type=exec --unit=fleet-eca-<uuid>.service
-p KillMode=control-group -p TimeoutStopSec=15 -p Restart=no --working-directory=… --setenv=NAME …`:

- stdout carries only the service's output; stderr is empty with `--quiet`.
- `--setenv=NAME` copies the value from the launcher's environment.
- Killing the Emacs-side wrapper leaves the service and its `setsid nohup` child alive **unless** the service
  exits on stdin EOF (native ECA does, since `--pipe` closes its stdin).
- `systemctl --user stop` kills main, shell child and detached child; after `--collect` the unit reads
  `LoadState=not-found`, `ControlGroup=` and the cgroup directory is gone. `fleet-runtime-verdict` treats
  `not-found` as `stopped` only for a settled launch with an empty/absent recorded cgroup.

## What to do on upgrade

1. `M-x fleet-doctor` will report the new pair as unsupported.
2. Run `tests/fixtures/eca/probe.py prompt|double|badmodel|stop|question` against the new server and diff
   against the recorded traces.
3. Re-verify each symbol above in the new frontend source, update `fleet-eca-supported-pairs`, and rerun
   `make test-native`.
