# Fleet TODO

[Contributor rules](AGENTS.md) · [Module/test map](docs/development.md) ·
[Source evidence](docs/known-gaps.md) · [Verification procedures](docs/testing.md)

This is the **canonical prioritized backlog**: task IDs, status, difficulty, dependencies and acceptance.
`docs/known-gaps.md` holds supporting source findings and technical closure details, not a second task queue.
Initial triage is based on the source review at `7ad225b`; findings were not all reproduced at runtime.
Recheck current code before implementing. Unverified native behavior is not automatically a broken feature.

## How to use this backlog

- **easy:** localized change with focused regression tests and little design uncertainty.
- **medium:** bounded work across several functions/interfaces, with integration or protocol tests.
- **hard:** crash recovery, asynchronous identities, uncertain outcomes, or substantial design/investigation.
- Difficulty includes tests/docs, is not a time estimate, and is independent of priority. Revise it when
  investigation changes the scope. Stable IDs are for task briefs; do not renumber existing items.
- An unchecked box means **not completed**, not permission to execute. Deferred items need an owner decision.
  Agree on a bounded set of IDs before dispatching; this file does not authorize the whole backlog, live
  operations, merges, pushes, provider spending, credential access, or changes to owner preferences.
- Follow `AGENTS.md`: isolated worktrees, existing disposable test server via `emacsclient`, never tests in
  the editing server or real owner fleets. Native/systemd/provider probes need explicit opt-in and no active
  owner fleets. Do not weaken evidence gates or silently resend unknown work to make a test pass.
- Check a box only after the stated acceptance and linked technical criteria are met. Record a concise
  completion commit/test reference, update the relevant guides and remove or qualify the obsolete finding
  in `docs/known-gaps.md`. Keep session narratives and private incident data out of this file.

**Suggested sequence:** F01 → small foundation fixes F02–F05 → messaging/recovery F06–F10, with F11 for
error clarity. Human decisions (F08) can proceed independently of message reconciliation, subject to file
ownership. V01 is an early authorized verification task; run relevant V02 checks alongside behavior changes,
not only after everything else. F14 should accompany any expansion of automatic mutation retries.

Parallelize only genuinely independent ownership areas. Several IDs touch `fleet-core.el`,
`fleet-supervisor.el` or `fleet-rpc.el`; give those files one owner or sequence the patches. F01 is the
recommended verification foundation, not a reason to skip tests: until fixed, use the documented safe
existing-server procedure. Source work, native acceptance, and live activation are separate stages.

## 0. Feature landing — tracked in its own document

