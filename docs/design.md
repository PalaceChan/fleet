# Fleet at home — native ECA technical design

**Status:** Final design specification. The implementation must verify its installed ECA frontend/server pair
as its first milestone.

**Target:** `/home/avelazqu/development/fleet`; Arch Linux; native ECA within Emacs; local, unsandboxed
execution; GitHub for normal pull-request workflows.

**Deliverable:** Build a new Fleet repository from this standalone specification, including its Emacs package,
agent interface, tests, `AGENTS.md`, and `quickstart.md`.

## 1. Product contract

Fleet is a persistent, Emacs-native workspace for delegating project work to a team of agents:

- **You** supply intent, scope, decisions, and authorization.
- One **commander** per fleet is your single liaison. It turns requests into bounded tasks, briefs operators,
  supervises outcomes, and escalates decisions.
- An **operator** does the work of one task in its own native ECA connection and chat.
- **Emacs**—not another model—owns execution, durable state, notification scheduling, and the dashboard.
- A task survives the loss of its chat, its ECA process, or Emacs. Its brief, workspace, progress, artifacts,
  and unhandled events remain.

The intended workflow is: `M-x fleet-new` → talk to the commander → independent operators start silently → use
`C-c h f` to inspect the fleet → receive decisions and results rather than progress chatter → `X` parks
execution without throwing work away → reopen the same fleet later.

"Zero-token supervision" means no model is invoked to poll or wait. Handling a real event still costs a model
turn. It does not mean that background monitoring has no CPU cost or that model recovery is free.

### 1.1 First-principles decisions

- **Decision:** ECA only; no backend plugin framework
  - **Reason:** Native ECA is the actual requirement. A small compatibility adapter is necessary; a fleet of
    hypothetical backends is not.

- **Decision:** Emacs owns the control plane
  - **Reason:** It already owns the UI and ECA connections. Avoid a second long-lived scheduler with another
    copy of task truth.

- **Decision:** One ECA server process and one designated chat per runtime
  - **Reason:** Gives explicit routing, independent model context, independent cancellation, and an
    accountable process group. No ambient "last chat" targeting.

- **Decision:** Durable task identity is independent of ECA chat identity
  - **Reason:** Conversations are replaceable execution context, not the project database.

- **Decision:** SQLite through Emacs, with a single authoritative writer
  - **Reason:** Task updates, events, delivery state, and acknowledgments need transactions. Loose status
    files and destructive queue drains do not provide them.

- **Decision:** Markdown for briefs, reports, and human-readable progress
  - **Reason:** Artifacts should remain useful without Fleet or ECA. Large document bodies do not belong in
    dashboard rows or event payloads.

- **Decision:** Structured Fleet tools over a local socket
  - **Reason:** Typed arguments and authorized operations keep agent requests separate from authoritative
    metadata writes.

- **Decision:** Linux user-systemd service per ECA runtime
  - **Reason:** A chat buffer disappearing is not proof that descendants stopped. Cgroup ownership solves the
    real orphan-process problem without adding a sandbox.

- **Decision:** Recovery uses briefs, progress, Git, and reports
  - **Reason:** Do not parse undocumented ECA caches or assume `/resume` restores a stable chat identity.

- **Decision:** No automatic model polling, permission approval, merge, or discard
  - **Reason:** Silence and scope discipline are product properties, not optional niceties.

SQLite and systemd are deliberate dependencies with specific responsibilities, not general infrastructure
additions. Emacs remains the only scheduler; systemd only launches, accounts for, and stops owned local
processes. There is no web dashboard, Redis, container runtime, shell watcher, or persistent Python service.

### 1.2 Explicit non-goals

V1 is single-host and ECA-only. Remote workers, sub-commanders, automatic model selection, arbitrary plugin
discovery, automatic PR merging, a separate task planner UI, and a replacement ECA chat renderer are outside
its scope.

GitHub pull requests use the user's existing authenticated tooling under the repository's instructions. Fleet
records the resulting URL/OID and verifies Git preservation independently; it does not need its own
hosting-provider framework. Personal notes and context-handoff tools are optional integrations, not startup
dependencies.

No arbitrary Fleet-wide concurrency cap. Serialize real dependencies, the same mutable workspace, and
explicitly named exclusive resources. Provider rate limits remain ECA/provider concerns; surface failures
rather than repeatedly retrying them.

## 2. User experience and safety invariants

### 2.1 Interaction contract

- Fleet-qualified commander/operator identity; contextual dashboard `RET`.
- `n/p` entries, `N/P` fleets, `j` fleet completion, `a` attention, `?` peek.
- Brief/report viewing is read-only by default; `q` leaves and `e` edits.
- Background operator launch never steals the frame or changes the user's current window.
- Fixed semantic columns with data-sized, capped widths, age before unclipped detail, themed faces, and a
  footer listing keys.
- Park, task teardown, and fleet destruction are distinct operations.
- Dashboard refresh preserves selected row identity, not a character offset.
- Visiting an unavailable session shows honest recovery/transcript information, not a newly created empty
  buffer.

### 2.2 Control-plane invariants

- Structured ECA events describe conversation activity; a service identity describes local execution
  ownership; transactional records describe delivery and acknowledgment.
- Task completion, active execution, artifact verification, and Git preservation are separate facts.
- Only the owning supervisor may declare an endpoint dead or restart it. A vanished UI never licenses a
  duplicate live worker.
- Park succeeds only after all accountable operator execution and pending launches have settled; durable files
  and history remain.
- A report is evidence, not authorization to implement its recommendations. Completed scope requires explicit
  new tasking before it runs again.
- An adopted workspace is not Fleet's property to remove.
- Refusals include the evidence needed to understand them.
- Human inspection never consumes commander notifications; neither a prompt submission nor a queue read
  acknowledges an event.

### 2.3 Vocabulary

Use `decision` for an operator requiring an answer, `supervision on/paused` for automatic commander dispatch,
and `parked` for a fleet whose operators have intentionally stopped. Use **preserved** for durable Git
retention and **integrated** for inclusion in the target branch. An open GitHub PR is not a merge. An ordinary
Emacs daemon can own Fleet; ownership is explicit and exclusive.

## 3. Environment and directory hierarchy

### 3.1 Supported baseline

- Arch Linux with a working user systemd manager and cgroup v2.
- Emacs 29.1 or later, built with SQLite support; test Emacs 30 as the initial reference.
- Installed native ECA Emacs package and executable; pin the tested pair in a compatibility manifest.
- Git; Python 3.11+ for a small stdio MCP/socket bridge and test support.
- ECA credentials and provider configuration already working in an ordinary manual native ECA chat.

Do not assume the Arch package build includes SQLite: check `(sqlite-available-p)`. Do not silently fall back
to a different persistence architecture if it does not. Installation should explain the missing prerequisite.

The exact installed ECA frontend/server pair is an implementation-time input. Section 5 identifies concrete
API candidates and required behavior; it does not certify an unspecified version. Milestone 0 must inspect the
installed sources and capture protocol evidence before enabling unattended Fleet.

### 3.2 Locations

| Purpose | Default |
|---|---|
| Fleet source | `~/development/fleet/` |
| Primary development clones | `~/development/<repo>/` |
| Fleet-created worktrees | `~/development/.worktrees/<repo>--<fleet>-<task>-<short-id>/` |
| Fleet user configuration | `$XDG_CONFIG_HOME/fleet/`, default `~/.config/fleet/` |
| Authoritative database and retained artifacts | `$XDG_DATA_HOME/fleet/`, default `~/.local/share/fleet/` |
| Disposable diagnostic/cache data | `$XDG_CACHE_HOME/fleet/`, default `~/.cache/fleet/` |
| Local control socket and ephemeral credentials | `$XDG_RUNTIME_DIR/fleet/` |
| Stable owner lock and descriptor | `<data-root>/owner.lock` and `owner.json` |
| ECA's ordinary user configuration | Its normal ECA location, generally `~/.config/eca/` |

Durable project state belongs under XDG data, not `/tmp`, a cache directory, or the source checkout.
`$XDG_RUNTIME_DIR` must be a local, user-owned directory; missing or unsafe runtime storage is a doctor error.
Do not bind an unauthenticated TCP port as a fallback.

Configuration roots may change, but no module independently reconstructs them. `fleet-paths.el` owns
resolution, canonicalization, path containment, and runtime identifiers. Use `expand-file-name`,
`file-truename` where the object exists, and validated canonical parents for new paths. Never use
string-prefix containment without a directory boundary.

Primary clones are not Fleet execution workspaces. Fleet never branches, resets, or stashes a primary checkout
behind the user's back. A dirty/off-default primary checkout is not a reason to modify it; inspect it and
create a separate worktree from an explicit base ref without changing its HEAD.

### 3.3 Source tree

```text
fleet/
├── AGENTS.md
├── README.md
├── quickstart.md
├── LICENSE                         # choose before publishing, not invented by an agent
├── Makefile
├── .gitignore
├── lisp/
│   ├── fleet.el                    # public commands, setup, package entry
│   ├── fleet-paths.el              # path/config resolution and identifiers
│   ├── fleet-store.el              # schema, migrations, transactions, projections
│   ├── fleet-core.el               # lifecycle operations and operation recovery
│   ├── fleet-supervisor.el         # event routing, outbox, waits, owner acquisition
│   ├── fleet-eca.el                # ALL ECA-specific API/protocol adaptation
│   ├── fleet-runtime.el            # systemd launch/stop/inspect; process evidence
│   ├── fleet-git.el                # worktrees, ownership, preservation evidence
│   ├── fleet-rpc.el                # local socket protocol and actor authorization
│   └── fleet-dashboard.el          # rendering/navigation; no state derivation
├── bridge/
│   ├── fleet_bridge.py             # stdio MCP + JSON socket client, Python stdlib
│   └── README.md                   # protocol and installation, not another doctrine
├── prompts/
│   ├── commander.md                # canonical commander instructions
│   ├── operator.md                 # canonical common operator instructions
│   ├── change.md
│   ├── study.md
│   └── stop.md
├── schema/
│   ├── 001.sql                     # initial database schema
│   ├── rpc-v1.json                 # requests/responses/error codes
│   └── tools-v1.json               # MCP schemas and role visibility
├── docs/
│   ├── design.md                   # implementation's maintained version of this TDD
│   ├── eca-compatibility.md        # tested pairs, anchors, required ordering evidence
│   ├── recovery.md                 # incident recovery, backup/restore, park failures
│   └── testing.md
└── tests/
    ├── fleet-store-tests.el
    ├── fleet-core-tests.el
    ├── fleet-supervisor-tests.el
    ├── fleet-eca-tests.el
    ├── fleet-runtime-tests.el
    ├── fleet-git-tests.el
    ├── fleet-rpc-tests.el
    ├── fleet-dashboard-tests.el
    ├── test_bridge.py
    ├── fake_eca.py                 # Content-Length JSON-RPC, scripted events
    └── fixtures/
        ├── eca/                    # redacted protocol traces, versioned provenance
        └── dashboard/              # narrow/wide/unicode/error golden cases
```

Files own independent invariants; they are not an invitation to invent public class hierarchies. Keep
functions small and module boundaries real. Do not add one file per noun or several interchangeable
stores/runtimes.

`fleet.el` autoloads `fleet-new`, `fleet-dashboard`, `fleet-park`, `fleet-destroy`, `fleet-doctor`,
`fleet-watch-start`, `fleet-watch-stop`, `fleet-commander-stop`, and `fleet-commander-replace`. It does not
launch workers merely because the package was required.

### 3.4 Runtime tree

```text
~/.local/share/fleet/
├── fleet.sqlite3                   # authoritative typed records; WAL while open
├── owner.lock                      # stable kernel flock inode; never rename/delete
├── owner.json                      # descriptor, published only under the lease
├── fleets/
│   └── <fleet-uuid>/
│       ├── about.md                # user-editable project context; optional
│       ├── commander/
│       │   ├── context.md          # explicit human/commander handoff
│       │   └── runs/<runtime-uuid>/
│       │       ├── launch.json     # non-secret execution/config fingerprint
│       │       ├── transcript.jsonl
│       │       └── stderr.log
│       ├── tasks/<task-uuid>/
│       │   ├── brief.md            # human-readable current brief
│       │   ├── briefs/0001.md      # immutable brief revisions
│       │   ├── progress.md         # restart-relevant facts, commands, remaining work
│       │   ├── report.md           # study result / optional other result
│       │   ├── artifacts/          # named local outputs; no automatic pruning
│       │   └── runs/<runtime-uuid>/
│       │       ├── launch.json
│       │       ├── transcript.jsonl
│       │       └── stderr.log
│       └── .archive/<fleet-uuid>/  # archive-moved artifact tree after empty retirement
```

