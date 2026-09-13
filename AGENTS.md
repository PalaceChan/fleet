# AGENTS.md — working on Fleet

Read this file first; follow the task links below rather than loading every document. These instructions
are for contributors. `prompts/` contains **runtime payloads** for commanders/operators, not contributor
instructions. Fleet is single-host, ECA-native orchestration in Emacs with local, unsandboxed execution.

## Workflow and authority

- Keep the primary clone on clean `master`. Prefer a short-lived worktree for concurrent or substantial
  work: `~/development/.worktrees/fleet--<context>`. Check status and existing worktrees first; never
  branch from a dirty tree or touch another task's worktree. Remove your worktree once merged or abandoned.
- A review is read-only unless changes are requested. Source work does not authorize live fleet operations,
  installation/reload, owner configuration changes, credential access, or external actions. Confirm scope
  before paid/native probes. Merge, push, and activation are separate steps, never concurrent shortcuts;
  follow the owner's authorization for each.
- Use **`emacsclient` only** for Emacs operations. Never run tests, unload Fleet, or exit functions in the
  owner's editing server. ERT needs an already-running, explicitly identified disposable test server; if
  none is available, report the skipped check. Current Make targets launch/exit Emacs and are not suitable
  under this rule; see [testing](docs/testing.md). Never kill servers by a broad process-name pattern.
- Owner trust/model choices belong in owner configuration, not product defaults. Never globally enable
  trust or change ordinary non-Fleet ECA sessions. Never use real user fleets as test fixtures.
- Keep credentials, private reports, transcripts, database copies, and session checkpoints out of Git.
  Engineering knowledge belongs here; history belongs in Git; private owner follow-ups stay with the owner.
  Runtime handoff belongs in `commander/context.md`, never the owner's Org checkpoint.

## Non-negotiable design constraints

These are constraints to preserve, **not a certification that every path implements them**. Consult
[known gaps](docs/known-gaps.md) before relying on recovery, authority, or unattended execution.

- **Owners:** Emacs alone writes state and schedules. `fleet-store.el` owns transactional facts/projections;
  `fleet-eca.el` alone knows ECA internals; `fleet-runtime.el` owns service lifetime; `fleet-git.el` authorizes
  workspace cleanup. Dashboard and bridge call the owners rather than copying their policy.
- **Evidence:** A missing buffer is not execution death; an idle spinner is not completion; a pipe write is
  not delivery; a status string is not preservation. Never respawn without predecessor stop proof. Never
  remove adopted worktrees/branches, delete uncommitted work through normal teardown, or infer merge/discard
  authority. Human task close and empty-fleet retirement remain distinct, explicit operations.
- **Durability:** Persist events before delivery; reading is not acknowledgment. Key mutations for
  idempotency; preserve intent across retryable long operations. No transaction spans a subprocess/network
  wait. Unknown results stay unknown, not blindly retried. Existing status/wait exceptions are documented.
- **Concurrency:** One supervisor per state root, including ordinary Emacs daemons. Async callbacks carry
  owner/fleet/task/runtime/operation identities as applicable and cannot mutate replacements. UI and tools
  share admission checks. Keep filters/timers short; prefer async waits (the current RPC evidence wait is a
  tracked exception, not a pattern to copy).
- **ECA:** Record private assumptions and redacted wire evidence in
  [integration notes](docs/eca-compatibility.md). Add private symbols to
  `fleet-eca-required-functions`/`-variables` and regression tests. Do not pin/gate ECA version numbers or
  read undocumented ECA caches as a recovery/API contract.
- **Code:** Lexical binding, explicit identities, stable `fleet-error` codes, argv rather than shell strings,
  display-width-aware UI. Prefer deleting special cases to adding knobs. Comments explain constraints.

## Read next by task

| Work | Start here |
|---|---|
| First contribution, module/test ownership, change impact | [Development](docs/development.md) |
| Install, commands, keys, normal park/resume | [Quickstart](quickstart.md) |
| State inspection, delivery/stop trouble, backup/restore | [Recovery](docs/recovery.md) |
| Bug selection, implementation limitations, deferred work | [Known gaps](docs/known-gaps.md) |
| Verification commands and native acceptance boundaries | [Testing](docs/testing.md) |
| ECA protocol/frontend drift | [Integration notes](docs/eca-compatibility.md) |
| Architecture, invariants, rationale | [Design](docs/design.md) — reference, not a greenfield task list |
| Runtime doctrine or MCP interface | [Prompts](prompts/), [tool schema](schema/tools-v1.json), [bridge](bridge/README.md) |

## Finish a change

Add regression tests at the owning layer, including refusal/crash boundaries. Use isolated roots and report
exact checks, skips, and unresolved risks; a Make exit status alone is not ERT evidence. Verify dashboard
keys in a disposable live test buffer when changing UI behavior. Update the relevant guide/schema/doctrine
with behavior changes; do not append landing narratives or duplicate runtime doctrine in generated skills.
Source/tests establish implemented behavior; design expresses intent; neither overrides authorization or
safety constraints. When they disagree, fix or record the discrepancy in `docs/known-gaps.md` rather than
silently treating the design as implemented. Keep this root entry small; add local instructions only for a
real subtree-specific rule, not to duplicate this file.
