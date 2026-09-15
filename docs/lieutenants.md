# Lieutenants — plan and work tracking

[TODO backlog](../TODO.md) · [Contributor rules](../AGENTS.md) · [Development](development.md) ·
[Design](design.md) · [Known gaps](known-gaps.md)

This document is both the design of the lieutenant feature and its **work tracker**. `TODO.md` item
**L01** points here. Check boxes only with the same evidence standard as `TODO.md`: tests at the owning
layer, exact results reported.

**Status and next step.** The implementation is merged and covered by the deterministic suite; nothing
has run against native ECA yet. The next step is the **live rehearsal** in §8 (L01.8), owner-authorized
because it spends model turns: it decides whether the remaining items move back to `TODO.md` or this
file stays as the feature's reference. Before the first live use on a host that ran the old code:
restart Emacs (the loaded Lisp and the owner lease predate this feature), delete stale
`lisp/*.elc`, and — since the owner keeps no fleets from before — start with a fresh data root
(`rm -rf ~/.local/share/fleet ~/.cache/fleet`); `M-x fleet-dashboard` then creates a v3 store.

## 1. Purpose

A **lieutenant** is a long-lived supervisor for one domain of a project (say `frontend` or `backend`)
sitting between the fleet's commander and the operators that do the work. The commander talks to the
user and owns the overall outcome; a lieutenant owns a coherent part of it — it breaks its part into
tasks, briefs and supervises its own operators, verifies their deliverables and reports upstream. The
value is scale: routine operator events stay in the lieutenant's context window, domain knowledge
accumulates with the lieutenant, and the commander sees outcomes, decisions and blockers rather than
a copy of every operator event.

Fleets without lieutenants keep working exactly as before. One lieutenant level only.

## 2. The mapping: a lieutenant is a fleet whose parent is a fleet

Almost everything a supervisor needs already exists in Fleet **per fleet**: a commander runtime with
stop/replace, `commander/context.md` handoff, a task namespace, a wake lane and event receipts, a
logical actor that survives replacement (`fleet:<id>:commander`), fleet-scoped tool authorization, and
a dashboard group. So a lieutenant is a **child fleet**: `fleets.parent_id` names its root fleet. Its
commander runtime is a lieutenant because its fleet has a parent. Nothing about receipts, wake
batches, lanes, RPC scoping, replacement or park needs to be rewritten; they operate on the child
fleet like on any other.

| Document concept | Fleet implementation |
|---|---|
| supervisor identity, charter | `fleets` row with `parent_id`, `charter` |
| own runtime, replace, stop | `fleets.commander_runtime_id`, `fleet-commander-replace/stop` with a `root/child` selector |
| own memory | the child's `commander/context.md` (written by the lieutenant itself, read at its boot) |
| own task namespace and inbox | `tasks.fleet_id`, `event_receipts.fleet_id`, `wake_batches.fleet_id` |
| scope enforcement | `fleet-rpc--task-in-fleet` (a lieutenant cannot touch sibling or root tasks) |
| global workspace/resource claims | `resource_claims.key UNIQUE` already spans all fleets |
| delegation | a message on the child's lane + a `requests` row |
| report upstream | an actionable event in the parent fleet (wakes the commander through the existing hook) |

**Effective role.** `runtimes.role` stays `commander`/`operator` (no CHECK-constraint rebuild). The
effective role of a commander runtime whose fleet has a parent is `lieutenant`; `fleet-core-effective-role`
derives it. The effective role selects the tool list (`schema/tools-v1.json` `roles` now uses the
vocabulary `commander` / `lieutenant` / `operator`), the ECA tool overlay (a lieutenant gets neither
`spawn_agent` nor `ask_user`: its questions go up by tool, like an operator's), and the boot prompt.

**Names.** Lieutenant names are unique per parent, so the active-name index becomes
`(COALESCE(parent_id,''), name)`. Everywhere a fleet is named by the human (`fleet-commander-stop`,
`fleet-commander-replace`, `fleet-destroy`, dashboard `j`), a lieutenant is written `root/child`.
`fleet-core-fleet` resolves ids, root names and `root/child` selectors.

## 3. Owner configuration

One owner file, `~/.config/fleet/config.json` (`fleet-config-file`), replaces the earlier `models.json`
without a compatibility path: the owner has a single configuration and no fleets predating this change.
The `models` object is the unchanged model policy; `fleets` declares lieutenants:

```json
{
  "version": 1,
  "models": {
    "default": {"model": "openrouter/…"},
    "rules": [{"when": "…", "use": [{"model": "…"}]}],
    "ask_first": [],
    "fallback": {}
  },
  "fleets": {
    "workshop": {
      "lieutenants": {
        "frontend": {"charter": "UI, interaction design, accessibility and browser-facing implementation."},
        "backend":  {"charter": "Service APIs, persistence, data processing and server-side performance.",
                     "model": "openrouter/…", "variant": "high"}
      }
    }
  }
}
```

Rules: fleet and lieutenant names follow the usual name grammar; `charter` is required non-blank prose
(the commander routes by reading it, Fleet never interprets it); `model`/`variant` optionally pin the
lieutenant's commander (default: the root's commander pin); unknown keys, nested `lieutenants`, and
non-object values are refused with the file's path and the offending key. A broken `fleets` section
does not break model policy loading and vice versa: each section is validated on its own and the error
is reported where it matters (root start for `fleets`, task creation for `models`).