```text
~/.cache/fleet/
└── eca/<runtime-uuid>/             # per-runtime ECA cache root; not recovery authority
```

```text
$XDG_RUNTIME_DIR/fleet/
├── control.sock                    # authenticated local RPC, mode 0600
└── credentials/<runtime-uuid>.json # mode 0600, ephemeral, never an artifact/log
```

Human fleet/task names are labels and completion keys. UUIDs are durable identity. An archived fleet's name
can be reused without colliding with old buffers, events, callbacks, or artifact paths.

A completed task remains in the database with lifecycle `archived`; its directory stays under its fleet. Do
not move multiple task files piecemeal during teardown. Fleet destruction archive-moves the entire artifact
tree through the recoverable operation mechanism, then releases the active-name reservation.

Transcripts are diagnostic/reorientation artifacts, not an authoritative parser input. Store normalized
user/assistant/tool summaries with message IDs where available; do not store every streaming token in SQLite
or duplicate full sensitive tool arguments by default. A transcript flush failure is visible, but does not
invent task state. Reports and explicit progress remain the recovery contract.

## 4. Required repository AGENTS.md

The implementation must include a root `AGENTS.md` containing the following durable instructions, adjusted
only for verified implementation details:

> **Fleet's scope:** Single-host, ECA-native orchestration in Emacs with local, unsandboxed execution.
>
> **Architecture:** Emacs is the sole state writer and scheduler. `fleet-store.el` owns transactional facts
> and projections; `fleet-eca.el` alone knows ECA internals; `fleet-runtime.el` alone owns service lifetime;
> `fleet-git.el` alone authorizes workspace cleanup. The dashboard and Python bridge call these owners rather
> than duplicating policy.
>
> **Safety invariants:** Never infer execution death from a missing chat buffer, model completion from an idle
> spinner, successful delivery from a write to a pipe, or preservation from a status string. Never respawn
> until the predecessor's owned local execution is proven stopped. Never remove an adopted worktree or adopted
> branch. Never delete uncommitted work through normal teardown. Never merge or discard by inference.
>
> **Durability:** Events are durable before delivery is attempted. Reading is not acknowledgment. Mutation
> requests have idempotency keys. Long operations persist intent and advance through retryable steps; no
> database transaction spans a subprocess or network wait. Unknown results remain unknown and are not retried
> blindly.
>
> **Concurrency:** Exactly one supervisor owns a state root. Normal Emacs daemons are supported. Every
> asynchronous callback carries owner, fleet, task, runtime, and operation identity as applicable. State
> callbacks cannot mutate a replacement. UI actions and agent tools use the same admission checks.
>
> **Emacs:** Use `emacsclient` for development operations against an existing server; never run tests or exit
> functions in the user's working Emacs. A dedicated test server is allowed and required for integration
> tests. Keep process filters, timers, and interactive callbacks short; all Git, systemd, and RPC waits are
> asynchronous.
>
> **ECA:** Verify the installed frontend/server pair before coding against it. Keep private API assumptions
> listed in `docs/eca-compatibility.md` and covered by recorded/fake-server tests. Do not read undocumented
> ECA caches. Do not change ordinary non-Fleet ECA sessions or globally enable trust.
>
> **Code quality:** Prefer deleting special cases to adding knobs. Comments explain constraints, not code
> history or the next line. Use lexical binding, explicit identities, structured errors, argument vectors
> rather than shell command strings, and display-width-aware formatting. No generated state, credentials, or
> transcripts in Git.
>
> **Verification:** Add regression tests at the owning layer for every bug. Run ERT and Python tests using an
> isolated temporary data/runtime/worktree root; real model/provider calls are opt-in. Test crash boundaries
> and refusal paths, not only success. Verify dashboard keymaps in a live test buffer after reload. Never
> operate on real user fleets as a test fixture.
>
> **Docs:** Keep `quickstart.md` accurate for user-facing commands, keys, failure meanings, and restart/park
> workflows. `prompts/` is the single canonical source of agent doctrine. Do not duplicate the same doctrine
> in generated skills and several unrelated files.

These are contributor instructions. Runtime commander/operator prompts are separate and do not instruct agents
to edit Fleet itself unless Fleet is the actual task repository.

## 5. Native ECA compatibility boundary

### 5.1 Reference API candidates and their limits

These reference API candidates and version-sensitive behaviors guide source discovery. Verify each required
surface and its semantics against the installed home frontend/server pair; this table does not establish that
any particular API exists in that pair.

- **Surface:** `eca-create-session(workspace-roots)`
  - **Reference behavior to verify:** Creates a session object with process, chat map, roots, response
    handlers
  - **Design consequence:** Keep the returned object, never rediscover an operator via ambient root lookup.

- **Surface:** `eca-process-start(session, on-start, handle-msg)`
  - **Reference behavior to verify:** Starts a pipe subprocess and hands parsed messages to a supplied
    callback
  - **Design consequence:** Wrap the callback to normalize events before ordinary ECA UI handling. Do not
    implement another ECA wire parser.

- **Surface:** `eca-process-wrapper-function`
  - **Reference behavior to verify:** Wraps the command argv before `make-process`
  - **Design consequence:** Prefer this seam for a user-systemd launch; bind it only for Fleet startup.

- **Surface:** `eca-api-request-async` / `eca-api-notify`
  - **Reference behavior to verify:** Explicit-session transport
  - **Design consequence:** Send with an explicit chat ID and callbacks. Transport availability alone is not a
    delivery/turn guarantee.

- **Surface:** `eca-chat-open(session)`
  - **Reference behavior to verify:** Client-generated UUID and chat-buffer registration; verify whether a
    separate `chat/create` is required
  - **Design consequence:** Adapter records the registered chat explicitly. Validate first-prompt semantics on
    the installed server.

- **Surface:** `chat/prompt`
  - **Reference behavior to verify:** Parameters include `chatId`, literal `request-id`, `message`, `model`,
    `agent`, `contexts`, optional `variant`/`trust`
  - **Design consequence:** Preserve exact wire spelling. Do not substitute a task UUID for a request
    sequence.

- **Surface:** `chat/statusChanged`
  - **Reference behavior to verify:** `running` / `idle`, addressed by chat ID
  - **Design consequence:** Useful activity evidence; does not establish outcome or process quiescence.

- **Surface:** `chat/contentReceived`
  - **Reference behavior to verify:** Chat ID, optional parent ID, role, typed content
  - **Design consequence:** Normalize tool lifecycle and progress; do not confuse subagent events with the
    operator's own turn.

- **Surface:** `chat/promptStop`
  - **Reference behavior to verify:** Notification, not acknowledged request
  - **Design consequence:** `cancel-requested` is not `stopped`. Strong stop uses the runtime owner.

- **Surface:** `chat/askQuestion`
  - **Reference behavior to verify:** Server request with a deferred answer
  - **Design consequence:** Capture a pending question; do not let a background operator open a surprise
    minibuffer.

- **Surface:** `jobs/list`, `jobs/kill`, `jobs/update`
  - **Reference behavior to verify:** Frontend expects job operations
  - **Design consequence:** Probe support; even supported jobs are not a substitute for group stop evidence.

- **Surface:** `eca-chat-finished-hook`
  - **Reference behavior to verify:** UI hook, also used after stop/synthetic idle, may follow dispatch of
    queued prompts
  - **Design consequence:** Do not use as Fleet's authoritative completion boundary.

Known version-sensitive behavior to verify: `eca-chat-send-prompt` may select a session's last chat and invoke
composer bookkeeping. Fleet requires a verified targeted, composer-independent send path.

Cancellation may have a ten-second UI fallback that resets loading to idle without server acknowledgment;
check the installed frontend. Fleet must never treat a UI-only idle transition as permission to tear down a
workspace.

### 5.2 Adapter interface

`fleet-eca.el` exports a small concrete API, returning typed results/futures or accepting callbacks:

- `fleet-eca-probe` → versions, fingerprints, supported features, incompatibilities.
- `fleet-eca-start(runtime, launch-spec, event-sink, callback)` → connection and designated chat handles after
  initialization.
- `fleet-eca-submit(runtime, message-record, callback)` → accepted / rejected / outcome-unknown, with the
  strength of evidence recorded.
- `fleet-eca-request-cancel(runtime)` → cancellation requested only.
- `fleet-eca-answer-question(runtime, question-id, answer)` and approval/rejection operations → exact pending
  item only.
- `fleet-eca-snapshot(runtime)` → observed connection/chat/tool/permission state, not a new derivation of task
  state.
- `fleet-eca-visit(runtime)` and `fleet-eca-peek(runtime, lines)` → the real ECA chat or retained transcript.
- `fleet-eca-detach(runtime)` → unregister Fleet's observer/UI association after runtime stop; never claim to
  kill descendants.

Normalized events include `connection-ready`, `connection-lost`, `prompt-accepted` when verifiable,
`turn-started`, `turn-idle-observed`, `tool-preparing`, `tool-approval-required`, `tool-running`,
`tool-finished`, `question-opened`, `question-answered`, and `protocol-error`.

Every event carries the Fleet runtime UUID and owner epoch supplied by the adapter closure, plus observed
chat/tool/request IDs and a timestamp. Do not trust a task identity supplied inside model text. Filter ECA
subagent events by parent identity; their activity can keep a runtime non-quiescent but cannot finish its
parent task.

### 5.3 Version-sensitive implementation policy

Use public process and transport seams first. Verify whether the installed pair requires private
initialization, chat registration, or notification/request-dispatch access. Keep any required private access
in this file, listed by symbol and verified shape in `docs/eca-compatibility.md`.

If a public event subscription or targeted chat API exists in the home version, use it instead of advice.
Otherwise install narrow, idempotent advice only on Fleet-owned sessions, and remove it cleanly on package
unload. Non-Fleet sessions must take the original path unchanged.

Do not monkey-patch ECA source in place, permanently change global last-model variables, reuse private UI
loading variables as facts, or depend on buffer-name conventions for routing.

Fleet must own **human submission before UI mutation**, not merely intercept the transport. Verify the
installed frontend's ordinary `chat/prompt`, `busy-chat` `chat/prompt$tee`, and internal queue paths, including
whether ordinary send clears the composer before calling the transport. For Fleet chats, capture the complete
submission envelope (text, contexts/attachments, model/agent/variant) before clearing the draft. Durably admit
it to Fleet's lane first; on database/admission failure leave the draft unchanged. Busy-chat RET and explicit
queue actions enqueue in Fleet rather than steering the active turn. Queue inspection/removal operates on
Fleet's never-dispatched messages. Disable native automatic queue/steer dispatch only for Fleet-owned
sessions; retain a transport guard against bypasses. Programmatic wakes neither read nor clear a human draft.

V1 permits exactly one designated top-level chat per Fleet connection. Guard native new-chat/fork/open/restart
commands on these sessions: explain the restriction and offer Fleet's replacement action instead. Runtime
credentials identify a process, not the originating chat or native subagent. Native subagents must have Fleet
mutation tools excluded through a verified ECA policy/provenance mechanism if the home version cannot do
that, disable native subagent spawning in Fleet runtimes. Fleet operators themselves still run independently.
Filtering rendered child events alone is not caller authorization.

### 5.4 Required home compatibility spike: first implementation milestone

Before building the scheduler, create two test ECA runtimes and prove, without touching ordinary ECA sessions:

1. Explicit connection/chat routing, different roots/models, and silent background creation.
2. Programmatic prompt submission without reading or clearing a human draft.
3. Success/error response semantics and ordering of prompt acceptance, running, progress-finished, and idle.
4. Duplicate end notifications, tool errors, permission approval, pending questions, cancellation, and
   disconnect behavior.
5. Human sends from the Fleet chat pass through the same admission/recording path.
6. No ECA UI queue automatically sends another prompt after an apparent finish behind Fleet's back.
7. Per-runtime cache/environment isolation and global instruction/config discovery with the native server.
8. Global MCP configuration launches a bridge with the correct runtime environment; ordinary ECA sessions get
   no Fleet authority.
9. A shell child and a deliberately detached local child are both stopped with their runtime's systemd
   service. Repeat after killing only the Emacs-side process wrapper.
10. Neither creating nor stopping a Fleet runtime affects another Fleet runtime or ordinary ECA.

Record redacted protocol fixtures, exact versions/revisions, and observed ordering. Source inspection is
required where an event might be ambiguous; a single successful smoke test is insufficient.

