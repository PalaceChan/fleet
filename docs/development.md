# Development

[Contributor rules](../AGENTS.md) · [TODO backlog](../TODO.md) · [Testing](testing.md) · [Source evidence](known-gaps.md)

## Start a session

1. Read root `AGENTS.md`; inspect Git status, branch, diff, and worktrees. Choose a bounded authorized set
   of IDs from [TODO.md](../TODO.md), then read the linked evidence in `known-gaps.md`. The backlog is not
   blanket execution permission. Do not infer running Fleet state or loaded Lisp from the checkout's HEAD.
2. Use a short-lived worktree from clean `master` for substantial work; keep unrelated worktrees intact.
   Repo-relative commands assume that worktree is the working directory. Nothing requires an Org checkpoint,
   old chat transcript, specific model, or remembered process ID to start contributing.
3. Find the owner below, read its implementation and tests, then the relevant guide. Read design sections
   for rationale, not as an instruction to reimplement the project. Inspect actual schema fields before SQL.
4. Make the smallest change and an owning-layer regression test. Follow the approved verification route in
   `testing.md`; report omitted checks honestly. Review the diff for unrelated edits and private state.
5. Update current guidance in place. `TODO.md` owns task status, priority and difficulty; check off an item
   only with acceptance evidence and qualify/remove the obsolete finding in `known-gaps.md` in the same
   change. Keep session chronology in commits, not a checkpoint document. Merging source does not load it.

## Module and change-impact map

All Lisp is under [`lisp/`](../lisp/); tests under [`tests/`](../tests/).

| Concern | Owner / useful entry point | Regression suite and companion docs |
|---|---|---|
| Public commands, install, human close | `fleet.el` | dashboard/core suites; [quickstart](../quickstart.md) |
| XDG roots, identities, containment, artifact hashes | `fleet-paths.el` | `fleet-paths-tests.el`; design §3 |
| SQLite transactions, migrations, projections, idempotency | `fleet-store.el` | `fleet-store-tests.el`; [`schema/`](../schema/), design §7 |
| Task create/start/retask, park/teardown/retire, recovery | `fleet-core.el` | `fleet-core-tests.el`; [recovery](recovery.md), design §10 |
| Owner configuration `config.json`: model policy (rules, default, ask-first gate, fallback) and lieutenant declarations | `fleet-policy.el` (pure; applied by core and supervisor) | `fleet-policy-tests.el`, policy cases in core/supervisor suites; [quickstart](../quickstart.md) |
| Lieutenants: child fleets, selectors, effective role, delegation requests/reports, whole-fleet park | `fleet-core.el` (identity, boot, park), `fleet-supervisor.el` (`fleet-supervisor-delegate/-report`), `fleet.el` (start with root) | lieutenant cases in core/supervisor/dashboard suites; [plan and tracker](lieutenants.md) |
| Ownership, delivery lanes, wake batches, receipts | `fleet-supervisor.el` | `fleet-supervisor-tests.el`; design §6/§8/§9 |
| ECA wire events, frontend advice, model/variant pinning | `fleet-eca.el` | `fleet-eca-tests.el`, `tests/fake_eca.py`, redacted fixtures; [integration](eca-compatibility.md) |
| systemd launch/stop and cgroup proof | `fleet-runtime.el` | `fleet-runtime-tests.el`; design §6 |
| Worktree ownership, Git preservation/removal evidence | `fleet-git.el` | `fleet-git-tests.el`; design §11 |
| Roles, RPC validation, tools, model-facing projections | `fleet-rpc.el` | `fleet-rpc-tests.el`; [`tools-v1.json`](../schema/tools-v1.json), [`rpc-v1.json`](../schema/rpc-v1.json) |
| Socket client, stdio MCP framing, flock helper | `bridge/fleet_bridge.py` | `test_bridge.py`; [bridge README](../bridge/README.md) |
| Dashboard keymaps, attention, rendering | `fleet-dashboard.el` | `fleet-dashboard-tests.el`, `tests/fixtures/dashboard/`; quickstart key table |
| Turn/tool/wake telemetry | `fleet-telemetry.el` | `fleet-telemetry-tests.el`; quickstart timeline/stats |
| Commander/operator instructions and task-kind briefs | [`prompts/`](../prompts/) | boot construction in `fleet-core.el`; core/native suites |
| Integrated runtime acceptance | `tests/fleet-native-tests.el` | opt-in, paid/live-host boundary in [testing](testing.md) |

