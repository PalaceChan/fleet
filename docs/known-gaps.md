# Known gaps — source evidence

[TODO backlog](../TODO.md) · [Contributor rules](../AGENTS.md) · [Development](development.md) ·
[Testing](testing.md) · [Recovery](recovery.md)

This is supporting source evidence and technical closure detail, not a second task queue, session log or
claim about live fleets. [TODO.md](../TODO.md) owns priorities, difficulty, task status, dependencies and
acceptance; its items link to the findings below. Initial source review: `7ad225b` (September 13, 2026).
**Source-review findings below were not reproduced in a runtime during the documentation audit.** Earlier
native observations are separately labeled. No implementation fixes are implied by documenting them.
Recheck the named functions/tests before acting; after verified completion, update the corresponding TODO
item and qualify/remove obsolete findings here in the same change. Keep history in Git.

Safety-sensitive work comes first, but this list is not authorization to change scope, run paid probes,
operate owner fleets, or alter credentials. Preserve design invariants when fixing gaps; do not weaken the
invariants to match an accidental implementation path. Private incident follow-ups stay outside this repo.

## Fail-closed evidence

Source: [`fleet-runtime.el`](../lisp/fleet-runtime.el), [`fleet-supervisor.el`](../lisp/fleet-supervisor.el).

- **Unreadable cgroup evidence:** `fleet-runtime-cgroup-populated` reports `absent` when `cgroup.events`
  is unreadable; `fleet-runtime-verdict` can accept `absent` as stopped evidence. Design requires unknown
  evidence to refuse replacement/removal. **Close with:** distinct missing/unreadable/malformed cases and
  verdict tests proving permission/read errors remain unknown; integration refusal coverage.
- **Malformed owner descriptor:** `fleet-supervisor-acquire` suppresses descriptor read/parse errors and
  can treat them as no descriptor. The design requires explicit recovery for corrupt/unknown identity.
  **Close with:** malformed/partial descriptor tests demonstrating fail-closed acquisition and a documented
  owner-authorized recovery path. Never remove locks or edit owner identity by inference.

## Recovery and delivery

Source: [`fleet-core.el`](../lisp/fleet-core.el), [`fleet-supervisor.el`](../lisp/fleet-supervisor.el).

- **No-runtime journal recovery:** `fleet-core-reconcile-runtimes` returns immediately when there are no
  nonterminal runtimes, bypassing `fleet-core-resume-operations`. Interrupted operations can therefore be
  left running even with everything stopped. Existing rename-recovery coverage in `fleet-core-tests.el`
  calls the resume helper directly. **Close with:** startup-path crash tests with zero runtime rows for
  interrupted brief publication/retirement, plus recovery independent of runtime count.
- **Interrupted retask:** `fleet-core-retask` persists a stopping operation with text length rather than
  the replacement brief; `fleet-core-resume-operations` has no `task-retask` case. **Close with:** durable
  replacement intent and explicit resume/refusal semantics tested across stop/brief-publication crashes.
- **Held operator messages:** `fleet-core-resume-fleet` makes held messages queued but retains their
  `target_runtime_id`; replacement operators get new IDs and `fleet-supervisor--dispatch-lane`
  dispatches to the recorded target. Retained text is not proof of delivery to the replacement.
  **Close with:** replacement tests for never-attempted, attempted, unknown, and changed-brief messages;
  identity/revision-aware reconciliation without blind resend. See [recovery](recovery.md).
- **Persisted busy lane with no adapter turn:** a message in `dispatching`/`accepted`/other in-flight state
  can hold the lane while the adapter has no turn. Earlier terminal-pair fixes have regressions, but general
  mismatch detection/self-healing and a doctor diagnostic remain open. **Close with:** deterministic
  mismatch/crash tests and reconciliation that preserves unknown delivery. Do not copy historical manual
  SQL repair into a runbook.