**Do not invent capabilities.** Strong turn correlation and acknowledged cancellation are desirable upstream
improvements, but baseline Fleet must not pretend they already exist. The baseline can use a verified
serialized chat contract: at most one submitted turn, observe its start, consume its terminal activity event
once, and keep duplicate trailing idle/finished events from reopening the lane. Where no turn ID exists, the
supported adapter must establish the server's ordering sufficiently to attribute events. If late terminal
events can be misattributed to a subsequent started turn, or no acceptance ordering can be established,
autonomous dispatch is unsupported for that pair until a small ECA integration fix exists. Flag the exact
missing contract, not "version too old."

Optional capabilities must not become blockers for unrelated functionality: absence of durable chat resume is
fine; absence of `jobs/list` is fine because full service stop owns cleanup. An unknown pair permits read-only
dashboard/artifacts, doctor, and independent verified systemd stop/park, but no autonomous spawn or ambiguous
send fallback.

The compatibility profile must fill in an executable transition table, not just list available symbols:

- **Observation:** Positive prompt acknowledgment
  - **Required policy:** Name exact wire response/event and meaning; only then mark accepted.

- **Observation:** Running/content before acknowledgment
  - **Required policy:** Record observed execution immediately; retain acceptance as unconfirmed until the
    profile's verified evidence arrives. Never resend because the response is late.

- **Observation:** Transport error/rejection
  - **Required policy:** Distinguish definite pre-submission rejection from uncertain write outcome. Verify
    whether the transport can catch send errors without invoking the error callback; Fleet must supply its own
    watchdog.

- **Observation:** No acceptance evidence by bounded acknowledgment deadline
  - **Required policy:** Mark delivery-unknown, freeze lane, expose evidence. This deadline is not a maximum
    turn duration.

- **Observation:** Terminal activity event
  - **Required policy:** Name exact wire event, required preceding start evidence, and duplicate/late-event
    handling. Consume once; ignore UI-synthetic finish.

- **Observation:** Unknown lane recovery
  - **Required policy:** Only a verified server query proving outcome, or explicit human reconciliation
    followed by verified runtime replacement, can release it. Never automatically resend attempted/unknown
    text.

Record whether tool/background activity forbids another prompt for the supported pair. Native approval and
question replies are control responses to the active turn, not new queued prompts. Profile timeouts are
bounded protocol waits with explicit unknown outcomes, not optimistic idle fallbacks.

## 6. Runtime and process ownership

### 6.1 One designated chat, one native service

Each commander incarnation and operator incarnation gets:

- A random runtime UUID, never a timestamp-only generation.
- One native ECA server process, one explicit ECA session object, one designated chat UUID.
- A service name derived from that UUID, for example `fleet-eca-<uuid>.service`.
- A launch record committed before the process is started.
- A revocable Fleet RPC credential scoped to its role/fleet/task/runtime.
- A unique ECA cache root so separate same-repo sessions cannot compete for the same undocumented workspace
  cache.

Use display names `*eca:commander:<fleet>*` and `*eca:operator:<fleet>:<task>*` for the designated chats.
These names are presentation only; buffer-local runtime/fleet/task UUIDs and the stored ECA handles own
routing. Keep Fleet names stable when ECA supplies a conversation title; show that title inside the chat if
useful. A retained ended conversation uses a runtime-suffixed name so a replacement can take the active
display name without overwriting evidence.

No service restart policy. Systemd must not restart a model process independently of Fleet's durable operation
state.

Use a transient **user service**, not a PTY or a scope whose launcher lifetime is mistaken for worker
lifetime. The intended mechanism is `systemd-run --user --quiet --pipe --wait --collect --service-type=exec
--unit=<exact-unit>` with explicit `KillMode=control-group`, `Restart=no`, bounded stop timeout, working
directory, and the native ECA argv. Verify these options with the installed Arch version in milestone 9. Keep
protocol stdout exclusively for ECA; wrapper diagnostics go to stderr. Do not pass `--verbose` if it makes
native ECA write logs to stdout.

A finite shutdown timeout, such as 15 seconds before systemd's final kill, is a resource-lifecycle bound, not
a work-duration cap. Never time-limit healthy model work merely because it is quiet.

Launch with argument vectors. Explicitly propagate HOME, locale, PATH, ECA configuration/cache roots,
necessary provider variables, and Fleet socket/credential-file paths into the service. For each selected
variable, set it in the launch client's private environment and pass `--setenv=NAME` so systemd-run copies its
value; merely setting the client's environment does not guarantee service inheritance. Verify this on the
installed systemd. Never put secret values in recorded argv, logs, or `launch.json`; record variable names
only.

### 6.2 Workspace and instruction model

- Commander: a fleet-local working directory; explicit access to fleet artifacts and project context; it does
  not mutate project repositories.
- Change operator: ECA workspace and cwd are the task's actual canonical worktree.
- Study/ops operator: a task-local workspace directory; additional read context is listed explicitly in the
  brief. Study permission to inspect a repo is not permission to edit it.

Native ECA should discover context for the actual workspace, and unique roots reduce routing/cache ambiguity.
Explicit boot context includes canonical role doctrine, current brief, progress/report paths, and global
instruction locations that the verified native version does not discover automatically. Do not copy or edit a
project's `AGENTS.md` to smuggle Fleet configuration into it.

Install one Fleet MCP entry in the user's ECA configuration, referencing the absolute bridge executable. It
activates only when the runtime environment points to a valid Fleet credential. Outside Fleet it advertises no
privileged tools. Merge that one entry with a backup and user-visible diff; never overwrite existing
provider/MCP/rule configuration.

Prefer ordinary ECA configuration discovery over a generated replacement `--config-file`. Verify whether that
flag replaces default search or overlays it in the installed version. If a per-runtime overlay is needed for
role-specific native-tool permissions, first verify and document its merge/instruction semantics; preserve
existing user configuration and record only a non-secret fingerprint.

Models are ECA provider/model identifiers. Resolve commander/operator defaults from the user's explicitly
configured Fleet preferences or the verified ECA defaults at fleet creation; persist the effective selection.
Do not choose a named provider/model in this TDD. Per-task overrides are explicit. New ECA `config/updated`
events must not silently retarget already-configured workers to whichever model the user last selected
elsewhere.

### 6.3 Stop evidence

The only strong local-stop verdict is: the exact runtime's service is stopped/unloaded **and** its recorded
cgroup has no remaining processes, with an unambiguous successful query. A failed query or unknown unit
identity is `stop-unknown`, not `stopped`.

Record boot ID, exact unit, systemd `InvocationID` and `ControlGroup` when available. Query structured
`LoadState`, `ActiveState`, `SubState`, `MainPID`, `ControlGroup`, and pending job state asynchronously. Check
recursive cgroup emptiness via `cgroup.events` `populated=0`, not only direct `cgroup.procs` members.

- **Evidence:** Launch operation unresolved, including manager request still in flight
  - **Verdict:** Not stopped; resolve the launch barrier first.

- **Evidence:** Current-boot exact unit inactive/failed, no pending activation job, recorded cgroup recursively
  empty or verifiably removed
  - **Verdict:** Stopped.

- **Evidence:** Unit collected/not loaded, successful manager query, no pending activation, launch settled,
  recorded cgroup removed/empty
  - **Verdict:** Stopped.

- **Evidence:** Launch settled as never-created, manager confirms no unit/job
  - **Verdict:** Never launched; safe to replace.

- **Evidence:** Recorded runtime belongs to a previous boot
  - **Verdict:** That old local execution is gone; remote external jobs still require disposition.

- **Evidence:** Active/activating/deactivating unit or populated cgroup
  - **Verdict:** Still running/stopping.

- **Evidence:** Permission/query failure, unknown launch outcome, missing contradictory identity
  - **Verdict:** Stop-unknown; no replacement/removal.

If collection races publication of `ControlGroup`, reconcile the exact UUID unit's launch/job result; without
positive never-created or stopped evidence remain unknown. Never assume every "not found" string proves
termination. Match UUID unit names exactly, not process names or broad `pkill` patterns.

Stop asynchronously: persist stop intent → revoke mutation capability for the old incarnation → request
graceful ECA cancellation where useful → stop exact service → inspect until terminal or timeout → commit
evidence. UI state does not authorize the final transition.

On failure retain the task/worktree, display the unit and evidence, and refuse replacement or teardown. No
"force" option bypasses an unknown/live predecessor.

Cgroups contain ordinary local descendants, including double-forked children that do not explicitly escape the
cgroup. They do **not** undo completed writes, cancel already-submitted remote jobs, or prevent a same-user
process deliberately creating a new service. Operators must register externally surviving operations with
idempotency, cancellation/continuation policy, and a progress record. Park reports these separately; it cannot
promise they stopped.

This is process accounting, not a security sandbox. All agents share the user's Unix authority. Tool scoping
and doctrine prevent accidental cross-task control; they cannot provide a security boundary against arbitrary
malicious same-UID shell code.

### 6.4 Emacs ownership and restart

Acquire a kernel-held exclusive nonblocking `flock` on a stable `owner.lock` file under the canonical data
root. Never unlink or rename this lockfile during takeover. A small `fleet bridge my lease` helper holds the
descriptor for the Emacs owner's lifetime, reports acquisition over a private pipe, and exits on pipe
EOF/parent death. It is not a scheduler or RPC service. Publish boot ID, Emacs PID, kernel process-start
identity, random owner UUID, and socket path in a separate atomic descriptor while holding the lock.

The helper's death fences the owner immediately: every mutation/launch admission checks the live lease
handle/epoch. A new lock acquirer also checks the previous descriptor: if the previous Emacs identity is still
alive and has not explicitly released ownership, refuse takeover even if its helper died. This closes the
helper-death/live-Emacs gap. Unknown/corrupt identity requires explicit recovery, not PID guessing. Normal
release first fences new work, settles launch operations, verifies all owned operator and commander runtimes
stopped, closes writable DB/RPC, marks released under the lock, then releases the descriptor. Kernel lock
acquisition, not an inspect-then-rename sequence, serializes competing reclaimers.

A second Emacs is read-only in v1: it opens SQLite read-only snapshots and directs interactive actions to the
owning Emacs. It neither controls native chats it does not own nor acquires agent credentials. Missing local
buffers never imply death. The lock belongs to the data root; runtime sockets/descriptors use a short root
hash to avoid collisions. Keep Unix socket paths below the platform limit.

The owner can be an ordinary interactive Emacs or an Emacs daemon. "Daemon" is not a safety test.
`fleet-watch-stop` pauses model dispatch, not ownership or critical process/event observation.

After an Emacs restart, old stdio connections are not reattached. Reconcile every nonterminal runtime against
its exact service. Stop surviving old services, retain evidence, mark affected tasks suspended/recoverable, and
require explicit Fleet resume before restarting operators. If the old owner might still be alive without a
verified released descriptor, do not take over. Explicit normal release permits a new owner while that old
Emacs remains open read-only. Do not generate an automatic restart/wake storm on opening Emacs.

## 7. Durable model and transactions

### 7.1 Identities and entities

Use UUID text keys, UTC timestamps for durable ordering/display, and a monotonically increasing database
event sequence. Use monotonic time for in-process timeouts; recompute persisted deadlines after restart.

Minimum entities:

- **Table:** `meta`
  - **Required facts:** Schema version and creation/version metadata.

- **Table:** `fleets`
  - **Required facts:** UUID, active name, lifecycle `active/parking/parked/retiring/archived`, supervision
    flag, project context path, commander model policy, created/updated times. Unique active name.

- **Table:** `tasks`
  - **Required facts:** UUID, fleet, active task name, kind `change/study/ops`, lifecycle
    `draft/ready/active/suspended/closing/archived`, semantic phase, latest detail/time, brief revision/hash,
    repository/workspace and ownership facts, delivery mode, current runtime, wait/dependency facts.

- **Table:** `runtimes`
  - **Required facts:** UUID, owner epoch, role, fleet/task, service/cgroup identity, connection/chat IDs when
    assigned, model/agent/variant, lifecycle, launch/stop evidence, last observed activity. Old rows retained.

- **Table:** `events`
  - **Required facts:** Sequence, UUID, fleet/task/runtime, kind, payload, source, actor, client operation ID,
    timestamp. Durable semantic events only.

- **Table:** `event_receipts`
  - **Required facts:** Event, consumer role/fleet, handling state, claim batch/commander runtime, outcome and
    acknowledgment time.

- **Table:** `messages`
  - **Required facts:** UUID/idempotency key, sender, target runtime/task, origin, text or immutable body
    path/hash, delivery state, ECA request identifiers, evidence, time.

- **Table:** `operations`
  - **Required facts:** UUID, kind, target, expected revision/runtime, current step, intent/evidence/error,
    start/update time. Recovery journal for multi-step external effects.

- **Table:** `artifacts`
  - **Required facts:** Task, kind, managed relative path or external path/URL, description, expected
    commit/digest, verification bound to brief revision/hash and actor/evidence.

