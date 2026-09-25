# ECA integration notes

Fleet's adapter (`lisp/fleet-eca.el`) is the only module that knows ECA internals. This document records the
wire behavior and private frontend symbols it relies on, so that a future ECA change that breaks Fleet can be
diagnosed quickly. ECA versions are **not** pinned: `fleet-eca-probe` (surfaced by `M-x fleet-doctor`) only
checks that the eca-emacs package loads, executable discovery succeeds, and the symbols in
`fleet-eca-required-functions`/`-variables` are defined. This is a partial probe: the required lists do not
cover every private symbol used, and an explicit unusable executable is not reliably rejected. See
[diagnostic gaps](known-gaps.md#verification-and-diagnostics). An explicit unsupported result refuses
launch with `unsupported-eca-contract`. Artifact inspection and independent systemd stopping do not require
a working ECA adapter. Dashboard startup itself can acquire ownership and reconcile runtimes; it is not an
offline read. Routine ECA upgrades need no version gate; investigate actual breakage against source/traces.

**Before unattended use:** operator `disabledTools` enforcement and several native acceptance checks remain
unverified. Read [testing](testing.md#pending-native-acceptance) and [known gaps](known-gaps.md), including
tool-level authority limitations; a role-filtered tool list is not proof that every handler enforces scope.

## Reference environment for the recorded facts

Observed on eca-emacs `20260529.1500` (rev `f700be30f1e5`) with server `eca 0.158.1` (2026-09-08) and
re-checked on `0.159.0` (2026-09-09), Emacs 30.2 with SQLite, systemd 260 (Arch, cgroup v2).

Traces recorded with `tests/fixtures/eca/probe.py` (raw Content-Length JSON-RPC against the native server, one
real model turn each): `trace-prompt.json`, `trace-double.json`, `trace-badmodel.json`, `trace-stop.json`,
`trace-question.json`. Welcome text and config payloads are redacted; ordering and shapes are intact.

## Transition table (observed, not assumed)

| Observation | Wire fact on this pair | Fleet policy |
|---|---|---|
| Positive prompt acknowledgment | `chat/prompt` **response** `{"chatId","model","status":"prompting"}` | mark `accepted` only on this response |
| Running/content before acknowledgment | `chat/opened`, user echo, `progress running`, `chat/statusChanged running` all precede the response by ~50–80 ms | record `turn-started` immediately; acceptance stays unconfirmed; never resend |
| Definite pre-submission rejection | response `{"status":"error","model":"error"}` after a `system` text `Error: ...`, `idle`, `finished` (no model configured) | `rejected`; lane freed |
| Accepted but the turn errors | response `prompting`, then `system` text starting `Error:`, then `idle` + `finished` (bad model id) | `accepted`, then `turn-idle-observed` with `:error-text`; lane freed; event surfaces the text |
| Accepted, then nothing (empty completion) | response `prompting`, `running`, then `idle` + `finished` with **no** assistant text, tool call, error text or `usage` (openrouter/x-ai/grok-4.6 via ECA 0.159.0, 5.7 s, openclaw 2026-09-11) | `turn-idle-observed` with `:empty t` (and `:barren t`); the supervisor resends the message once (`fleet-supervisor-empty-turn-retries`), then once on the owner's policy fallback model if one is configured (`fleet-supervisor-model-fallbacks`, `model-fallback` event, live chat re-pinned via `fleet-eca-select-model`), then finishes it with `:empty` evidence, records a `turn-empty` event (actionable for operators) and tells the human. A turn whose only output is `system` text beginning `Error:` is `:barren t` without `:empty`: it skips the same-model resend and goes straight to the fallback, then `turn-failed` |
| Operator answers a commander message without a status | an ordinary `idle` + `finished` after assistant text or tool calls; nothing on the wire tells it apart | a store fact, not a wire one: when no `task-done`/`task-failed`/`task-blocked`/`decision-requested` from that task and runtime is at or after the message's `created_at`, the supervisor records one actionable `turn-unreported` (`:message-id`) at turn end (design note 23). Barren turns keep `turn-empty`/`turn-failed` |
| Transport error | `eca-api--send!` catches `process-send-string` errors and only `message`s them; the error callback is **not** invoked | Fleet checks `process-live-p` before sending and runs its own acknowledgment watchdog (`fleet-eca-ack-timeout-sec`, 45 s) |
| No acceptance evidence by deadline | no response and no `running` | `delivery-unknown`; lane frozen; no automatic resend |
| Running seen but no response by deadline | | `observed-unacknowledged`; lane stays held until the terminal event |
| Terminal activity event | `chat/statusChanged idle` immediately followed by `progress state=finished` (same instant); after `chat/promptStop`: `statusChanged stopping` then `progress finished` and **no `idle`** | consume the first of the two once; the second is `turn-idle-duplicate`; UI-synthetic finish is never observed because Fleet reads the wire |
| Late `metadata` (title) | arrives 0.6–1 s after `finished` | not activity |
| Second prompt while running | **accepted** (`prompting`), server emits a second `running`, then a single `idle`; the first prompt's answer is dropped (`trace-double.json`) | Fleet admits at most one in-flight prompt per chat; a second submission is refused with `lane-busy` |
| Question | `chat/askQuestion` is a **server request** (has `id`) after `toolCallRun/Running` of `ask_user` and `progress "Waiting answer"`; answered with `{answer, cancelled}` | captured before the UI renders it; `fleet-eca-answer-question` replies to the exact request id |
| Tool approval | `toolCallRun` with `manualApproval: true`; `chat/toolCallApprove` / `chat/toolCallReject` notifications; `toolCallRunning` follows an approval | captured as `tool-approval-required` (dashboard attention, not a commander wake); cleared on `toolCallRunning`/`toolCalled`/`toolCallRejected`; never auto-approved by Fleet |
| Tool result | `toolCalled` carries `error` and `outputs` (`[{type: text, text}]`). ECA validates a tool call's arguments against the MCP `inputSchema` itself: a call missing a required parameter is answered `error: true` with the text `missing required params: ...` and **never reaches the MCP server** (so Fleet's RPC layer cannot log it; the supervisor records such a refusal of a `fleet_*` tool as a `tool-call` event from source `eca`, code `eca-invalid-args`) | `tool-finished` and the transcript row carry `error`; a failed call also keeps its outputs text clipped to 600 chars (`output`), since that is the only record of the reason. Successful outputs are not copied |
| Subagent activity | `chat/contentReceived` with `parentChatId`; child `statusChanged` | recorded as `subagent-activity`; can never finish the parent turn |
| Models | first `config/updated` with non-empty `chat.models` arrives ~6 s after `initialized`; it also carries `selectModel` (server default) and `variants` (for the selected model only; e.g. `high low max medium xhigh` on `openai/gpt-5.6-*`). Per-chat `config/updated` later carry `chatId` + `selectVariant`. | connection readiness waits for it (`fleet-eca-models-timeout-sec`, 90 s); the catalog is persisted in `meta` (`fleet-store-eca-catalog`) |
| Model selection | `eca-chat--model`/`--variant` fall back to the global `eca-chat--last-known-*`, i.e. the user's last interactive pick; variant `"-"` means "send none". The session-wide `config/updated` (no `chatId`) is broadcast by `eca-chat-config-updated` → `eca-chat--apply-per-chat-config` into **every** chat buffer, rewriting `eca-chat--selected-model/-variant/-trust` with `selectModel`/`selectVariant`/`selectTrust` | the connection (`fleet-eca-conn-model`/`-variant`) is the source of truth for `chat/prompt`; the buffer-locals are only re-synced for the mode-line (`fleet-eca--sync-selection`). No requested variant ⇒ the server's announced `selectVariant` (what a fresh interactive chat gets), recorded on the runtime row |
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
  `disabledTools: ["eca__spawn_agent"]` for the commander, `["eca__spawn_agent", "eca__ask_user"]` for
  operators (their question channel is `fleet_status needs-decision`; a native `ask_user` parks the turn on a
  human-only `chat/askQuestion` the commander cannot answer). The MCP entry is therefore invisible to
  ordinary sessions; `M-x fleet-install-mcp` is optional.
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
- **Terminal pair vs. the next prompt (openclaw, 2026-09-10):** `statusChanged idle` and `progress finished`
  arrive in one chunk. A prompt submitted from inside the `idle` handler (the supervisor dispatching a queued
  message) received the `finished` as *its own* terminal: a 4 ms "turn", the connection's turn cleared by
  the 5 s finished-before-ack timer while the real turn ran, the real terminal dropped as a duplicate, the
  message stuck `accepted`, and the lane busy forever. Two guards: `fleet-eca--turn-terminal` ignores a
  terminal for a turn that has seen neither `running` nor acceptance (a prompt's own terminal is always
  preceded by its `running`; a definite rejection clears the turn via the error response), and the supervisor
  dispatches the next queued message from a zero timer, after the chunk.
- **Turns that end with nothing (openclaw, 2026-09-11):** a human prompt to the commander was accepted and
  the chat went `idle` 5.7 s later with no content of any kind — no assistant text, no tool call, no
  `system` error text, no `usage`. Fleet recorded a normal finish, the message was `finished`, and the only
  visible trace was an unanswered prompt in the chat. The same session had an earlier commander die on an
  OpenRouter 400 (context length) that ECA 0.159.0 also did **not** report as a `system` `Error:` text on
  the wire (it is kept as `prompt-error` in the server's chat record), so `:error-text` was null there too.
  Fleet now marks a turn `:empty` when it was accepted, not stopped by a human, and produced no text, tool
  activity or error text; the supervisor interprets this observed-empty signal as eligible for one resend
  and surfaces the second failure instead of retrying further. It is not general proof of zero external
  side effects when error/tool reporting itself may be incomplete. Capturing 0.159's error reporting is
  still open; do not add an undocumented cache dependency to compensate.
- **Admission feedback:** the chat's minibuffer report after RET used to read the connection's turn, which on
  a free lane is the just-dispatched message itself, so every send said "queued (operator busy)". The
  supervisor's sink now returns the durable message state and the report follows it (sent / queued / held).
- **ECA UI on Fleet sessions:** `eca-chat--handle-init-progress` and `eca-chat--handle-mcp-server-updated`
  call `(with-current-buffer (eca-chat--get-last-buffer session))`; interactively that buffer exists because
  `eca--initialize` calls `eca-chat-open` right after `initialized`, before models. Fleet used to create its
  silent chat only at readiness (~6 s later), so every `$/progress`/`tool/serverUpdated` in between raised
  `Wrong type argument: stringp, nil` (logged to `<eca:emacs-errors[…]>`). Fleet now registers the chat at
  the same point as the frontend and pins model/variant later (`fleet-eca--pin-selection`). The guard around
  `eca--handle-message` stays: `eca-process--make-filter` maps `handle-msg` over a whole chunk, so a UI error
  must never cost the observer the rest of the chunk.
- **Unverified:** whether `disabledTools` fully prevents `eca__spawn_agent` (and, for operators,
  `eca__ask_user`) on this server version. Until a trace confirms it, treat native subagent spawning inside
  Fleet runtimes as possible; a child would inherit the parent's credential, not gain a separate authority
  grant. Handler scope checks have [known gaps](known-gaps.md#authority-and-interface). On an authorized
  operator run, inspect `tool/serverUpdated` for the `eca` server: neither `ask_user` nor `spawn_agent`
  should be advertised. Mere absence of a call in one transcript does not prove exclusion.

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

## If an ECA upgrade breaks something

1. `M-x fleet-doctor`: a missing private symbol is named on the `ECA` line (refusal is deliberate there).
2. For behavioral drift with symbols present, inspect the adapter, installed frontend source and existing
   redacted traces first. Only after explicit authorization, capture the relevant native shape with
   `tests/fixtures/eca/probe.py` (`prompt|double|badmodel|stop|question`) and compare it with fixtures.
   The script launches a server at top level: even importing it or trying an unsupported help invocation
   is not passive. Paid/native acceptance must follow [testing](testing.md), not an automatic
   `make test-native` invocation or a probe inside an active owner fleet.