- **Backup/shutdown lifecycle:** `fleet-supervisor-release`, `fleet-supervisor-stop`, and `fleet-rpc-stop`
  do different parts of shutdown; no single verified maintenance command establishes quiescence. DB backup
  and separately copied artifacts are not automatically one snapshot. **Close with:** an explicit tested
  maintenance path covering pending operations, all runtimes, artifact writers, RPC, lease and DB handles;
  restore rehearsal in isolated roots, never in-place on owner state.

## Authority and interface

Source: [`fleet-core.el`](../lisp/fleet-core.el), [`fleet-rpc.el`](../lisp/fleet-rpc.el),
[`tools-v1.json`](../schema/tools-v1.json), [`rpc-v1.json`](../schema/rpc-v1.json),
[`fleet_bridge.py`](../bridge/fleet_bridge.py).

- **Operation reads across tasks:** `fleet_operation` permits operator reads of operations across the
  same fleet; decide and test whether that visibility is intentional or must be task-scoped (F15).
  Unsandboxed execution does not excuse a tool-level scope violation. (External-job updates are now
  task/fleet-owned at the core mutation boundary; see F04.)
- **Human-authority decisions:** core requires human authority, but RPC supplies commander authority and
  there is no public human decision-resolution command. Native question answers and chat messages do not
  resolve the durable `decisions` row. **Close with:** an explicit human-authorized UI/API and end-to-end
  resolution/delivery tests. Do not impersonate human authority or bypass the refusal.
- **Status/wait idempotency:** `fleet_status` and `fleet_wait` bypass the keyed mutation wrapper and their
  schemas do not accept `idempotency_key`. Repeated status can create repeated events/decisions. The schema
  overview's blanket statement that every mutation is keyed is too broad. **Close with:** an aligned
  schema/handler/doctrine contract and retry tests. Until then inspect after an uncertain result, don't
  blindly repeat these calls or invent an unsupported key. Consequence for the wait watchdog
  (`fleet-core-watch-waits`, design note 20): it anchors a wait on the task's latest `task-paused` event, so
  a repeated identical `fleet_wait` restarts the watchdog clock (when the watchdog is enabled; it is off by
  default); the deadline is unaffected.