- **Table:** `wake_batches`
  - **Required facts:** Claimed receipt set, message ID, commander runtime, reminder-used bit,
    delivery/reconciliation state.

- **Table:** `actions`
  - **Required facts:** Logical actor/action UUID, canonical payload digest, linked event/batch and
    operation/result; survives runtime replacement.

- **Table:** `decisions`
  - **Required facts:** UUID, task/brief revision, question/options, authority required, state
    open/resolved, answer/actor/evidence, correlated reply message.

- **Table:** `external_jobs`
  - **Required facts:** UUID, task/runtime, external system/job identifier, state, completion source, deadline,
    cancellation policy and disposition.

- **Table:** `resource_claims`
  - **Required facts:** Exclusive canonical workspace or explicitly named mutable external resource, owning
    task/operation.

Foreign keys on; WAL enabled; durable writes configured for synchronous commit (`synchronous=FULL` initially);
busy wait bounded so a stray writer cannot freeze Emacs. Fail on unsupported schema, unsafe filesystem, or
invalid relationships. Support migrations only under owner lock, with a consistent pre-migration backup. Do
not let an older package open a newer schema for writes.

The event log is an audit/delivery record, not a mandate for full event sourcing. Typed tables are current
authoritative facts; update them and append semantic events in the same transaction. The dashboard and tools
read one shared snapshot/projection function. Do not independently derive state from Markdown, timestamps, or
transcript text.

### 7.2 Facts that must stay separate

A task can simultaneously be:

- semantic phase `done`;
- runtime observed busy finishing its final response;
- report unverified;
- Git branch pushed but not integrated;
- lifecycle active until teardown completes.

Never collapse these into one mutable `status` field. The UI's primary state is a projection, not the complete
lifecycle.

Operator phases: `working`, `needs-decision`, `blocked`, `paused`, `done`, `failed`. Operator status is
accepted only from the current runtime credential and current brief revision. Terminal scope cannot be changed
back to working except through an explicit retask operation. A failed task may be retried with a durable
corrective note; a done task always requires new tasking.

### 7.3 Durable document updates

Fleet creates/revises briefs with a temporary file in the same directory, flush/close, atomic rename, then a
transaction referencing the immutable revision path/hash. Keep an operation record covering the file/DB
boundary so interrupted publication is recoverable. A revision is not runnable until both the canonical file
and recorded digest agree. Never silently replace a runnable brief under an active operator; retasking creates
a new revision and a visible scope boundary.

Agents may edit `progress.md` and `report.md` through normal file tools. Completion includes artifact
registration; commander verification reads actual files rather than trusting a path exists. A report missing
after `done` is a verification failure, not successful teardown. `fleet_artifact_verify` records
criteria/evidence against the exact brief revision and artifact hash/commit OID. Changed contents or scope
invalidate the verification. Rehash/recheck after runtime stop before cleanup; an old verified flag cannot
bless a report changed afterward.

Fleet-managed document/message/transcript paths are stored relative to the fleet's authoritative
`artifact_root`, with task-relative identities underneath. External/adopted paths and URLs remain absolute.
Fleet retirement records old/new roots, renames, and commits the new root; recovery resolves the in-progress
operation when rename happened before DB commit. Do not rewrite hundreds of absolute paths or leave archived
pointers broken.

### 7.4 Long operations

No open SQL transaction around Git, ECA, systemd, filesystem copying, or network calls. Use a short
transaction to admit/reserve, external asynchronous work, then a short transaction to record the result.
Recheck expected task/runtime/revision and relevant Git facts after awaits.

Examples: create workspace, start runtime, stop/park, retask/replace, teardown, fleet archive. Each operation
is resumable by inspecting reality. Do not repeat a non-idempotent external action because a callback was
lost.

- **Operation barrier:** one task-lifecycle operation at a time; a fleet parking/retiring operation excludes
  new starts/replacements and waits for every previously admitted launch operation. Commit launch intent and
  exact unit identity before calling systemd. Every pre-barrier launch must settle as proven never-created or
  created-and-verified-stopped before park/retire can commit. An absent unit while its launch request is in
  flight is not a settled launch. Stale callbacks may record/clean up their operation's external effects, but
  cannot make themselves the current runtime. After owner loss, only the new owner performs that reconciliation
  from the journal. Test delayed successful launch completion arriving after park begins.

- **Revisions:** `brief_revision` changes only when task scope is explicitly revised; `entity_revision`
  advances on authoritative mutation of that fleet/task; `snapshot_revision` is a global commit sequence used
  for coherent reads/rendering. Runtime observations have their own revision so streaming UI updates do not
  invalidate a human scope confirmation. Mutating requests state expected entity/brief revisions where
  relevant; do not confuse the three counters.

- **Dependencies/resources:** task creation rejects cycles and missing/cross-fleet dependencies. A dependency
  is satisfied only by an explicit verified-success milestone for its recorded brief revision, not by runtime
  idle or teardown. Failed/revised prerequisites hold dependents ready-but-blocked until the commander
  explicitly revalidates scope. Canonical workspace claims persist through suspension until teardown; named
  external-resource claims persist until declared release/completion, not merely local runtime death. These
  claims prevent Fleet-scheduled concurrent mutation, not arbitrary same-user external edits.

Filesystem paths are resolved from server-side identities, never from arbitrary RPC path concatenation. Names
use a simple documented grammar such as `[A-Za-z0-9][A-Za-z0-9._-]*`; generated filesystem names are bounded
and disambiguated by UUID. Reject traversal, NUL, invalid encoding, and unexpected symlink destinations before
mutation.

## 8. Agent/control interface

### 8.1 Local RPC

`fleet-rpc.el` serves a Unix-domain stream socket, mode 0600 beneath a 0700 runtime directory. The bridge uses
newline-delimited UTF-8 JSON **for this Fleet socket protocol**, not ECA's Content-Length protocol. Newlines
inside text are JSON escaped.

Requests contain `protocolVersion`, `id`, `operation`, `idempotencyKey` for mutations, credential, and a
schema-validated `params` object. Responses contain the matching ID and either a structured result or
`{code,message,evidence,retryable}` error. Define bounded request size and pagination as protocol resource
limits, not as arbitrary task/model limits; reject oversize input explicitly.

Read operations return immediately from snapshots. Long mutations return an operation ID; the caller may
inspect it once if necessary, but the commander must not poll it in a loop. Completion is a durable event, and
the normal supervisor delivers it. Socket filters parse/validate/enqueue only; no Git or systemd wait inside a
filter.

MCP bridge responsibilities are framing, schema advertisement, forwarding, and cancellation/disconnect
reporting. It does not know task-state precedence, Git gates, or wake scheduling. It must not write SQLite.

Use a small standard-library Python implementation for the narrow stdio MCP surface: initialize/version
negotiation, initialized notification, ping, tools/list, tools/call, and protocol errors. Pin supported MCP
protocol versions and test against the actual ECA client; do not invent a private MCP dialect. If implementing
this correctly becomes larger than using the official MCP SDK, use one pinned SDK dependency instead and
document the change—do not build a general MCP framework.

No unrestricted `eval` RPC. No interpolation of arbitrary prose into Elisp or shell command strings. An
optional diagnostic CLI is the same bridge in `rpc` mode, not a second implementation; it is not required for
day-to-day use.

### 8.2 Actor capabilities

- **Actor:** Human through Emacs
  - **Authority:** Create/resume/park/retire fleets; task operations; explicit decisions; sensitive
    confirmations.

- **Actor:** Commander runtime
  - **Authority:** Read its fleet; create/brief/start/retask operators within scope; send messages; inspect
    evidence; acknowledge events; request normal teardown.

- **Actor:** Operator runtime
  - **Authority:** Read its own brief/snapshot; publish its own status/progress/artifacts; request a decision;
    register waits/external jobs. No spawning, fleet retirement, sibling control, or authoritative metadata
    writes.

- **Actor:** Ordinary ECA session
  - **Authority:** No Fleet mutation authority merely because the MCP entry exists.

The credential record binds actor to runtime; Fleet derives fleet/task identity from it. A task ID argument
cannot grant authority. Revoke credentials on park/replacement; reject stale-incarnation status atomically
with task updates. Keep tokens out of prompts, transcripts, tool results, and database export. This is
accidental-misuse protection under one Unix user, not hostile-agent containment.

Native ECA shell/file tool policy is separate from Fleet RPC capability. Preserve the user's ECA policy; Fleet
must not bypass permissions or enable blanket trust. Where native ECA supports role-specific tool allowlists,
apply the narrow verified policy. Otherwise permissions/questions become actionable dashboard/commander
events, never an excuse to auto-accept a dialog. Full unsandboxed autonomous shell access is an explicit user
choice, not an installation default.

### 8.3 Required tools

Expose compact tools with precise enums rather than a large family of aliases:

- **Tool:** `fleet_snapshot`
  - **Inputs/result summary:** Scoped fleet/task snapshot, states, pending operations, artifacts, attention.

- **Tool:** `fleet_task_create`
  - **Inputs/result summary:** Task name/kind; complete brief text; repo/base/ownership/delivery where
    applicable; dependencies/resource claims. Validates and produces ready task or structured refusal.

- **Tool:** `fleet_task_start`
  - **Inputs/result summary:** Ready/suspended task, expected revision; returns operation ID.

- **Tool:** `fleet_task_retask`
  - **Inputs/result summary:** New durable tasking and expected revision; replacement only after old runtime
    stop proof. Done tasks require nonempty new scope.

- **Tool:** `fleet_message_send`
  - **Inputs/result summary:** Target operator, text, idempotency key; records a
    queued/accepted/rejected/unknown message, never a terminal key.

- **Tool:** `fleet_status`
  - **Inputs/result summary:** Current runtime's phase/detail, optional structured decision/wait/artifact
    references.

- **Tool:** `fleet_artifact_register`
  - **Inputs/result summary:** Named path/URL, purpose, expected identity; not automatically verified.

- **Tool:** `fleet_artifact_verify`
  - **Inputs/result summary:** Commander/human-only result bound to brief revision and artifact hash/OID;
    acceptance evidence and any limitations.

- **Tool:** `fleet_decision_resolve`
  - **Inputs/result summary:** Commander within scope, otherwise human; exact decision ID, answer, authority,
    expected revision. Resolves the decision separately from sending its answer.

- **Tool:** `fleet_external_job`
  - **Inputs/result summary:** Register/update job identity, system, owner, state, cancel/continue policy,
    completion source and deadline; never arbitrary executable monitor text.

- **Tool:** `fleet_events_pending`
  - **Inputs/result summary:** Non-destructive paginated events plus current snapshot revision.

- **Tool:** `fleet_events_ack`
  - **Inputs/result summary:** Explicit event IDs and disposition/evidence; only after handling or durably
    recording a user decision.

- **Tool:** `fleet_wait`
  - **Inputs/result summary:** Reason, bounded deadline, external job ID if applicable, and who/how completion
    will be reported.

- **Tool:** `fleet_cleanup_evidence`
  - **Inputs/result summary:** Read-only preservation/ownership/quiescence evidence for a task.

- **Tool:** `fleet_task_teardown`
  - **Inputs/result summary:** Normal verified teardown request; no autonomous force/discard parameter.

- **Tool:** `fleet_operation`
  - **Inputs/result summary:** Inspect an asynchronous operation by ID; no long-poll requirement.

Use the same internal operations for dashboard/M-x and RPC. An agent cannot skip a safety check by choosing a
tool instead of a key.

## 9. Message delivery and zero-token supervision

### 9.1 Message state machine

`queued → dispatching → accepted → turn-observed → finished`, with branches `rejected`, `delivery-unknown`,
and `cancelled-before-dispatch`.

- Commit queued text and a client idempotency key before attempting submission.
- Admit at most one in-flight prompt per designated chat. Human messages and commander messages use the same
  lane.
- Commit `dispatching` with the target runtime before writing the ECA request.
- `accepted` requires verified protocol evidence from the supported adapter; a write to stdin is insufficient.
- Request response, turn end, task done, and artifact verification are different events.
- On disconnect/crash in the write/acceptance window, mark `delivery-unknown`. Do not automatically resend the
  text, press Enter, or turn it into a new task.
- Before dispatching queued work, verify the target is still the current runtime and the brief revision
  matches. Never silently send an old answer into a replacement chat.