Configuration is **desired topology, applied at root commander start** (`fleet-new` and
`fleet-commander-replace` on a root): missing lieutenants are created and started, changed charters
and pins are recorded. It never deletes, detaches or reparents: a lieutenant that disappeared from the
file keeps existing (with its tasks) and `fleet-doctor` reports the drift. Retiring a lieutenant is
`M-x fleet-destroy root/child` with the usual empty-fleet rule.

## 4. Delegation protocol

Two tools, no new subsystem: parent → child is a message on the child's lane, child → parent is an
actionable event in the parent's inbox. Both are already durable, ordered, idempotent and wake-admitted.

- **`fleet_delegate`** (commander): `lieutenant`, `subject`, `text`, optional `request_id`. Without
  `request_id` it opens a request: inserts a `requests` row (`open`) and queues the text (origin
  `commander`, sender the root's actor) to the lieutenant's commander runtime with the request id and
  subject prefixed. With `request_id` it sends a follow-up on an existing open request (answer, more
  scope, "stop and settle"). Refuses when the lieutenant is not a child of the caller's fleet or its
  commander is not ready (`runtime-not-ready`: lieutenants are not started implicitly; the user
  restarts them). Returns the request id and the message's truthful lane state.
- **`fleet_report`** (lieutenant): `kind` ∈ `question` / `progress` / `settled`, `text`, optional
  `request_id`, and for `settled` an `outcome` ∈ `done` / `failed` / `partial`. Appends an actionable
  `lieutenant-report` event to the **parent** fleet (payload: child name, request id, kind, outcome,
  text as `detail`), which creates a receipt and wakes the commander through
  `fleet-store-actionable-event-hook`. `settled` also closes the `requests` row; a settled request
  cannot be settled again (`request-settled`). A report without `request_id` is an out-of-band notice
  (e.g. the human talked to the lieutenant directly). Refuses from a fleet without a parent.

`requests`: `id, parent_fleet_id, child_fleet_id, subject, state ('open','settled'), outcome, summary,
message_id, created_at, updated_at`. The request text lives in the message row; the brief contract
still applies (the commander writes a real brief). `fleet_snapshot` shows a root its lieutenants
(name, commander liveness, task tally, open requests) and a lieutenant its parent name and its
requests. A settled request is evidence for the commander to verify, not user acceptance or a merge.

## 5. Lifecycle rules

- **Start.** Root start ensures configured lieutenants exist and starts each whose commander is not
  live; the root's boot message lists them with their charters. A lieutenant boot is the commander
  prompt plus `prompts/lieutenant.md` (your user is the commander of fleet X; report by tool; no
  greeting; the human may still address you directly) plus its charter and, as for any commander, its
  `context.md` and snapshot.
- **Stop / replace** are per supervisor and non-cascading: `fleet-commander-stop root/child` and
  `fleet-commander-replace root/child` act on the lieutenant only; the root and all operators continue.
  Replacing the root leaves lieutenants running. Claims of a replaced lieutenant's runtime go to
  `needs-reconciliation` as for any commander. The commander can do the same without the human:
  when a lieutenant reports that its handoff is written and its context is long, `fleet_lieutenant_replace`
  (`fleet-supervisor-replace-lieutenant`) runs the identical stop → reconcile → start sequence as one
  `lieutenant-replace` operation, refused while the lieutenant is mid-turn, and completes as an actionable
  `lieutenant-replaced` / `lieutenant-replace-failed` event for the root.
- **Park / resume** are whole-fleet operations on the root: `fleet-park root` parks the root and every
  child (operators stop, supervisors stay), reports the descendant counts, and records per-child
  partial failure. `fleet-resume` recurses the same way. Dashboard `X` on a lieutenant row parks its
  root and says so. There is deliberately no per-lieutenant park.
- **Watch** (`fleet-watch-start/stop`) on a root applies to its children.
- **Destroy.** `fleet-destroy root` refuses while it has unarchived children; `fleet-destroy root/child`
  retires an empty lieutenant. Open requests block a lieutenant's retirement.
- **Old state.** Existing fleets have `parent_id NULL` and behave as before. No task is moved.
- **Model approvals.** A lieutenant routes its operators under the same `models` policy and hits the
  same `model-needs-approval` gate; having no user of its own, it batches its proposals for a request
  into one `fleet_report` `question`, the commander puts them to the human as it does for its own tasks
  and relays the answer on the request, and the lieutenant creates the tasks with `owner_approved`. The
  human may also answer in the lieutenant's chat directly. While `ask_first` is `["*"]` this costs one
  round trip per delegation; it fades as the rules converge. The commander never approves on the
  human's behalf.
- **Long context.** Handoff timing is the supervisor's judgement, for roots and lieutenants alike; a
  lieutenant writes `context.md`, reports `progress` "ready to be replaced", and the commander calls
  `fleet_lieutenant_replace`. Fleet has per-turn usage but no window size, so it gives no number yet
  (see L02 below).

## 6. Dashboard

Row identity stays `(fleet-id . task-id|commander)`. Rendering nests: root header, root tasks, then each
lieutenant's header (indented, labeled lieutenant) and its tasks, blank line, next root. `N`/`P` step
over all headers; `j` completes `root` and `root/child`; `RET`/`v`/`s`/`i`/`t`/`b`/`r`/`w` are
unchanged because the row identity is unchanged; `X` parks the root of the selected row. Attention on a
lieutenant header uses the same commander-status predicate. A configured but not yet created lieutenant
is not rendered (it does not exist until the root starts).

## 7. Non-goals and deferred work

Not wanted: per-lieutenant park, more than one lieutenant level, a separate message service, a second
model-routing policy for lieutenants.

Deferred (revisit after v1 ships; add to `TODO.md` if still wanted):

- **L02 — Context-size hint in wake messages** · **easy–medium**. Fleet records each finished turn's
  `usage` (telemetry) but a supervisor never sees its own token count, so "context is getting long" is
  a guess. Proposal: an optional per-model (or single) `context_tokens` threshold in `config.json`;
  when a supervisor's last observed usage exceeds it, `fleet-supervisor--wake-text` appends one line
  ("your last turn reported N tokens; write your handoff and report ready-to-replace"). Decision left
  with the model; Fleet supplies the number. Caveats from `known-gaps.md`: usage is sometimes absent
  (no hint then, never a false one) and Fleet does not know window sizes, hence an owner threshold.
  Decide where the threshold lives before implementing; test with fake usage.
- **Structured request bodies** (acceptance, constraints, authority as fields). v1 keeps the brief in
  prose, as commander→operator briefs are.
- **Cancel semantics.** v1 cancels by follow-up message asking the lieutenant to stop and settle
  `partial`; no `cancel-requested` state.
- **Human-intake notice automation.** v1 relies on doctrine: a lieutenant addressed directly by the
  human reports it with an out-of-band `fleet_report`.
- **Lieutenant-aware `fleet-timeline`/`fleet-stats` grouping.**

## 8. Work tracker

Sequence is top to bottom; each step keeps every existing test green. Owning layer and test file in
parentheses. Verify through the disposable `fleet-test` server per [testing](testing.md).

- [x] **L01.1 Schema and store** (`schema/003.sql`, `fleet-store.el`, `fleet-store-tests.el`):
  `fleets.parent_id`, `fleets.charter`, per-parent active-name index, `requests` table;
  `fleet-store-schema-version` 3; `fleet-store-fleet-by-name` takes an optional parent; v2→v3 upgrade
  test on a populated fixture proves existing rows keep `parent_id NULL` and the old name index is gone.
  Tests: `fleet-store-lieutenant-names-are-unique-per-parent`, `fleet-store-v2-database-upgrades-to-v3-keeping-roots`.
- [x] **L01.2 Core identity** (`fleet-core.el`, `fleet-core-tests.el`): `fleet-core-create-fleet
  :parent-id :charter` (one level: a parent with a parent is refused, `nested-lieutenant`);
  `fleet-core-fleet` resolves `root/child`; `fleet-core-fleet-selector` renders it;
  `fleet-core-effective-role`; overlay disables `ask_user` for lieutenants; `fleet-core-lieutenants`
  lists children. Test: `fleet-core-lieutenant-is-a-child-fleet-with-selector-and-effective-role`.
- [x] **L01.3 Owner config** (`fleet-policy.el`, `fleet-policy-tests.el`, `quickstart.md`):
  `config.json` with `models` and `fleets` (no `models.json` fallback; the owner migrated); `fleet-config-lieutenants
  fleet-name` with validation errors naming the key; `fleet-doctor` reports the file in use and each
  section's validity. Tests: `fleet-policy-config-json-*`, `fleet-core-configured-lieutenants-are-created-updated-and-never-removed`.
- [x] **L01.4 Boot and prompts** (`fleet-core.el`, `prompts/lieutenant.md`, `prompts/commander.md`,
  core tests): root boot `## Lieutenants` section; lieutenant boot with parent, charter and doctrine;
  commander doctrine section on delegating. Test: `fleet-core-lieutenant-boot-carries-charter-and-root-boot-lists-lieutenants`.
- [x] **L01.5 Requests and tools** (`schema/tools-v1.json`, `fleet-rpc.el`, `fleet-supervisor.el`,
  supervisor tests): `fleet_delegate`, `fleet_report` (`fleet-supervisor-delegate/-report`), tool
  `roles` vocabulary with `lieutenant`, effective role in `fleet-rpc-authenticate`; snapshot
  `:open-requests`; wake text names lieutenant, kind and request. Test:
  `fleet-supervisor-delegation-is-a-lane-message-down-and-an-actionable-event-up` (lane message down,
  actionable receipt and admitted wake up, replay, scope refusals, settle-once, tool visibility).
  `fleet_lieutenant_replace` (`fleet-supervisor-replace-lieutenant`), test
  `fleet-supervisor-lieutenant-replace-is-non-cascading-and-wakes-the-root`.
  Not yet covered: a wire-level RPC test through `fleet-rpc-dispatch` for the three tools (the handlers
  are thin; add one when touching `fleet-rpc-tests.el`).
- [x] **L01.6 Lifecycle glue** (`fleet.el`, `fleet-core.el`, core tests): `fleet-core-ensure-lieutenants`
  applied and lieutenants started by `fleet--start-commander-and-show` on a root; selectors in
  `fleet-new`/stop/replace/destroy/watch; `fleet-core-park-fleet` recurses with per-child operation
  rows; `fleet-core-resume-fleet` recurses and refuses a lieutenant; retire refuses lieutenants and open
  requests. Test: `fleet-core-park-and-resume-cover-lieutenants-and-retire-refuses-them`. The `fleet.el`
  command layer (`fleet--start-lieutenants`, prompts, messages) has no ERT coverage, as before for that file.
- [x] **L01.7 Dashboard** (`fleet-dashboard.el`, `fleet-dashboard-tests.el`): nested rendering,
  `j` selectors, `X` to the root, open-request count on headers; row identity unchanged so refresh
  restores selection. Test: `fleet-dashboard-lieutenants-nest-under-their-root`.
- [ ] **L01.8 Documentation and acceptance** (`quickstart.md`, `development.md`, `prompts/`):
  - [x] Guides updated; full non-native suite on a fresh `fleet-test` daemon: at the feature commit
    **146 passed, 3 skipped (native opt-in), 150 total**; at the follow-up commit (config simplified,
    `fleet_lieutenant_replace` added) **147 passed, 1 failed, 3 skipped, 151 total**, the failure being
    a `cl-flet`→`cl-labels` slip in the new replace function, fixed and re-run singly to green. Python
    bridge tests 9/9.
  - [ ] **Live rehearsal — the next step** (owner-authorized, costs model turns; fresh data root as
    described at the top). Suggested script, in order, each with its evidence:
    1. `config.json`: under `fleets.master.lieutenants` add one entry (e.g. `study` with a charter
       covering research/study work). `M-x fleet-dashboard`, `M-x fleet-new master`: the lieutenant is
       created and started with the root and appears nested; `fleet-doctor` shows the config line green.
    2. Ask the commander for a small study that falls under the charter: it should `fleet_delegate`
       rather than create an operator; the dashboard shows `1 open request` on both headers.
    3. With `ask_first: ["*"]`, the lieutenant's model proposal should arrive as one relayed question
       from the commander; answer it; the lieutenant creates and starts its operator.
    4. The lieutenant verifies the report and settles; the commander verifies and reports to you.
    5. `M-x fleet-commander-replace master` while the lieutenant's operator works: no operator
       restart, request intact, successor lists the lieutenant.
    6. Ask the lieutenant (directly in its chat) to write its handoff and report ready; the commander
       should call `fleet_lieutenant_replace`; check `lieutenant-replaced` in its next wake.
    7. `M-x fleet-park master` then resume: both supervisors retained, operators stopped and resumable.
    8. `M-x fleet-destroy master/study` while its task exists: refused with the reason.
    Record redacted evidence (wire fixtures per [integration notes](eca-compatibility.md) where the
    native tool list or a prompt shape is involved), then decide whether the remaining items fold
    into `TODO.md` or this file stays as the feature's reference.
  - [x] `docs/design.md` points here from its model-policy note; a fuller design section can wait for
    the next design edit.