- **Waits on unregistered job ids:** `fleet_wait`/`fleet_status paused` judge `job_id` only when it names a
  row in `external_jobs` (own task: terminal state returns instead of pausing; another task's: `forbidden`).
  An id nothing was registered under pauses as declared, since Fleet has no record to compare it with, and
  the row's `state` is the operator's own claim: the 2026-09-19 incident's job still read `running` when
  the wait was declared, so the terminal-job return would not have caught it; the watchdog would have.
  **Close with (if wanted):** require registration before a wait names a job, as doctrine already says.
- **Task scope and delivery parameters:** `context_paths` is recorded at creation but is not wired into
  operator roots/boot context. Brief completeness is a length check, not semantic validation. When task
  start creates a change worktree, `fleet-core--create-change-workspace` chooses the sole remote, otherwise
  `origin`, otherwise the first remote, and records the resolved default branch as target. Task creation
  does not populate these fields; adopted-existing/reused worktrees bypass this selection path. Tools have
  no explicit remote/integration-target override. **Close with:**
  supported parameters/enforcement and multi-remote/scope tests, or truthful narrower descriptions.
  Do not assume a brief overrides those implementation choices; escalate a conflicting delivery contract.
- **Interface descriptions exceed enforcement:** `fleet-rpc--validate` only checks selected top-level
  shapes, not full nested JSON Schema/bounds. `fleet_wait.completion_report` is accepted but ignored;
  compact snapshots omit some advertised runtime/operation/attention information; `tools_list` is
  authenticated despite the transport schema's credential exception. **Close with:** actual request/result
  contract tests and reconciled schemas/descriptions. Clients must not depend on absent fields.
- **RPC evidence wait:** `fleet-rpc--sync-evidence` uses `accept-process-output` from request dispatch;
  it is a re-entrant synchronous wait, despite the async-only design/comment. **Close with:** deferred
  replies and concurrent/cancellation tests, or an explicitly reviewed bounded design.
- **Bridge CLI authority:** the bridge CLI can send mutations; it is not intrinsically a read-only
  diagnostic interface. (The former unterminated-input bound gap is closed: the MCP reader now rejects a
  line incrementally once it exceeds 1 MiB, see F17 and `tests/test_bridge.py`.)

## Verification and diagnostics

- **Test harness:** [`Makefile`](../Makefile) uses a fixed per-UID socket, ignores daemon-start failure,
  and later exits that server. Its output pipeline does not reliably fail on ERT failures. It also launches
  Emacs, incompatible with this checkout's `emacsclient`-only rule. Follow [testing](testing.md), not a
  remembered `make test`/process-kill recipe. **Close with:** explicit disposable-server selection,
  concurrency isolation, no accidental reuse/termination, and tests for client/ERT failure propagation.
- **Doctor coverage:** [`fleet-eca.el`](../lisp/fleet-eca.el) uses private symbols absent from its required
  lists (including `eca--path-to-uri` and `eca-chat--set-chat-loading`). An explicit but unusable executable
  can satisfy discovery. [`fleet.el`](../lisp/fleet.el) checks systemd availability rather than full manager
  health, and reports store/operation state only with an already-open store. **Close with:** complete
  required-symbol coverage and broken executable/manager/cold-store diagnostic tests. Do not start the
  dashboard for a supposedly passive check; it acquires/migrates/reconciles.
- **Native tool exclusion:** overlay construction is tested, server enforcement is not. Verify an operator's
  `tool/serverUpdated` excludes both `ask_user` and `spawn_agent`; commander's human question channel must
  remain available. No observed use in one task is not proof of absence. See
  [integration notes](eca-compatibility.md) and [native checklist](testing.md#pending-native-acceptance).
- **Native behavior acceptance:** truthful sent/queued feedback, bounded empty-turn retry/give-up, artifact
  workspace-name canonicalization, dirty-path refusal, and dashboard/chat/wire model/variant agreement
  still need recorded native acceptance. Deterministic regressions do not close these checks.
- **Provider error shape:** earlier native observation on ECA 0.159.0: a provider HTTP error lacked the
  `system` text beginning `Error:` that sets turn `error-text`; `$/showMessage` currently emits a separate
  `server-message`. Capture redacted error wire evidence before designing correlation to the in-flight
  turn. No undocumented chat-cache dependency. Explicit permission is required for a paid error probe.
  Consequence for the policy fallback (`fleet-supervisor--fall-back-model`): it keys on a *barren* turn (no
  text, no tool call), so a provider failure that surfaces as an empty completion still reaches the fallback
  after the same-model resend, but one that surfaces only as a `server-message` while the turn shows work,
  or that never terminates the turn, does not. A turn that did work and then errored is finished with its
  error text and is **not** actionable for the commander (unchanged from before); whether such a failure
  should wake the commander is an F11 question, not a fallback one.
- **Fallback and approval have no native acceptance:** `model-fallback`, `turn-failed`, and the
  `model-needs-approval` round trip are covered by fake-backed core/supervisor/RPC tests only. Wire-level
  confirmation that a re-pinned chat's next `chat/prompt` carries the fallback model and keeps history is
  listed under [pending native acceptance](testing.md#pending-native-acceptance).
- **Prompt-specific empty completions:** earlier native observation: some wordings returned no output and
  rephrasing worked. Cause is unproven; do not encode a provider/model/wording blacklist. After Fleet's
  bounded retry gives up, rephrase or investigate with an authorized probe. Lack of observed tool output
  is not general proof that no external effect occurred.
- **Missing usage:** earlier native observation: a successful turn had no usage notification. Current
  [`fleet-telemetry.el`](../lisp/fleet-telemetry.el) totals may undercount; absent usage is not proof of zero
  cost. **Close with:** provider-shape fixtures and clear unknown-versus-zero telemetry semantics.

## Native observations, zero-lieutenant run (2026-09-17)

First native run of the post-lieutenants merge (schema v3, `config.json`, fresh store): one root fleet, two
parallel `change` tasks on a repository with no remote, both delivered `local-ready`, both verified and
archived; three wake cycles, retention refs, `fleet-destroy`. The closed items below were fixed in the same
change as their regression tests; the open ones are recorded as evidence.

- **Closed — arguments lost to a long `brief`:** the commander's model dropped `model` and `delivery` from
  `fleet_task_create` whenever the inline `brief` ran to several KB, and dropped `brief` when it kept the
  rest (ECA refused those before the MCP server saw them). `brief_path` (`fleet-rpc--brief-text`) lets the
  brief travel as a file under the fleet directory; the commander doctrine prefers it.
- **Closed — silent `remote-review` on a remote-less repository:** the fixed default delivery contract was
  discovered only by the teardown evidence gate. `fleet-core-create-task` now judges it at admission
  (`fleet-git-remotes-now`; `delivery-needs-remote`; `delivery_source` on the event and result).
- **Closed — refused tool calls without a reason:** `toolCalled` with `error: true` now keeps its outputs
  text (clipped) in the transcript and `tool-finished` event. Fleet's RPC layer already journals its own
  refusals; ECA's schema refusals never reach it (see [integration notes](eca-compatibility.md)).
- **Closed — superseded failed operations kept raising attention:** `fleet-core-open-failed-operations`
  drops failures settled by a later same-kind success or by archiving the task/fleet; doctor uses it.
- **Closed — no owner-file selection for supervisors:** the commander ran on the ECA default while
  operators followed `models.default`, with no way to say otherwise short of a per-fleet pin. The owner
  wanted `default` to stay operator-only and supervisors to keep following the ECA default unless named,
  so the policy gained optional `commander` and `lieutenant` selections (`fleet-policy-supervisor`;
  `fleet-core-commander-model` reads them after the pin and the defcustom).
- **Considered, not adopted — refuse `owner_approved` without `model`:** the dropped `model` produced a
  policy-default task that the commander then retasked. A guard matching model names inside
  `model_reason` would interpret free text the schema promises never to interpret; a strict "approved
  implies model named" rule would make approving the default awkward for no remaining cause once briefs
  travel by file. Revisit only if a defaulted model under `owner_approved` recurs.
- **Open — `runtimes.main_pid` is the `systemd-run --wait` wrapper (child of Emacs), not the unit's
  `MainPID`.** Verdicts rest on `control_group`/`invocation_id`, so this is a naming question; keep it in
  mind when reading `main_pid` in evidence (F02).
- **Open — a stopped operator unit ends `ActiveState=failed`, `Result=exit-code`** (`eca server` exits
  non-zero on SIGTERM) and its runtime row reads `connection_state=lost` after a *requested* stop. The stop
  verdict is correct and `--collect` reaps the unit; only the wording invites misreading a normal teardown
  as a crash. A `SuccessExitStatus` on the transient unit or a `closed` connection state would remove the
  ambiguity.
- **Open — autonomous archive of a verified `local-ready` task:** the commander verified artifacts,
  requested teardown and archived without asking the user (worktree removed, branch kept, user told what
  remained). Consistent with doctrine; whether the owner wants a confirmation step for `local-ready` is an
  owner decision, not a defect.
- **Open — stale `refs/fleet/retained/*`:** the development clone carries retained refs from rehearsal
  fleets whose store was deleted. Harmless; an owner-side listing/prune of retained refs with no task in
  the store is D09.

## Optional or deferred work

- A human `fleet-retask` command is absent; core/RPC retask exists. Add only if prioritized, preserving
  normal admission, corrective brief, and explicit new-tasking rules.
- Additional native-approval notification/salience was **deferred by the owner**. Existing dashboard task
  attention is not absent. Empty-turn give-up currently has an event/minibuffer message, not dedicated
  header severity. Neither is an approved UI expansion merely because it appears here.
- Study-task deny rules were an unapproved idea, not a sandbox guarantee or committed feature.
- Automatic task-close inside `fleet-destroy` was rejected: preserve the explicit two-step human workflow.

The suspended-but-done workflow is documented in [commander doctrine](../prompts/commander.md): verify and
finalize, never rerun completed scope just to clear suspension; escalate an inadmissible teardown to the
human's explicit close command. It is not an outstanding request to weaken teardown.