There is no blanket exactly-once delivery claim. Without a server-side idempotency/query API, uncertain
delivery requires reconciliation. Fleet's own mutations are idempotent by **durable logical actor + action
UUID**, not runtime UUID. Current runtime credentials authorize a call, but action identity survives commander
replacement. Commit a synchronous mutation and its action receipt in the same transaction; commit an
asynchronous operation intent, action mapping, and handling linkage together before any external effect. After
authorizing the current actor, resolve an existing action key/payload before fresh-operation
revision/admission checks, so the original mutation's revision advance does not reject its own retry.
`fleet_events_pending` includes already-started actions so a replacement inspects/resumes them instead of
inventing new IDs. Reject the same action key with changed payload. This prevents replay of the same recorded
action, not arbitrary semantically duplicate plans invented under different keys.

A message accepted by an operator after its last status adds `sent since:<summary>` to detail until a new
applicable status arrives.

### 9.2 Durable event handling

Actionable events include task done, decision requested, blocked, failed, unexpected runtime death,
delivery-unknown, wait deadline expiry, operation failure, permission/question requiring intervention, and
task-start/cleanup results that need commander continuation.

Ordinary working updates, streaming output, and token/tool progress update views but do not wake a model. Do
not send a wake because a timer ticked.

In one transaction: record status/fact → append semantic event → create an unhandled receipt. Only then
schedule a commander notification. File notification is not part of correctness.

Delivery rule:

1. If fleet parked/parking, supervision paused, commander unavailable/busy, human draft present, or the
   **commander** has a pending permission/question: retain the event and do not inject. An operator's pending
   question is a reason to wake, not suppress, the commander.
2. In one short transaction select eligible pending receipts, claim them under a new batch, and insert exactly
   one queued wake message containing concise facts/artifact pointers. Enforce one active batch claim per
   receipt. Reentrant scheduling callbacks cannot claim it twice.
3. Persist the wake message/batch identity before submit.
4. Commander reads events non-destructively, takes durable-action-ID mutations, then acknowledges specific IDs
   with outcomes.
5. An event reaching a chat or being read does not acknowledge it.

Receipt states are `pending` → claimed → acknowledged, with `held-unknown` and needs-reconciliation branches.
A pre-dispatch cancellation or definite rejection releases claims to pending, but a rejection incident blocks
immediate auto-retry until resolved. Accepted/finished delivery retains claims until ack. Delivery-unknown
holds claims and freezes the lane. After verified commander replacement, unresolved claims become
needs-reconciliation, carrying prior message/action evidence; never blind replay of side effects. A queued
wake deferred by a human message retains its claims/message and simply waits. The one-reminder-used bit is
persisted on the batch and cannot reset on restart. A second unacknowledged finish holds the batch for
human/recovery action, not another model reminder.

Claim/ack semantics are at-least-once. A commander crash releases that incarnation's claims for
reconciliation; it does not erase them. Do not coalesce distinct user questions into one forgotten "latest
task state." Multiple redundant progress-derived hints can point to one outstanding attention incident, but
retain their event identities and evidence.

If a commander finishes a turn with unacknowledged events, do not create an immediate self-wake loop. Keep the
receipt outstanding, show attention, and permit a single bounded protocol-reminder for that handling batch;
repeated failure stops automatic dispatch for that batch until new user action or explicit recovery. This is
protocol-error handling, not periodic supervision. Acknowledged/deferred decisions have durable records
explaining who must act next.

Human messages take priority over pending automatic wakes. An existing commander draft is not overwritten,
sent, or cleared by Fleet; display pending-wake count and retry admission on a relevant composer/turn event.
Do not busy-poll a draft every second.

The dashboard never drains or acknowledges events. There is deliberately no `d` drain key. An optional later
nudge command would ask the commander to process its own queue; it would not consume anything.

### 9.3 Waits and state detection

Use structured ECA events and runtime evidence for activity and failure detection; silence alone leaves
uncertainty.

- A permission prompt/question immediately becomes a structured pending item.
- A lost process/transport becomes an execution observation and actionable event once per incident.
- A declared wait has a reason and deadline. A timer emits one deadline-expired event if no subsequent
  phase/completion superseded it.
- External/local jobs include stable identity and a completion path. Local ECA job events can satisfy a
  declared wait when supported.
- An active tool call can be displayed with elapsed time; long duration alone does not prove it is wedged.
- Silence while a model/tool is running is not grounds to interrupt or respawn it.

Do not build arbitrary authenticated shell polling scripts into v1. For a remote job without notifications,
the operator must arrange a bounded existing monitor or stop with a documented wait that produces a deadline
event. Fleet does not repeatedly spend tokens asking whether it finished.

## 10. Lifecycle commands and algorithms

### 10.1 `M-x fleet-new`: create or resume

Completion lists active and parked fleets. A new valid name requires confirmation. For an existing name,
branch on fleet lifecycle *before* commander liveness: parked/recoverable always offers explicit resume versus
visit-only, even if its retained commander is alive. For an already-active fleet with a live commander, visit
that exact chat and show the dashboard instead of erroring or duplicating it. Visiting alone never changes a
parked fleet to active.

New fleet flow:

1. Doctor/admission checks; acquire the owner if needed.
2. Create fleet UUID, artifact roots, configuration snapshot, and persisted commander-start operation.
3. Launch native ECA commander and wait asynchronously for verified initialization/readiness.
4. Submit a self-contained boot payload containing the canonical commander doctrine, scoped Fleet
   identity/tools, current snapshot, and context paths.
5. On readiness, show commander plus dashboard without arbitrary rearrangement of unrelated windows. Operator
   creation remains entirely background-only.

Existing parked/recoverable fleet flow:

1. Reconcile old runtime identities and prove any predecessor stopped.
2. Ask whether to resume operator execution; summarize pending/finished/suspended tasks. Preserve one explicit
   confirmation rather than silently waking an abandoned fleet on startup.
3. Bring up/visit commander, provide a deterministic recovery summary and durable context paths, then permit
   it to start unfinished tasks under existing scope.
4. Done tasks are verified/finalized, not rerun. Tasking needs no remembered fleet path; completion supplies
   the existing names.
5. Review held messages; never-attempted messages may be explicitly rebound to a replacement under unchanged
   scope, preserving original identity and recording the disposition. Attempted/unknown messages are never
   silently rebound or resent; reconcile their effects first. Cancel obsolete answers by exact
   decision/message identity.

Recovery uses `about.md`, commander `context.md`, briefs, and progress. The user or commander can record an
explicit handoff in `context.md` with decisions, next steps, and artifact pointers.

### 10.2 Task creation and start

Validate kind, complete brief, dependency identities, workspace ownership, delivery intent, and resource
conflicts. Do not create dummy metadata pointing to a decoy branch while prose redirects work elsewhere.

Change workspace modes:

- **New work:** Fleet creates a branch/worktree from an explicit verified base ref; owns both.
- **Adopt branch:** use an existing local/remote branch and create a Fleet-owned worktree; Fleet owns the
  worktree, not the adopted branch. Refuse if native Git says the branch is already checked out elsewhere.
- **Adopt worktree:** validate exact canonical repository/worktree/HEAD identity; adopt neither directory nor
  branch ownership. Acquire exclusive task claim to prevent concurrent writers.

Task IDs/names are not branch names by accident. Resolve repository branch policy from its instructions or
explicit brief; default to a simple Fleet-qualified branch only when no project rule contradicts it. Never
assume `master` over `main`, `origin` over another remote, or that a repo has a remote at all. Persist repo
common-dir identity, chosen remote/default/base ref, and resolved base OID.

Starting a task reserves its workspace/resource claims, creates a runtime incarnation, launches it, and
submits one boot payload containing role doctrine, immutable brief revision, progress path, existing
Git/workspace facts, and current scope. Report ready only after initialization and evidenced submission;
launching a process is not a successful dispatch.

If startup fails, keep the brief/worktree and an inspectable failed operation. Do not erase useful evidence or
automatically create a second worktree.

### 10.3 Retask / replacement

Unfinished suspended/dead work can resume from the same brief/workspace after predecessor stop proof. New
scope appends a durable revision/change note. Done tasks require that note; do not run the old completed brief
again.

A live active worker is not replaceable just because another model thinks it is stuck. Normal replacement
first requests an explicit interrupt/stop through the owning runtime, waits for stop evidence, revokes its
credential, then starts a new incarnation. Never have two current runtime credentials for one task.

### 10.4 `M-x fleet-park` / dashboard `X`

Park means **stop operators, retain the commander and all durable work**. The commander's continued presence
lets the user finish a handoff/context note before closing it.

Both entry points confirm, including live operator count, running tool count, and declared external jobs. M-x
and dashboard semantics must not diverge.

1. Persist fleet `parking` before beginning cancellations. Block new operator starts/sends, commander
   auto-respawn, and ordinary wake dispatch.
2. Preserve queued messages as held; cancel only those explicitly abandoned by the user. Do not turn them into
   lost tasking.
3. Revoke operator mutation credentials and stop every owned operator service, including ones whose buffers
   disappeared.
4. Wait asynchronously for local stop evidence. Keep worktrees, metadata, briefs, progress, reports,
   transcripts, and events.
5. Mark stopped unfinished tasks `suspended`; preserve done/failed semantic phases.
6. When all operators are confirmed stopped **and every pre-parking launch/replacement operation has crossed
   the section 7.4 barrier**, commit fleet `parked`. Suppress expected death wakes, not genuine stop failures.
7. On failure stay `parking` with an attention item and exact service evidence. Do not print "parked" while a
   worker might still run.

Park retains task resources and the commander; context handoff is explicit. It never discards work. "Preserves
work" means persisted files/history survive; it does not guarantee saving uncommitted in-memory model
reasoning, completing a partially written file, or cancelling remote external jobs. Park explicitly lists
known external jobs left running; unregistered remote actions cannot be reliably discovered.

While parked the commander can chat, inspect, and update its context note, but cannot start operators until an
explicit human resume. Existing in-flight commander actions are revalidated at their mutation commit points.

### 10.5 Task teardown (`t`)

Teardown ends one task's supervision and releases/removes only resources safe to release/remove. Default
eligibility is done + verified deliverables; failed/abandoned work requires a human close decision with
preservation/ownership handling, not a forged `done` status.

Flow:

1. Admit closing against expected task revision; block new sends/starts and take task/repo claims.
2. If currently executing, request a normal stop only with explicit user authority, or wait for observed turn
   end when task has just reported done. Never infer idle from done. Commander normal teardown should return
   `waiting-for-runtime-idle`/operation progress rather than sleep in a tool call.
3. Prove the runtime stopped locally before destructive workspace cleanup. Teardown may stop an idle native
   server; it never relies on ECA idle to prove child quiescence.
4. Obtain and persist Git/artifact/ownership evidence; recheck workspace HEAD and cleanliness after
   asynchronous remote checks and immediately before removal.
5. Remove only Fleet-owned worktree using native `git worktree remove`. On dirty/locked/broken/uninspectable
   tree, refuse with evidence. Never fall back to `rm -rf`.
6. Apply section 11.3's resource table first: never attempt deletion of a local-ready or adopted branch. For
   other Fleet-owned branches, optionally try native `git branch -d` after their own preservation/retention
   proof. Never `-D`; a refusal retains the branch with a visible warning.
7. Mark task archived, release claims, revoke credentials, retain artifacts/history. Failures leave an
   operation that can be retried from its completed step.

Full service stop is inexpensive because each operator owns a dedicated native server, and it makes the
cleanup invariant substantially simpler than proving every ECA job ended individually.

### 10.6 `M-x fleet-destroy`

Retire an **empty** fleet, not recursively clean a project. No dashboard key by design; no commander tool.

Require no unarchived tasks, no unresolved task operations, no operator services, and commander absent or
admitted for an explicit idle stop. Show confirmation that artifacts will be archived and the name released.
Stop the commander with the same verified service lifecycle, recheck admissions after awaits, persist retiring
intent, archive-rename the fleet artifact tree, then mark archived/release name in a transaction. Resume the
operation after any file/DB boundary interruption.

Never delete its database history, reports, or work. Failed rename must leave the fleet visible and
recoverable; it must not silently lose supervision registration. Active-name reuse happens only after
successful retirement commit.

### 10.7 Other core M-x commands

- `fleet-dashboard`: create/show live view; acquire ownership when eligible or use second-Emacs read-only mode.
  Preserve each fleet's persisted supervision flag; opening/refreshing the dashboard never re-enables paused
  dispatch or resumes parked fleets. New fleet creation explicitly enables its initial supervision;
  `fleet-watch-start` explicitly re-enables a pause.
- `fleet-watch-start`: idempotently enable event dispatch and observation under owner authority; replay
  durable pending events according to admission.
- `fleet-watch-stop`: pause automatic model dispatch, not runtime ownership, event persistence, or
  stop/failure observation. Display supervision paused.
- `fleet-doctor`: read-only compatibility/config/owner/DB/runtime/worktree checks with evidence. Expensive
  checks asynchronous. Repair actions require explicit named confirmation and share the operation machinery.