- [ ] **L01 — Lieutenants: domain supervisors between commander and operators** · **hard**
  - **Payoff:** a commander delegates a whole domain (frontend, backend, …) to a long-lived lieutenant
    that owns its own operators, context and inbox; routine operator traffic stays out of the
    commander's context and the fleet scales.
  - **Status:** implemented and covered by the deterministic suite (schema v3, `config.json`,
    `fleet_delegate`/`fleet_report`/`fleet_lieutenant_replace`, nested dashboard). The shared paths ran
    natively on 2026-09-17 with a zero-lieutenant fleet (two parallel change tasks, three wake cycles,
    teardown, destroy); findings in [known gaps](docs/known-gaps.md#native-observations-zero-lieutenant-run-2026-09-17).
    **Next: the live rehearsal** of the lieutenant paths scripted in the tracker.
  - **Plan, decisions and step-by-step tracker:** [docs/lieutenants.md](docs/lieutenants.md). Check this
    box only when that document's tracker is complete or its remainder has been moved back here.
    L02 (context-size hint in wake messages) is proposed there and waits for an owner decision.

## 1. Correctness foundation — do first

- [ ] **F01 — Make verification reliable and isolated** · **medium**
  - **Payoff:** trust test results and avoid reusing or terminating another worktree's test server.
  - **Done:** client/ERT failures and empty test selections fail the command; existing disposable-server
    selection is explicit; no implicit Emacs launch/shutdown or socket collision; native opt-in is set in
    the actual server environment. Test failure propagation and concurrent invocation/refusal paths.
  - **Start:** `Makefile`, `tests/fleet-test-runner.el`; [harness evidence](docs/known-gaps.md#verification-and-diagnostics).

- [ ] **F02 — Fail closed on unreadable cgroup evidence** · **easy**
  - **Payoff:** ambiguous process evidence cannot authorize replacement or workspace removal.
  - **Done:** distinguish verified absence/empty from unreadable, malformed and failed reads; the latter
    stay unknown. Cover stop verdicts and downstream refusal, including permission/read failures.
  - **Start:** `lisp/fleet-runtime.el`; [evidence gaps](docs/known-gaps.md#fail-closed-evidence).

- [ ] **F03 — Refuse ambiguous or corrupt owner metadata** · **medium**
  - **Payoff:** a damaged descriptor is not silently treated as permission to acquire ownership.
  - **Done:** malformed/partial descriptors fail closed; valid live/dead/released-owner behavior is covered;
    document an explicit owner-authorized recovery path without guessed identity or lock deletion.
  - **Start:** `lisp/fleet-supervisor.el`; [evidence gaps](docs/known-gaps.md#fail-closed-evidence).

- [x] **F04 — Enforce external-job ownership on updates** · **easy**
  - **Payoff:** one operator cannot corrupt another task's external-job record by supplying its ID.
  - **Done:** `fleet-core-external-job` refuses `forbidden` before the transaction unless the existing job's
    task and fleet match the caller; tests `fleet-core-external-job-updates-are-owned-by-the-registering-task`
    and `fleet-rpc-external-job-refuses-another-tasks-job-id` cover same-task update, cross-task/cross-fleet
    refusal, unchanged row and no event on refusal. The `fleet_operation` cross-task read stays F15.

- [ ] **F05 — Complete actionable doctor preflight checks** · **medium**
  - **Payoff:** broken dependencies produce useful diagnostics instead of mysterious launch failures.
  - **Done:** required private symbols cover actual use; invalid executable and unavailable user manager
    are detected; cold-store versus already-open-store coverage is explicit and inspection does not
    secretly start/acquire Fleet. Test each refusal; retain no-version-pinning policy.
  - **Start:** `lisp/fleet-eca.el`, `lisp/fleet.el`; [doctor evidence](docs/known-gaps.md#verification-and-diagnostics).

## 2. Highest daily workflow payoff

- [ ] **F06 — Detect and safely reconcile stuck message lanes** · **hard**
  - **Payoff:** eliminate unexplained "sent something, nothing happens, lane stays busy" situations.
  - **Done:** detect persisted in-flight messages with no matching adapter turn; surface the exact reason
    and next action; define identity-safe reconciliation for each evidence class. Test crashes, late
    callbacks and replacement runtimes. Unknown delivery stays uncertain, never blindly resent.
  - **Start:** `lisp/fleet-supervisor.el`, adapter seams, doctor; [delivery evidence](docs/known-gaps.md#recovery-and-delivery).
  - **Coordinate:** F07 shares message/identity policy; F05 owns generic doctor changes.

- [ ] **F07 — Reconcile held messages across operator replacement** · **hard**
  - **Payoff:** park/resume no longer leaves retained text silently addressed to a stopped predecessor.
  - **Done:** define handling for never-attempted, attempted, unknown and obsolete-brief messages; rebind
    only when justified, otherwise surface reconciliation. Test replacement/runtime/brief identities,
    delivery feedback and crash boundaries without replaying uncertain actions.
  - **Start:** `lisp/fleet-core.el`, `lisp/fleet-supervisor.el`; [held-message evidence](docs/known-gaps.md#recovery-and-delivery).
  - **Coordinate:** settle shared reconciliation rules with F06 before parallel implementation.

- [ ] **F08 — Complete human-authority decision resolution** · **medium**
  - **Payoff:** operator asks → human answers → durable resolution → operator receives answer → attention clears.
  - **Done so far (2026-09-19):** the commander's relay (`owner_approved` after the user answered in chat)
    closes human-authority rows in its own fleet and in its lieutenants' fleets; the row/event record human
    authority by relay with the relaying runtime and fleet; a resolution by anyone but the fleet's own
    commander is actionable for that fleet so it delivers; duplicate, stale-revision, unrelated-commander,
    lieutenant and operator refusals are tested (`fleet-rpc-root-commander-relays-the-humans-answer-into-a-lieutenants-decision`,
    `fleet-core-decision-resolve-records-relay-and-wakes-the-fleet-that-must-deliver`; design note 21).
  - **Remaining:** provide an explicit human-authorized command/UI (`actor` `human`, no relay evidence
    needed; core already wakes the fleet's commander to deliver); truthfully expose a delivery failure;
    end-to-end attention-state test. Chat text alone is not resolution.
  - **Start:** `lisp/fleet.el`, dashboard; [decision gap](docs/known-gaps.md#authority-and-interface).

- [ ] **F09 — Recover operation journals even with no live runtimes** · **medium**
  - **Payoff:** startup cannot leave interrupted operations "running" merely because nothing needs stopping.
  - **Done:** reach operation recovery independently of runtime count; cover the actual startup path with
    zero nonterminal runtimes and interrupted brief publication/retirement, including repeated recovery.
    Existing direct-helper tests alone are insufficient.
  - **Start:** `lisp/fleet-core.el`, core startup tests; [recovery gap](docs/known-gaps.md#recovery-and-delivery).

- [ ] **F10 — Make interrupted retask intent recoverable** · **hard**
  - **Payoff:** changing direction and restarting Emacs do not strand a task between old and new briefs.
  - **Done:** persist enough replacement intent before stopping; implement explicit recovery or actionable
    refusal across stop, brief publication and restart boundaries. Preserve claims/workspace, revisions
    and predecessor stop proof; test repeated recovery and late callbacks.
  - **Start:** `lisp/fleet-core.el`, operation persistence; [retask gap](docs/known-gaps.md#recovery-and-delivery).
  - **Depends on:** F09's startup recovery integration; coordinate operation dispatch changes.

- [ ] **F11 — Surface the actual cause of failed or apparently empty turns** · **medium**
  - **Payoff:** show an actionable provider/turn error instead of silence or misleading success.
  - **Done:** obtain redacted supported wire evidence, correlate relevant errors with the right in-flight
    turn, and distinguish errors from observed-empty completion. Test notification ordering, late errors,
    cancellation and retry eligibility. No undocumented chat-cache dependency or assumed absence of effects.
  - **Start:** `lisp/fleet-eca.el`, supervisor feedback; [provider observations](docs/known-gaps.md#verification-and-diagnostics).
  - **Gate:** new native/error probes require opt-in; investigate this before wording-specific D07.
  - **Note:** the owner model-policy fallback (design note 19) already turns a *barren* errored turn into a
    `model-fallback` then `turn-failed`; F11 is about errors on turns that did work, and about errors that
    reach Fleet only as `server-message`.

- [x] **F12 — Owner model policy: natural-language routing rules for the commander, ask-first gate, provider fallback** · **medium**
  - **Payoff:** the user stops naming models per task; expensive models (or, while shaping the rules with
    `"*"`, every task) need one explicit yes; an OpenRouter outage moves a runtime to the configured
    fallback instead of stalling.
  - **Done:** `lisp/fleet-policy.el` + `~/.config/fleet/config.json` (`models`; originally `models.json`); `fleet_task_create` requires
    `model_reason` and accepts `owner_approved`; `model-needs-approval` refusal echoing the proposal;
    `model-fallback`/`turn-failed` events; boot-message policy section; commander doctrine. Tests:
    `fleet-policy-tests.el`, `fleet-core-operator-model-follows-owner-policy-and-ask-first-gate`,
    `fleet-supervisor-barren-turn-falls-back-to-the-policy-model-once`. Native acceptance pending (V02).
  - **Evidence:** [design note 19](docs/design.md), [fallback limits](docs/known-gaps.md#verification-and-diagnostics).

## 3. Native verification — early, explicit, bounded

These are acceptance tasks, not pre-approved paid probes or an instruction to use owner fleets as fixtures.
Use [the native checklist](docs/testing.md#pending-native-acceptance) and retain redacted evidence with scope.

- [ ] **V01 — Verify native operator tool exclusion** · **medium**
  - **Payoff:** operators cannot accidentally bypass commander-mediated questions or spawn hidden subagents.
  - **Done:** an authorized disposable operator's advertised native tool list excludes both `ask_user` and
    `spawn_agent`; the commander's human question channel remains available. Overlay construction and
    absence of calls are not proof. If enforcement fails, record a blocker/follow-up, not a passing check.
  - **Start:** `docs/eca-compatibility.md`, native fixtures/tests; [exclusion evidence](docs/known-gaps.md#verification-and-diagnostics).

- [ ] **V02 — Record native acceptance for user-visible contracts** · **medium**
  - **Payoff:** establish that fake-backed improvements work through the installed frontend/server.
  - **Done:** record scoped results for sent/queued/held feedback; bounded empty-turn retry/give-up;
    requested/wire/runtime/chat/dashboard model/variant agreement; policy-chosen model, ask-first refusal
    and fallback re-pin in the same chat (F12); artifact-name canonicalization; and
    dirty/untracked/ignored-path cleanup refusal. Separate observed, failed and skipped coverage.
  - **Start:** [pending native acceptance](docs/testing.md#pending-native-acceptance).
  - **Coordinate:** test affected contracts after their relevant fixes; partial coverage does not close V02.

## 4. Situational correctness and robustness

Prioritize when the affected workflow is used; these are not merely cosmetic. F14 is especially relevant
before adding automatic retries, and F12 before migration/restore or frequent live-code maintenance.

- [ ] **F12 — Provide a verified shutdown/backup/restore maintenance path** · **hard**
  - **Payoff:** maintenance has one reviewed procedure rather than ad hoc store/lease/RPC surgery.
  - **Done:** account for all fleets/runtimes, pending operations, callbacks, external artifact writers,
    RPC connections, lease and DB handles; protect backup destinations and capture matching DB/artifacts
    with WAL awareness. Rehearse failures and restore only in isolated roots; document separate activation.
  - **Start:** supervisor/core/store/RPC; [maintenance evidence](docs/known-gaps.md#recovery-and-delivery), [recovery](docs/recovery.md).
  - **Depends on:** F09/F10 for interrupted-operation handling; review F02/F03 before relying on stop/owner proof.

- [ ] **F13 — Make context inputs effective and brief validation truthful** · **medium**
  - **Payoff:** an operator does not silently miss context that task creation appeared to supply.
  - **Done:** either wire supported `context_paths` into boot context/authorized roots with containment
    tests, or explicitly reject/remove unsupported inputs through a reviewed contract change. Distinguish
    enforceable field checks from semantic brief guidance; do not silently broaden permissions.
  - **Start:** core task creation/boot, tool schema/doctrine; [scope evidence](docs/known-gaps.md#authority-and-interface).

- [ ] **F14 — Make status and wait submissions safely idempotent** · **medium**
  - **Payoff:** uncertain tool results do not produce duplicate decisions/events on retries.
  - **Done:** align status/wait schema, handlers and doctrine on a replay-safe contract; test repeated
    identical submissions, conflicting reuse and uncertain results. Plan compatibility for existing callers;
    do not simply tell an agent to send keys rejected by the current schema. A replayed identical
    `fleet_wait` must not restart the wait watchdog's clock (it anchors on the latest `task-paused` event).
  - **Start:** core/RPC/store, `schema/tools-v1.json`; [idempotency evidence](docs/known-gaps.md#authority-and-interface).

- [ ] **F15 — Align the advertised tool interface with actual behavior** · **medium**
  - **Payoff:** agents can rely on supported inputs, outputs and authority rather than discovering silent gaps.
  - **Done:** resolve ignored `completion_report`, overpromised snapshot fields, validation depth/bounds and
    authenticated `tools_list` documentation. Decide/test operator visibility of same-fleet operations.
    Decide whether `fleet_wait.job_id` must name a registered external job (today an unregistered id pauses
    as declared; see [waits on unregistered job ids](docs/known-gaps.md#authority-and-interface)).
    Prefer narrowing unsupported promises over gratuitous features; add request/result/refusal contract tests.
  - **Start:** `lisp/fleet-rpc.el`, schemas, bridge and doctrine; [interface evidence](docs/known-gaps.md#authority-and-interface).
  - **Coordinate:** F04 owns job mutation checks; F13/F14 own their inputs; split this item into bounded
    sub-tasks before dispatch if needed, retaining this ID as the parent rather than mixing unrelated changes.

- [ ] **F16 — Remove the re-entrant synchronous cleanup-evidence wait** · **hard**
  - **Payoff:** slow Git evidence does not create surprising RPC/event-loop behavior as concurrency grows.
  - **Done:** implement deferred responses, or obtain an explicit reviewed bounded design; cover concurrent
    requests, timeout, cancellation, disconnect and stale owner/runtime callbacks without blocking policy
    in a process filter. Preserve single-pass cleanup evidence semantics.
  - **Start:** `fleet-rpc--sync-evidence` and Git callbacks; [wait evidence](docs/known-gaps.md#authority-and-interface).

- [x] **F17 — Bound unterminated bridge input incrementally** · **easy**
  - **Payoff:** malformed input cannot grow buffers without reaching the advertised line-size check.
  - **Done:** `McpServer.serve` rejects an unterminated line with `-32700 "message too large"` as soon as
    it exceeds `MAX_REQUEST_BYTES`, then discards bytes up to the next newline and resumes framing; EOF
    inside a rejected line exits 0 after that single error. Tests: `test_bridge.py`
    `test_oversized_unterminated_input_is_rejected_before_newline`,
    `test_oversized_unterminated_input_then_eof_terminates_cleanly`,
    `test_large_valid_request_split_across_chunks_is_not_truncated` (plus the pre-existing
    `test_split_frames_malformed_and_oversize`). Branch `fleet/fleet/F17-bridge-input-bound`.
  - **Evidence:** [bridge README](bridge/README.md#socket-protocol).

## 5. Deferred or optional — owner selection required

These are remembered possibilities, not assignments. Preserve the existing deferral unless the owner
reprioritizes it. An easy label is not a reason to implement unsolicited UI or policy changes.

- [ ] **D01 — Add native-approval notification/salience** · **medium**
  - Existing dashboard attention is present; additional notification was explicitly deferred.
  - **Done if selected:** agree on the attention/message behavior, test transitions and deduplication,
    and avoid notification noise or commander/automatic approval authority.
  - **Evidence:** [deferred UI](docs/known-gaps.md#optional-or-deferred-work).

- [ ] **D02 — Give empty-turn give-up durable dashboard attention** · **easy**
  - Add visibility beyond the current event/minibuffer message only if desired.
  - **Done if selected:** attention appears and clears from truthful state, without a self-waking failure
    loop; cover rendering and action semantics. Coordinate with F11, not an independent error model.
  - **Evidence:** [deferred UI](docs/known-gaps.md#optional-or-deferred-work).

- [ ] **D03 — Add a human retask command** · **medium**
  - Convenience: core/RPC retask already exists. Prefer finishing F08's missing decision path first.
  - **Done if selected:** reuse normal admission, corrective brief/new-scope rules and async results;
    test command/UI refusal and success. Do not add a force-restart shortcut; finish F10 recovery first.
  - **Evidence:** [retask option](docs/known-gaps.md#optional-or-deferred-work).

- [ ] **D04 — Support explicit remote and integration-target selection** · **medium**
  - Useful when actual repositories need more than the existing selection rules; not a default expansion.
  - **Done if selected:** agree on create/retask/adopt/reuse semantics, persist and validate selections,
    and test multi-remote/default-branch cases plus preservation gates. A brief alone cannot override settings.
  - **Evidence:** [delivery parameter limits](docs/known-gaps.md#authority-and-interface).

- [ ] **D05 — Display unknown usage separately from zero** · **easy**
  - A small optional clarity improvement; missing usage does not prove a free turn.
  - **Done if selected:** retain missing-versus-zero semantics in projections/display; test absent, explicit
    zero and reported usage without fabricating costs. Escalate scope if persistence needs a migration.
  - **Evidence:** [usage observation](docs/known-gaps.md#verification-and-diagnostics).

- [ ] **D06 — Improve provider usage accounting** · **medium**
  - Lower priority unless accurate per-turn accounting is needed; D05 can stand alone.
  - **Done if selected:** capture authorized/redacted usage shapes, test cumulative-to-delta behavior and
    missing/out-of-order notifications, and document remaining undercount rather than claiming full accuracy.
  - **Evidence:** [usage observation](docs/known-gaps.md#verification-and-diagnostics).

- [ ] **D07 — Investigate prompt-specific empty completions** · **hard**
  - Cause remains unproven and could be upstream; prioritize F11 error evidence first.
  - **Done if selected:** agree on a bounded investigation/budget, preserve a minimal redacted reproducer,
    and report supported findings, inconclusive limits and any upstream follow-up. Do not promise a Fleet
    fix, invent a wording blacklist, or retry paid probes indefinitely.
  - **Evidence:** [empty-completion observation](docs/known-gaps.md#verification-and-diagnostics).

- [ ] **D08 — Evaluate study-task deny rules** · **hard**
  - An unapproved design idea, not an existing filesystem sandbox or a commitment to build one.
  - **Done if selected:** first produce a bounded design/decision on desired enforcement and limitations;
    any implementation needs separate scope and must not misrepresent same-UID execution as isolation.
  - **Evidence:** [study policy option](docs/known-gaps.md#optional-or-deferred-work).

- [ ] **D09 — List and prune orphaned retained refs** · **easy**
  - **Payoff:** `refs/fleet/retained/<task>` from fleets whose store was deleted stop accumulating in the
    owner's clones.
  - **Done if selected:** an explicit owner command lists retained refs in a repository with no task row in
    the store and deletes only on confirmation; never automatic, never for tasks that still exist.
  - **Evidence:** [zero-lieutenant run](docs/known-gaps.md#native-observations-zero-lieutenant-run-2026-09-17).

- [ ] **D10 — Make a requested stop read as one** · **easy**
  - **Payoff:** a normal teardown does not look like a crash in `systemctl`/journal (`Result=exit-code`) or
    in the runtime row (`connection_state=lost`).
  - **Done if selected:** the transient unit treats the ECA server's SIGTERM exit as success, or the
    verdict/observation path records a distinct closed state; stop verdicts and fail-closed tests unchanged.
  - **Evidence:** [zero-lieutenant run](docs/known-gaps.md#native-observations-zero-lieutenant-run-2026-09-17).

- [ ] **D11 — Watch idle runtimes that declared no wait** · **medium**
  - **Payoff:** an operator whose turn ended without a status (no `paused`, no `done`) and that has no
    queued message is noticed before a human reads its chat buffer.
  - **Done if selected:** define the evidence that distinguishes "idle, awaiting the commander" from
    "stalled" without polling a model; emit one actionable event per incident through the same tick and
    idempotency rule as the wait watchdog (design note 20; opt-in like it). Coordinate with F06 (stuck lanes) and F11.
  - **Evidence:** the 2026-09-19 wait incident was a declared wait, which note 20 now covers; the undeclared
    case is out of its scope.

## Not TODOs — preserve these decisions

- Automatic task-close inside `fleet-destroy` was rejected. Keep explicit human close separate from
  empty-fleet retirement; do not infer authorization to discard work.
- Suspended-but-done tasks are verified/finalized, not rerun to clear suspension. The workflow is already
  documented in [commander doctrine](prompts/commander.md); it is not a request to weaken teardown.
- Do not introduce a sandbox/backend redesign, global trust changes, version gates, undocumented cache
  parsing, or private session-log migration as incidental "cleanup." Model selection is owner policy
  (F12): extend it through `models` in `~/.config/fleet/config.json`, never through product defaults or commander
  discretion.
