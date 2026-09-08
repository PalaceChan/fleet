# AGENTS.md — contributor instructions for Fleet

These are instructions for people and agents *working on Fleet itself*. Runtime commander/operator doctrine
lives in `prompts/` and is deliberately separate.

**Fleet's scope:** Single-host, ECA-native orchestration in Emacs with local, unsandboxed execution.

**Architecture:** Emacs is the sole state writer and scheduler. `fleet-store.el` owns transactional facts and
projections; `fleet-eca.el` alone knows ECA internals; `fleet-runtime.el` alone owns service lifetime;
`fleet-git.el` alone authorizes workspace cleanup. The dashboard and Python bridge call these owners rather
than duplicating policy.

**Safety invariants:** Never infer execution death from a missing chat buffer, model completion from an idle
spinner, successful delivery from a write to a pipe, or preservation from a status string. Never respawn until
the predecessor's owned local execution is proven stopped. Never remove an adopted worktree or adopted branch.
Never delete uncommitted work through normal teardown. Never merge or discard by inference.

**Durability:** Events are durable before delivery is attempted. Reading is not acknowledgment. Mutation
requests have idempotency keys. Long operations persist intent and advance through retryable steps; no database
transaction spans a subprocess or network wait. Unknown results remain unknown and are not retried blindly.

**Concurrency:** Exactly one supervisor owns a state root. Normal Emacs daemons are supported. Every
asynchronous callback carries owner, fleet, task, runtime, and operation identity as applicable. State
callbacks cannot mutate a replacement. UI actions and agent tools use the same admission checks.

**Emacs:** Use `emacsclient` for development operations against an existing server; never run tests or exit
functions in the user's working Emacs. A dedicated test server is allowed and required for integration tests
(`make test` starts one). Keep process filters, timers, and interactive callbacks short; all Git, systemd, and
RPC waits are asynchronous.

**ECA:** Verify the installed frontend/server pair before coding against it. Keep private API assumptions
listed in `docs/eca-compatibility.md` and covered by recorded/fake-server tests. Do not read undocumented ECA
caches. Do not change ordinary non-Fleet ECA sessions or globally enable trust. The verified pair for this
repository is eca-emacs `20260529.1500` (rev `f700be30f1e5`) with server `eca 0.158.1`; the compatibility
profile in `fleet-eca.el` refuses autonomous dispatch on an unverified pair.

**Code quality:** Prefer deleting special cases to adding knobs. Comments explain constraints, not code history
or the next line. Use lexical binding, explicit identities, structured errors (`fleet-error` with a stable
code), argument vectors rather than shell command strings, and display-width-aware formatting. No generated
state, credentials, or transcripts in Git.

**Verification:** Add regression tests at the owning layer for every bug. Run ERT and Python tests using an
isolated temporary data/runtime/worktree root (`fleet-test-with-roots`); real model/provider calls are opt-in
(`FLEET_TEST_NATIVE=1`). Test crash boundaries and refusal paths, not only success. Verify dashboard keymaps in
a live test buffer after reload. Never operate on real user fleets as a test fixture.

**Docs:** Keep `quickstart.md` accurate for user-facing commands, keys, failure meanings, and restart/park
workflows. `prompts/` is the single canonical source of agent doctrine. Do not duplicate the same doctrine in
generated skills and several unrelated files. `docs/design.md` is the maintained design; update it when
behavior deliberately diverges from it and say why.