- `fleet-commander-stop`: human-only explicit commander stop, with confirmation when active/unknown; uses
  service stop evidence and keeps all operator/task state. In an active fleet, auto-dispatch waits for a
  replacement commander; operators are not implicitly parked. Document parking first for end-of-week use.
- `fleet-commander-replace`: human-only stop-then-start on the same fleet with context/reconciliation payload.
  Cannot overlap commander incarnations. Available as a doctor recovery action as well as M-x.

Closing/burying a chat buffer only hides it; intercept destructive native session close/restart on Fleet
sessions and direct the user to these commands. Do not pretend buffer kill is verified shutdown.

A separate `fleet-resume` command is not necessary for v1; `fleet-new` already provides completion,
existing-session visit, and explicit resume. Add an alias only if actual use demonstrates a discoverability
problem.

## 11. Git preservation and cleanup policy

### 11.1 Three questions, three results

1. **Preserved:** Will the work remain reachable after removing a disposable worktree?
2. **Integrated:** Is the work included in the intended target branch?
3. **Owned and safe to remove:** Does Fleet own this resource, and will native Git permit its removal without
   losing dirty/detached work?

A pushed open PR may satisfy preservation without integration. A local-ready branch is a valid deliverable
when the brief says so, but must remain durably retained. Artifact verification is a separate task-level
requirement.

### 11.2 Evidence algorithm

Inputs: canonical repo/common-dir, actual worktree HEAD and branch, recorded branch identity/ownership,
selected delivery remote/default target/base, task delivery mode, and whether adopted resources will be left
intact.

Collect:

- `git status --porcelain=v1 -z --untracked-files=all --ignored=matching --ignore-submodules=none`, plus
  explicit recursive inventory where ignored directories/submodules can hide contents; parse without shell
  whitespace assumptions. V1 refuses owned-worktree removal while ignored content remains, rather than
  assuming ignored means disposable. Operators should put lasting artifacts in task storage and clean only
  outputs whose disposal is already authorized by the brief. Never auto-run `git clean -fdx`. This
  conservative policy includes ignored human notes.
- Actual HEAD and symbolic branch; missing/invalid/uninspectable are different outcomes.
- Relevant refs and native worktree registrations.
- Remote advertisement/fetch evidence when remote preservation/integration is claimed; do not hardcode
  `origin/master`.

Positive proofs:

- **Remote-preserved:** work tip equals an advertised branch head, or is an ancestor of an advertised head
  whose object was verified/fetched. Arbitrary branch names are valid. This is not a PR merge proof.
- **Integrated by ancestry:** work tip is an ancestor of the explicitly trusted target OID.
- **Integrated by equivalent change:** stable Git patch evidence against the trusted target, described below;
  report equivalence separately from ancestry.
- **Local-retained:** for an explicitly local-ready delivery, create/verify a durable Fleet retention ref such
  as `refs/fleet/retained/<task-uuid>` at the exact tip using Git's ref transaction/CAS semantics, and record
  it as a retained deliverable. Keep the task branch as well. This does not claim remote backup or merge.

A remote outage does not magically verify a remote target. Default to refusal for a remote-required delivery
when fresh proof is unavailable. Offer an explicit human switch to local-retained delivery; do not silently
change the contract.

For remoteless repos, resolve the explicit local target and use ancestry/equivalence, or local-ready
retention. Do not require a remote to use Fleet.

Stable patch-ID equivalence should cover the real squash/rebase-and-squash use case without becoming a
hosting-specific PR scraper:

1. Find merge-base of work tip and verified target.
2. Build patch-ID evidence for target non-merge commits since the base.
3. Compare the branch's cumulative change to a target patch; otherwise require every branch commit's
   individual patch to match.
4. Account for all branch commits; merge/empty-diff commits cannot silently disappear from the proof count.
5. Any Git error, missing object, ambiguous base, unsupported binary/mode/submodule change, or incomplete
   evidence produces no equivalence proof. Do not guess.
6. State clearly that Git patch IDs are normalized patch equivalence, not semantic program equivalence or
   byte-for-byte identity. Prefer ancestry/retention when available.

Do not generate synthetic commits, query all hosting providers, or use a PR-status string as the preservation
gate. If equivalence cannot prove an edited squash, local retention plus an explicit disposition is safer than
inventing an optimistic heuristic.

### 11.3 Detached and adopted work

Inspect detached HEAD independently from the metadata branch. If removing the worktree/deleting a branch would
leave an original commit without a surviving local ref, create/verify an exact CAS-protected retention ref
first, even when patch equivalence proves integration. Equivalence does not retain original commit identity. A
reflog alone is not the contract; a branch scheduled for deletion cannot count as surviving. Retention ref
creation is preservation, not permission to relax a remote-required delivery contract.

- **Resource:** Fleet-owned worktree
  - **Removal predicate:** Runtime/launch barrier stopped; deliverable verified at current revision; delivery
    contract satisfied; no tracked/untracked/ignored data at risk; every detached/original tip retained;
    native Git agrees.

- **Resource:** Adopted worktree
  - **Removal predicate:** Never remove; dirty/ignored content may remain under an explicit recorded close
    disposition since no files are deleted.

- **Resource:** Fleet-owned remote-review branch
  - **Removal predicate:** Its own tip preserved/retained; task delivery verified; no local-ready policy;
    native `git branch -d` agrees.

- **Resource:** Local-ready or adopted branch
  - **Removal predicate:** Always retain; do not attempt `-d`.

Retention refs and their exact OIDs are reported in cleanup output and kept until a separate explicit human
retention-cleanup action. Do not quietly accumulate unreachable history behind an optimistic equivalence
verdict.

Adopted worktree: never remove directory or branch. Completion still needs deliverable verification;
unsaved/dirty changes must be reported as left in place, not silently forgotten. Adopted branch in a
Fleet-created worktree: remove only the owned clean worktree; never delete that branch.

Worktree ownership is recorded at creation/adoption and revalidated against native Git identity, not inferred
from a pathname containing `.worktrees`. Do not operate on the primary clone even if an incorrect path happens
to pass a prefix test.

Branch cleanup is hygiene, not a reason to lie about the task result. Exclude local-ready and adopted branches
entirely. For an eligible Fleet-owned branch only, use `git branch -d` after proving its own tip safe and
after worktree removal. On native refusal, keep it and display the reason. Do not reimplement Git's
checked-out-branch rules or escalate to force deletion.

### 11.4 Discard policy

There is no autonomous `--force --discard` tool. Normal teardown never destroys dirty or unpreserved work. A
human may deliberately handle a named exceptional discard through a separate explicit recovery procedure,
inspect the exact path/OIDs/diff, and then rerun teardown. Building a general discard UI is not a v1
requirement.

Refusal output must include actual HEAD/branch, ownership, dirtiness, remote/target OIDs and freshness,
preservation/integration result, detached reachability, proposed removals, retained refs/branches, and errors
from the single evidence pass. Do not recompute a second contradictory explanation after the decision.

## 12. Dashboard specification

### 12.1 Buffer and rendering

Buffer name `fleet:*`; `fleet-dashboard-mode` derives from `special-mode`; read-only, `truncate-lines=t`,
`hl-line-mode` enabled. No dependency on Magit; use propertized hierarchical lines, not a browser UI. Preserve
theme compatibility using standard inherited faces.

Intended appearance (illustrative data, not a literal width prescription):

```text
Fleet compiler - commander live/idle · supervision on · wakes 1 · 2 working, 1 decision
  ● parser-errors        working·eca        change compiler     4m  validating malformed input + tool test
  ◐ ast-layout           decision·status    study compiler      2m  retain source offsets? [02]
  ● benchmark            working·eca        ops .               36s measuring cold start · tool shell 28s

Fleet website - commander live/idle · parked · wakes 0 · 1 suspended, 1 done
  ◌ mobile-navigation    suspended          change website      1h  paused by you; workspace retained
  ✓ accessibility        done·status        study website       18m report verified; ready for cleanup

p/P entry · N/P fleet · a attention · j jump · RET open · v view · s send · i interrupt ·
t teardown · b brief · r report · w worktree · X park fleet · g refresh · q quit
```

Show commander connection/activity and actual fleet supervision/lifecycle.

Header contains fleet name, commander live/activity, supervision state, pending actionable event count,
fixed-order task tally. The tally is based on the shared snapshot, never an independent parser. Distinguish a
busy commander from a dead one; header severity includes commander/runtime/protocol failures.

Task columns:

- **Column:** Icon
  - **Contract:** Themed single state glyph; ASCII fallback when display width is unsuitable.

- **Column:** Task
  - **Contract:** Data-sized over all visible fleets, min 12, max 28 display columns.

- **Column:** State/source
  - **Contract:** Data-sized, min 12, max 20; `eca`, `status`, `runtime`, or a compact source-free lifecycle
    label.

- **Column:** Kind
  - **Contract:** Six display columns: change/study/ops.

- **Column:** Repo
  - **Contract:** Data-sized, min 4, max 20; `.` if not applicable.

- **Column:** Age
  - **Contract:** Right-aligned width 5 for status age; `<90s` seconds, `<90m` minutes, otherwise hours.

- **Column:** Detail
  - **Contract:** Remaining line; not field-truncated, horizontally clipped by `truncate-lines`.

Use `string-width` and `truncate-string-to-width`, not character length. Strip embedded newlines/control
characters from row detail. Long names, Unicode, and differing window sizes must not shift adjacent columns
unpredictably. Keep the layout compact with no column-heading row; describe columns in help/quickstart.

Use stable alphabetical fleet/task ordering, not urgency reordering that moves targets under the user's hands.
Attention navigation supplies urgency. An empty dashboard still displays a brief `no active fleets — M-x
fleet-new` hint and footer.

### 12.2 Primary state projection and faces

Compute from orthogonal task/runtime/message/decision facts:

1. Corrupt/incompatible/unknown execution evidence → `unknown` with attention detail; never guessed dead.
2. Fleet parking/stopping operation or suspended task → explicit lifecycle row, while preserving terminal
   result in detail where applicable.
3. Unexpected confirmed runtime loss on unfinished work → `dead`.
4. Unresolved permission/user question/needs-decision → `decision` (permission detail distinguishes tool
   policy from scope).
5. Explicit blocked/failed/done semantic phase → corresponding state; done still shows active tool/turn
   warning when applicable.
6. Declared wait → `paused`.
7. Verified turn/tool activity → `working·eca`.
8. Last working status with observed idle → `working·status`, detail says idle/awaiting next step rather than
   implying current model execution.
9. Otherwise `unknown`.

Operation failure/delivery-unknown contributes an attention badge even if the task's primary result remains
done. Multiple facts must not be hidden solely because one won the primary-state precedence.

| State | Face | Glyph |
| --- | --- | --- |
| unknown | warning | ? |
| working | success | ● |
| decision | warning | ◐ |
| paused / suspended / stopping | warning or shadow for deliberately inactive fleet | ◌ |
| blocked | error | × |
| failed | error | ! |
| dead | error | ! |
| done | shadow | ✓ |

Apply row faces consistently. Header uses bold+error for unresolved blocked/failed/dead/stop failure,
bold+warning for decisions/protocol unknowns, otherwise bold. Intentional park is not an error. Display
severity and `a` attention come from the same attention predicate so an important warning is not impossible to
navigate to.

### 12.3 Exact key contract

- **Key:** `n` / `p`
  - **Command:** `fleet-dash-next` / `fleet-dash-prev`
  - **Meaning:** Next/previous entry, including fleet headers; no wrap.

- **Key:** `N` / `P`
  - **Command:** `fleet-dash-next-fleet` / `fleet-dash-prev-fleet`
  - **Meaning:** Next/previous fleet header; from a task `P` may select its own header.

- **Key:** `j`
  - **Command:** `fleet-dash-jump`
  - **Meaning:** Required-match fleet completion; jump/recenter.

- **Key:** `a`
  - **Command:** `fleet-dash-attention`
  - **Meaning:** Next operator requiring action; wraps. Includes decision/blocked/failed/dead/unknown delivery
    or stop issues; not deliberately suspended rows. If only the commander has a problem, select its fleet
    header.

- **Key:** `RET`
  - **Command:** `fleet-dash-visit`
  - **Meaning:** Header → actual commander ECA chat; task → actual operator ECA chat.

- **Key:** `v`
  - **Command:** `fleet-dash-peek`
  - **Meaning:** Read-only snapshot of last 40 logical transcript lines, header or operator, in reusable
    `fleet-peek*`; no stealing the main chat.