`fleet-core.el` implements lifecycle policy but delegates systemd and Git evidence to their owners.
`fleet-rpc.el` translates snake_case tool arguments to Lisp plists and emits deliberately compact views;
not every database field is in `fleet_snapshot`. Some compact projection functions are defined there under
`fleet-core--compact-*` names. Check definitions rather than guessing ownership from a prefix.

## Contracts and documentation ownership

- **Current behavior:** implementation plus regression tests. The design is normative intent/rationale;
  its historical milestones and acceptance requirements are not proof of coverage. Differences belong in
  [known gaps](known-gaps.md), not hidden in session notes.
- **Interface changes:** keep schema descriptions/arguments, `fleet-rpc--validate`/`fleet-rpc--run`, core
  admission and role checks, bridge behavior, doctrine, and regression tests aligned. The current validator
  is not a full JSON Schema implementation. Do not assume adding a schema field wires it into execution.
- **State changes:** add an ordered migration under `schema/`, inspect the store migration path and backup
  behavior, and test old-schema upgrade, too-new refusal, interrupted operations, and projection consumers.
- **ECA changes:** keep all private integration in `fleet-eca.el`. Compare installed frontend source and
  redacted wire fixtures; no version allowlist and no cache-parsing workaround. A dependency probe is not
  native acceptance. Never import the native probe as a harmless discovery step.
- **User behavior:** update quickstart commands/keys/failure meanings. Lifecycle/recovery safety goes in
  recovery; verification scope in testing; runtime doctrine only in prompts. `prompts/stop.md` is currently
  unused by the stop path, not a guaranteed graceful-handoff mechanism.

## Source changes are not live changes

Source-tree installation avoids copying the package; it does **not** eliminate loaded code or cached state.
Do not reload the owner's server as part of a source/documentation check.

| Changed artifact | When it takes effect / trap |
|---|---|
| `lisp/*.el` | Definitions already loaded stay loaded. A newer source file does not replace them. Ignored `.elc` files may be loaded instead of source; `git status` cannot establish their freshness. Use fresh compilation or `load-prefer-newer` in the disposable test server. |
| Structs, advice, callbacks, owner/store/RPC code | Plan a quiescent owner-approved restart or carefully reviewed reload. Existing objects, closures, processes and DB handles survive definition reloads; there is no universal safe hot-reload recipe. |
| `schema/tools-v1.json` | `fleet-rpc-tools` caches it in `fleet-rpc--tools`; another `tools/list` or reloading a `defvar` does not invalidate that cache. Coordinate cache lifecycle with runtime/tool refresh in an approved maintenance session. |
| `schema/*.sql` | Applied by store migration on opening the database, not by commander replacement. Never open the production store just to test a migration. |
| `prompts/*.md`, fleet `about.md`, `commander/context.md` | Boot messages read these at runtime creation; edits do not retroactively change an agent's context. Commander replacement refreshes commander context/doctrine, **not loaded Lisp**, and leaves operators (and lieutenants) running. |
| `~/.config/fleet/config.json` `fleets` section | Applied when a root's commander starts (`fleet-new`, `fleet-commander-replace`): lieutenants are created/updated then, never removed. `models` is read on every task creation. |
| `bridge/fleet_bridge.py` or per-runtime configuration overlay | Existing processes retain their loaded program/environment; changes affect subsequent launches. |

For an authorized commander-context refresh, prefer an idle commander, request a durable handoff, then use
`fleet-commander-replace` and let pending receipts reconcile before assigning new work. Replacing a commander
is not a development test and can incur model cost. Park stops operators, not the commander; watch-stop only
pauses automatic wakes. See [recovery](recovery.md) for the separate ownership/store/RPC shutdown boundaries.

## Runtime and owner data boundaries

Use `fleet-paths.el` root resolution; don't copy defaults into every subsystem. Data (DB, artifact trees,
owner descriptor), runtime (socket/credentials), cache (per-runtime ECA diagnostics), source, Git worktrees,
and owner ECA configuration are distinct. Defaults are described in [recovery](recovery.md); query configured
roots without starting the supervisor before inspecting a host.

Never transplant a private incident transcript or database into a fixture. Reproduce with fakes and minimal
redacted input. Runtime status must be freshly inspected; HEADs, PIDs, live fleet names, model catalogs,
provider limits, hosting login identities and loaded-key state do not belong in durable project instructions.
Authentication failures require checking the authorized account and asking the owner to unlock/load their
credentials, not switching identities or copying secrets. Study is a scope promise, not a filesystem sandbox.