- **Key:** `s`
  - **Command:** `fleet-dash-send`
  - **Meaning:** One minibuffer message to commander on header or operator on task. Use targeted structured
    send; show queued/accepted/unknown truthfully.

- **Key:** `i`
  - **Command:** `fleet-dash-interrupt`
  - **Meaning:** Operator-only guarded cancellation request; active/unknown turn requires confirmation. Show
    pending result; never synthesize idle.

- **Key:** `t`
  - **Command:** `fleet-dash-teardown`
  - **Meaning:** Operator-only normal teardown with confirmation and full evidence gate.

- **Key:** `b`
  - **Command:** `fleet-dash-brief`
  - **Meaning:** View current brief read-only. Header explains that it has no operator brief.

- **Key:** `r`
  - **Command:** `fleet-dash-report`
  - **Meaning:** View report read-only; missing report gives a concise message.

- **Key:** `w`
  - **Command:** `fleet-dash-worktree`
  - **Meaning:** Dired into the verified existing task worktree; non-change/no-worktree is an explicit
    message.

- **Key:** `X`
  - **Command:** `fleet-dash-park`
  - **Meaning:** Park the fleet at point, with exactly the M-x confirmation semantics.

- **Key:** `g`
  - **Command:** `fleet-dash-refresh`
  - **Meaning:** Refresh snapshot and render; no lifecycle mutation.

- **Key:** `q`
  - **Command:** inherited quit-window
  - **Meaning:** Leave/bury dashboard; do not stop supervision or workers.

No `d` drain, `k` blind kill, dashboard destroy key, new mark/bulk-delete grammar, or rebinding `p` to peek.
Keep `C-c h f` as the documented optional global binding installed by the user's Emacs configuration; the
package must not steal it automatically.

`b`/`r` use `view-mode`, with `q` leaving and `e` explicitly entering editable mode. Editing a brief file
directly does not mutate an active brief revision; import it through the revision operation before it can be
sent as new tasking. Explain this when editing an active brief.

For pending ECA permissions/questions, visiting the real ECA chat presents the exact native approval/question
UI without automatic approval. `s` may answer a specific free-form pending Fleet decision only when its
correlation is explicit; it must not treat arbitrary text as a permission grant. A stopped/dead target is not
silently restarted by `RET` or `s`; show retained transcript and recovery choices/messages instead.

### 12.4 Refresh, selection, and responsiveness

Rows carry `(fleet-uuid, task-uuid-or-commander)` identity properties. Before render preserve selected
identity, within-row display column, and window start identity. After render restore them. If the row
vanished, select the next sibling, then prior sibling, then fleet header; never dispatch an action using a
cached character position.

Each action captures identity and expected revision at invocation and revalidates before mutation. If the row
changes while a confirmation is open, refuse/reconfirm rather than targeting its replacement.

Refresh on committed snapshot changes with a short coalescing timer (initial 100–300 ms is sufficient); update
age display on a modest UI timer only while visible. No Git, process-manager query, or network work in
rendering. Database events and runtime callbacks drive correctness; the age timer does not wake models. `g`
remains useful for explicit reconciliation visibility.

Reinitializing/loading the package must update the keymap in existing buffers. Do not hide key definitions
solely inside a `defvar` initializer that will not run again. ERT and an actual test buffer must verify
key-binding after reload.

## 13. Commander and operator doctrine

### 13.1 Commander boot and supervision

Canonical `prompts/commander.md` must instruct:

1. Read pending events non-destructively and the current snapshot.
2. Reconcile tasks, operations, artifacts, and preserved scope; a Fleet runtime result is stronger evidence
   than transcript speculation.
3. Give the user a two-to-four-sentence picture: running, finished, needs a decision. Do not narrate scheduler
   mechanics.
4. Classify intake as change/study/ops, prepare a complete brief, then dispatch independent work immediately.
5. Do not project implementation yourself. Operators own workspaces; you own delegation, verification, scope,
   and communication.
6. On events, handle within existing authority, record outcomes, acknowledge exact event IDs, then end your
   turn. No polling/sleep loops.
7. Verify actual artifacts before claiming success or requesting cleanup.
8. Answer operator questions from the brief/context where authorized. Escalate scope changes, spending,
   irreversible actions, merges/discards, and unresolved decisions with a recommendation.
9. Never reinterpret a study report as permission to implement it.
10. Respect parking and runtime safety refusals. Do not repeatedly retry a refusal or manufacture done/idle
    state.
11. Suggest an explicit context handoff at a natural milestone, recording decisions, next steps, and artifact
    pointers in `commander/context.md`.

User-facing noise policy: outcomes, findings, decisions, real blockers. No routine retries, no "still working"
messages, no periodic whole-fleet summaries absent a user request.

### 13.2 Operator boot and status

Common operator instructions:

- Read the exact brief revision and prior progress before acting. Existing workspace changes are evidence to
  preserve, not a reason to restart from scratch.
- Work only in assigned scope/workspace. Do not create a replacement task branch because it has a nicer name.
- Use structured Fleet status/artifact/wait tools; never edit metadata/DB or send messages to siblings.
- Publish sparse semantic phase transitions. A tool running is not itself a new status phase.
- Keep `progress.md` current at meaningful milestones, before bounded long waits, and before ending with
  incomplete work. Include concrete artifacts/commands/remaining work rather than a stream of thoughts.
- Encountering the same obstacle twice means stop and ask for help with evidence; do not perform endless
  retries.
- `paused` is a named self-clearing external wait with deadline; `blocked` requires intervention;
  `needs-decision` includes a precise question/options/recommendation.
- Declare any operation that may outlive the local runtime, with its external identity and stop/continuation
  semantics.
- Report done only when the brief's criteria are met and artifacts are registered. Do not invoke teardown on
  yourself.
- No merge, discard, permission weakening, or scope expansion by implication.

### 13.3 Brief contents

Every brief has: task identity and revision; goal/non-goals; relevant context and source paths; acceptance
criteria; allowed changes/actions; workspace/ownership; dependencies/shared resources; deliverable and
verification method; known risks; stop/escalation rules; progress/report paths.

Change adds repo/base/branch/worktree, tests, delivery mode (`remote-review`, `local-ready`, or explicitly
integrated delivery), and hosting instructions from the actual repo. Study adds question, evidence standard,
self-contained report outline, no-code-change boundary, uncertainty/limitations. Ops adds exact
artifact/action, external system authority, rollback/stop semantics, deadlines, and external-job registration.

The repository's own `AGENTS.md` and the user's request govern branch and delivery policy. Use GitHub for
normal pull-request workflows through the user's authenticated tooling, following the actual repository's
hosting instructions.

## 14. quickstart.md — required shipped content

The repository must ship **root `quickstart.md`** (that exact spelling and lowercase path). `README.md` links
to it. Provide a practical native ECA/Emacs guide alongside the design document.

It should contain the following usable content, with commands verified against the actual implementation:

### Prerequisites and install

1. Verify ordinary native ECA works manually, user systemd is available, and Emacs SQLite support exists.
2. Place Fleet at `~/development/fleet`; add its `lisp/` to Emacs `load-path`; require `fleet`.
3. Set `fleet-development-root` to `~/development` if different; worktree root derives as `worktrees`. Set
   native ECA command/model preferences only if discovery cannot use the already configured native
   executable/defaults.
4. Optionally bind `C-c h f` to `fleet-dashboard`.
5. Install the one ECA MCP bridge configuration entry with backup, keeping all existing tools/providers/rules.
   Do not enable blanket trust.
6. Run `M-x fleet-doctor`; resolve unsupported adapter, ownership, path, permissions, SQLite, or systemd
   failures before unattended work.

Show a minimal real Emacs configuration snippet in the shipped file, using public configuration names. Avoid
an installer that edits `.emacs` wholesale or mutates user fleets during setup.

### M-x reference

- **Command:** `fleet-new`
  - **When:** Create or resume a named fleet; an existing live commander is visited, not duplicated.

- **Command:** `fleet-dashboard`
  - **When:** Live grouped view, also `C-c h f` if configured.

- **Command:** `fleet-park`
  - **When:** Stop operators with confirmation; retain commander and durable work.

- **Command:** `fleet-destroy`
  - **When:** Archive an empty fleet; no cascade deletion; no dashboard key.

- **Command:** `fleet-watch-start` / `fleet-watch-stop`
  - **When:** Enable/pause automatic dispatch without lying about stopped processes.

- **Command:** `fleet-doctor`
  - **When:** Compatibility and recovery evidence; no automatic destructive repair.

- **Command:** `fleet-commander-stop` / `fleet-commander-replace`
  - **When:** Explicit verified commander shutdown or fresh-context replacement; no operator teardown.

### Dashboard key reference

Include the complete table from section 12.3, condensed for daily use. State explicitly: `p` is previous row,
`v` is peek, `a` wraps, `RET` depends on row, `X` is park, and `q` does not stop anything.

### First project

`M-x fleet-new` → choose `myproj` → tell the commander what to achieve and which repo/delivery mode applies.
Fleet supplies the commander boot context automatically. Watch silent background operators in the dashboard.

### During the day

Use `a` for decisions/failures, `v` for a quick look, `RET` for the actual ECA conversation, `b/r` for
artifacts, `w` for files. Send scope changes to the commander. Use `s` for a short answer and `i` only after
understanding what will be interrupted. Pending permission approval is not an ordinary message.

### When a task finishes

Commander verifies and requests normal teardown. Manually use `t`. A refusal shows
preservation/ownership/process evidence; read it. Pushed means preserved, not merged. A retained branch
warning is not task failure. Fleet never force-deletes a dirty worktree for convenience.

### End of day/week

On the fleet press `X`, confirm, and wait for **parked**, not merely parking. Review any external jobs left
running. Use the still-live commander to write an explicit handoff in `commander/context.md`. Then `M-x
fleet-commander-stop` and wait for verified stop; hiding/killing a buffer is not the shutdown operation.
Worktrees/briefs/reports/events remain.

### Resume / Emacs restart

`M-x fleet-new` → existing name → review/resume confirmation. Fleet reconciles old services, starts a fresh
commander if needed, and resumes unfinished scope from durable records. Completed scope is not rerun. ECA
conversation history is a convenience, not the recovery contract.

### Commander context exhausted

Write/verify a short `commander/context.md` handoff with decisions, next steps, and artifact pointers. Run
`M-x fleet-commander-replace` (also offered as a doctor recovery action); do not create a second live
commander by renaming a buffer. No invisible automatic compaction protocol is required.

### Mistyped name / finished fleet

Teardown or explicitly preserve/close all tasks; `M-x fleet-destroy` archives the now-empty fleet. The name
becomes reusable after successful archive commit. Destroy never bypasses task closure or preservation
requirements.

### Troubleshooting

Explain queued versus accepted versus delivery-unknown, cancellation requested versus service stopped, parking
failure, adopted workspace retention, incompatible ECA version, outstanding permission/question, stale owner,
and external jobs. Give paths to operation evidence, transcripts, and doctor. Never advise blind resend or
deleting lock/worktree directories by guesswork.

## 15. Testing and acceptance

### 15.1 Test isolation

All automated tests use temporary data/cache/runtime/development roots and fake credentials. Never load a real
Fleet state root, real provider configuration, or real MCP server during unit tests. Fakes must prevent
accidental native launches even if a test assertion fails.

Run ERT through `emacsclient` connected to a **dedicated disposable test server**, not the user's editing
server. The implementation agent must arrange that test server explicitly with the user/environment; do not
call an exit-bearing test helper in the main Emacs. Pure ERT execution should return results without killing
the server. Python tests use the configured interpreter explicitly; a verified absolute path such as
`/usr/bin/python` is suitable.

Test async code with controllable fake clock/process callbacks, not real multi-second sleeps. Real systemd
integration and opt-in model smoke tests are separate from deterministic unit tests.

### 15.2 Required test matrix

**Store/protocol**

- Atomic status+event+receipt update, failed write rolls back all three.
- Same idempotency key/same payload returns prior result; changed payload refuses.
- Stale runtime on wrong actor/fleet/task cannot publish status or mutate siblings.
- Schema migration backup, downgrade refusal, corrupted/locked DB evidence.
- Brief file/DB publication crash boundaries; no runnable missing/mismatched revision.
- MCP framing, Unicode/multiline/dash-leading text, split frames, oversize/malformed JSON, protocol
  negotiation, disconnected caller, and role-specific tool lists.

**Supervisor/delivery**

- Enqueue while commander busy/drafted/absent/parked retains events.
- Human reading/peeking never consumes an event.
- Crash before write, after write before acceptance, after acceptance, and before/after ack.
- Unknown delivery never auto-resends; claims survive/release correctly on replacement.
- Two distinct questions for one task both survive coalescing.
- End-of-turn without ack does not create an unbounded model loop.
- Human send and automatic wake cannot race into two prompt lanes.
- Expired wait emits once; healthy long tool never becomes dead solely by age.
- Replayed/duplicate ECA terminal events cannot finish a new turn.

**ECA adapter**

- Two sessions with overlapping roots route to explicit handles.
- Programmatic send preserves existing human draft; normal human send is recorded/admitted.
- Config/model updates do not leak across runtimes or ordinary ECA sessions.
- Tool approval/question captured without stealing focus; exact response correlation.
- Child/subagent finish does not complete the parent; tool error is not automatically task failure.
- Cancellation's synthetic UI idle cannot satisfy runtime-stop admission.
- Protocol errors/disconnect preserve pending request evidence.
- Hot reload installs advice/keymaps once and can uninstall cleanly.

**Runtime/Lifecycle**

- Stop kills ordinary and detached local child processes in the exact unit; other units survive.
- Missing buffer/closed wrapper while service lives refuses respawn.
- Service query failure is unknown, not gone.
- Park first blocks commander respawn/new starts; failure stays parking; success retains all artifacts.
- Late callback from old commander/operator cannot mutate replacement or reused fleet name.
- Second Emacs/daemon can observe but not take ownership; genuine daemon owner works.
- Restart inventories surviving exact units before launching any replacements.
- Destroy refuses nonempty/active operations, and file-rename/DB failures recover without hiding the fleet.

**Git**

- Fresh branch, adopted branch, adopted worktree, same worktree claimed twice, dirty primary clone untouched.
- Spaces/Unicode paths, symlink aliases, same repo basename in different roots, worktree path swapped during an
  await.
- Remote head under arbitrary name; advanced head ancestry; missing/offline remote; explicit remote not named
  origin.
- Main/master/other default branch; remoteless repo; local-ready retention ref preserved.
- Multi-commit squash, rebased squash, merge/empty commits, unsupported patch cases, edited squash refusal.
- Dirty/untracked/submodule/broken/locked worktree refusal without deletion.
- Detached commit with/without surviving ref; branch slated for deletion cannot be its only preservation proof.
- Branch cleanup `-d` refusal is visible but does not erase artifacts; never `-D` or `rm -rf` fallback.
- Failure after runtime stop, after worktree removal, and before archive commit can be retried safely.

**Dashboard**

- Exact key bindings, including after reload in a live buffer.
- Header/operator contextual RET/s/v; missing session never creates empty fake buffer.
- Attention wrap, fleet navigation, sorted order, no mutation from refresh/peek.
- Point/window preservation by identity while rows/details are inserted/removed.
- Confirmations revalidate row-identity/revision.
- Unicode/display width, narrow windows, long names, no fleets, permission/error/parked rows.
- Background spawn and permission events do not alter selected window/buffer.
- Brief/report read-only view; q/e behavior; active brief edit does not silently alter dispatched scope.

### 15.3 End-to-end acceptance scenarios

1. Two fleets, several independent change/study/ops tasks, silent spawns and correct contextual dashboard
   navigation.
2. Operator asks a scoped question; one durable event wakes an idle commander; answer reaches only the right
   runtime; event acknowledged after disposition.
3. Operator reports done before its response/tool finishes; task shows result without prematurely permitting
   workspace removal.
4. Park during active work; all owned local execution stops; commander cannot respawn; artifacts and held
   events remain; resume continues existing work.
5. Kill/restart Emacs while a native worker has a detached child; replacement never overlaps predecessor.
6. Complete remote-review task: remote preservation permits cleanup, but UI never calls it merged. Complete
   local-ready task: durable ref/branch retained and named.
7. Kill commander between reading and acknowledging an event; replacement sees the unhandled work and does not
   duplicate idempotent task operations.
8. Upgrade ECA to an unsupported pair: doctor names the contract mismatch, safe read-only inspection works, no
   blind compatibility fallback.

Passing tests with a fake ECA server is necessary but not sufficient. A release needs the native two-runtime
smoke test on the installed home pair and the actual systemd child-lifetime test. Report exactly which tests
used real native ECA and which were simulations.

## 16. Implementation sequence

Each milestone leaves a coherent, testable result. Do not build the entire UI before verifying the native
process boundary.

1. **Compatibility spike and launch ownership.** Native two-runtime routing, event ordering, human-send
   interception, MCP identity, instructions/config, service child stop; publish evidence and supported pair.
   No scheduler yet.
2. **Store and deterministic core.** Schema/transactions, identities, paths, task/brief revisions, owner lock,
   operation recovery; fake runtime tests.
3. **Workspaces and safety.** New/adopted worktrees, resource claims, preservation/equivalence/local-retention
   proofs, teardown crash/refusal tests. No model needed.
4. **Agent bridge and one operator.** Scoped MCP, status/artifact/wait APIs, one real native operator from a
   complete brief, honest send/stop results.
5. **Commander and durable supervision.** Events/receipts, message lane/outbox, busy/draft/park admission,
   recovery and noise policy. Prove at-least-once handling without duplicate operations.
6. **Dashboard and M-x lifecycle.** Exact key/visual contract, new/resume/park/destroy, live keymap reload and
   focus tests.
7. **Hardening and install.** Crash matrix, two-fleet real smoke, native upgrade check, backup/restore,
   complete quickstart, verified home paths and credential hygiene, clean installation/uninstallation.

Do not claim Fleet is ready for unattended daily work until park/restart orphan tests, unknown-delivery
handling, and Git refusal tests pass. Do not hide an unproven native contract behind a TODO in a production
path.

## 17. Operational maintenance

### Configuration surface

Keep only settings with a genuine independent purpose: development/data/cache/runtime roots; native
executable; commander/operator model/agent/variant defaults; explicitly supported compatibility profile.
Derive worktree root from development root unless the user overrides it for an actual layout need. UI key
binding is ordinary Emacs configuration.

Keep retry policy, state precedence, and safety invariants in their owning modules rather than exposing
configuration overrides. Protocol/shutdown deadlines have documented implementation defaults and tests; add
user knobs only when an actual supported environment requires them.

### Backup and retention

Use a consistent SQLite backup (SQLite online backup where supported, otherwise pause writes and use a
verified consistent method); do not copy a live DB without accounting for WAL. Back up DB and referenced
artifacts together at a recorded snapshot revision. Git repos/worktrees need their own backup; local retention
refs are not an off-machine backup.

Never automatically prune reports, briefs, progress, or archived task/fleet history. Disposable ECA caches and
bounded diagnostic transcripts may have an explicit separate retention command/policy after all related
runtime operations terminate. Credential files are ephemeral and removed/revoked at runtime end.

### Upgrade/uninstall

On frontend/server version change, doctor invalidates the prior compatibility result and reruns non-model
checks; real acceptance is an explicit action. No auto-updating the native executable during worker startup. A
known absolute custom native command avoids asynchronous package-download behavior during launch.

Uninstall first parks all fleets and settles their launch barriers, then explicitly stops every retained
commander with `fleet-commander-stop`. Prove all owned runtimes stopped before closing the owner RPC/releasing
the lease and removing the Emacs load-path entry and single Fleet MCP config entry. Unsupported ECA still
permits independent systemd stopping. Uninstall does not delete data, worktrees, or reports. Reload/unload
tests must leave ordinary ECA untouched.

### Diagnostics

Errors carry stable codes, concise message, exact affected identities, and evidence pointers. Examples:
`unsupported-eca-contract`, `owner-unproven`, `delivery-unknown`, `runtime-stop-unknown`, `workspace-changed`,
`work-unpreserved`, `adopted-resource`, `brief-revision-mismatch`.

Telemetry records operation IDs and state transitions, not raw secrets or full prompts by default. Telemetry
failure must not swallow a required durable event or change a safety verdict. Database failure *does* block
mutation because durable state is load-bearing; cosmetic logging failure is reported separately.

## 18. Deliberately deferred improvements

These are extension seams, not requirements hidden inside v1:

- Stable native ECA chat-history reopen, only through a verified public API; task recovery does not depend on
  it.
- Public upstream ECA lifecycle/cancellation/turn-ID contracts to reduce any verified need for private adapter
  access.
- External notification integrations.
- Hosting-specific PR status/merge integrations, only when authorized and worth maintaining.
- A commander-nudge command that requests handling without consuming events.
- Hierarchy/sub-commanders only if actual work justifies it; do not complicate the worker protocol now.
- More elaborate report publication or personal knowledgebase integration through the user's existing tools.

## 19. Review decisions and implementation questions

The architecture rests on persistent parked/suspended state, explicit native service ownership, and structured
transactional tools/events. These are required foundations for durable, accountable execution.

The implementation agent must resolve concrete home-version questions during milestone 0, without asking the
user to research them:

- Which installed public ECA APIs provide initialization/send/notification access, and where, if anywhere, is
  verified private adapter access necessary?
- What exact acceptance and turn-order guarantees does that native server provide?
- How do instructions, native-tool permissions, MCP processes, and configuration discovery interact for a
  task-root workspace?
- Which environment variables are required for the user's native providers without logging credentials?
- Does the Arch user service launch preserve ECA protocol stdout and terminate all tested ordinary local
  descendants?

If a required contract cannot be proven, report the exact source/trace and the smallest necessary adapter or
upstream change. Do not redesign Fleet around undocumented cache files or terminal emulation to avoid
answering it.

## 20. Implementation handoff and evidence record

Start with milestone 0, then follow section 16. Use this document as the repository's initial `docs/design.md`
and implement the specified behavior in the new repository.

Resolve installed ECA source with `locate-library` through `emacsclient`. Useful API-discovery anchors
include:

- `eca-util.el`: session structure, `eca-create-session`, workspace routing.
- `eca-process.el`: `eca-process-wrapper-function`, `eca-process-start`, parsed-message callbacks and process
  lifetime.
- `eca.el`: initialization, notification/request dispatch, shutdown/restart.
- `eca-api.el`: explicit-session asynchronous request/notification transport and error handling.
- `eca-chat.el`: prompt/steering/queue admission, chat registration, tool approval, question handling,
  progress/status, and cancellation UI.
- `eca-jobs.el`: job identity, status, and kill/list support if present.

Names may change between ECA versions; the required behavior is specified in section 5. Record the installed
native executable's version/help, frontend revision, immutable source anchors, and redacted protocol traces in
`docs/eca-compatibility.md`. Source examples and UI events are not substitutes for verified native-server
guarantees.

The finished repository must include:

1. Working public M-x commands and the exact dashboard key/visual contract.
2. A verified native adapter and accountable local runtime lifetime.
3. Transactional task/action/event/message state with tested crash recovery.
4. Worktree/adoption/preservation checks that refuse unsafe removal.
5. Scoped commander/operator tools, canonical doctrine, and brief templates.
6. Root `AGENTS.md`, `README.md`, and complete `quickstart.md`.
7. Deterministic tests plus clearly identified native/systemd acceptance results.
8. Minimal installation, explicit compatibility diagnostics, and artifact-preserving uninstall.

Record any unresolved compatibility contract as a specific blocker with evidence and the smallest remedy. Do
not report readiness for unattended use until the native acceptance criteria pass.

---

## Implementation notes (deviations and clarifications recorded during the build)

These are the points where the shipped implementation deliberately differs from, or pins down, the text above.
Each was driven by evidence from the installed pair (see `docs/eca-compatibility.md`).

1. **MCP entry delivery.** Fleet runtimes receive the `mcpServers.fleet` entry through the per-runtime
   `ECA_CONFIG` overlay (deep-merged by the server), so ordinary ECA sessions never see the bridge at all.
   `M-x fleet-install-mcp` still exists and merges the same single entry into the user's global config with a
   backup and a diff, but it is optional rather than an installation step.
2. **Readiness waits for models.** The native server answers a prompt sent before its first `config/updated`
   with models by an error turn (recorded). `fleet-eca-start` therefore reports `connection-ready` only after
   models are announced (bounded by `fleet-eca-models-timeout-sec`).
3. **Agent default.** This pair's agents are `code`/`plan`; `fleet-agent` defaults to nil (server default).
4. **Prompts.** `prompts/ops.md` exists alongside `change.md`/`study.md` so every task kind has a doctrine file.
5. **Environment propagation.** `ECA_*` variables of the spawning environment are excluded from propagation
   (Fleet sets `ECA_CONFIG` itself); provider credentials are selected by name pattern, values never logged.
6. **`fleet-watch-start/stop`** take a fleet name and toggle that fleet's persisted supervision flag.
7. **Subagent tools.** The overlay sets `disabledTools: ["eca__spawn_agent"]`; whether this pair honors it is
   not yet verified by a trace and is listed as an open item in the compatibility profile.
