# Recovery

[Inspect first](#passive-inspection-without-starting-fleet) · [Restart](#emacs-crashed-or-was-killed) ·
[Delivery](#delivery-unknown-and-held-messages) · [Backup / restore](#backup-and-restore) · [Testing](testing.md)

Fleet's recovery records are the SQLite database (typed tables plus `events` and `operations`) and
per-fleet artifact trees. Git repositories/worktrees, retention refs and external jobs have their own
state; ECA conversation history is a convenience, not the recovery contract. This is an operational guide,
not a replacement for the [design](design.md) or a claim that every intended invariant is implemented.

## Passive inspection without starting Fleet

Resolve paths through [fleet-paths.el](../lisp/fleet-paths.el), not a hard-coded default. Custom
`fleet-data-root`, `fleet-runtime-root` and other root variables override XDG-derived locations. The usual
data default is `~/.local/share/fleet`, but that may not be the affected owner's root.

In an **existing named Emacs server configured for the affected root**, this expression only loads the
path module and resolves locations; it does not acquire ownership, open/migrate SQLite or start Fleet.
This is a read-only diagnostic, not permission to run tests in the editing server:

```bash
: "${OWNER_SOCKET:?Set OWNER_SOCKET to the confirmed existing server for the affected root}"
emacsclient --alternate-editor=false --socket-name="$OWNER_SOCKET" --eval '
(progn
  (require (quote fleet-paths))
  (list :data (fleet-paths-data-root)
        :database (fleet-paths-db-file)
        :artifacts (fleet-paths-fleets-root)
        :owner (fleet-paths-owner-descriptor)
        :runtime (fleet-paths-runtime-root)
        :socket (fleet-paths-socket)
        :worktrees (fleet-paths-worktree-root)))'
```

The module must already be available on that server's `load-path`. An unset/unsafe runtime root can
signal an error; do not invent a fallback or create a new server. If the owner crashed, recover its root
configuration from the owner-approved configuration/evidence; another Emacs's defaults are not proof.

For database inspection, set `DB` to the resolved **existing** database path. These Bash/SQLite CLI
examples do not use Fleet startup or its store API. Read-only SQLite may still interact with WAL shared
memory/locking; these are nonmutating SQL queries, not a bit-for-bit forensic snapshot:

```bash
: "${DB:?Set DB to the resolved existing fleet.sqlite3 path}"
test -f "$DB" && sqlite3 -readonly -header -column "$DB" <<'SQL'
PRAGMA query_only = ON;
BEGIN;
SELECT key, value FROM meta
 WHERE key IN ('schema_version', 'snapshot_revision');
SELECT id, name, lifecycle, supervision, commander_runtime_id, artifact_root
 FROM fleets ORDER BY name;
SELECT id, fleet_id, name, lifecycle, phase, current_runtime_id, brief_revision
 FROM tasks WHERE lifecycle <> 'archived' ORDER BY fleet_id, name;
SELECT id, role, fleet_id, task_id, lifecycle, unit, control_group, boot_id,
       invocation_id, owner_epoch, stop_evidence
 FROM runtimes WHERE lifecycle NOT IN ('stopped', 'never-launched');
SELECT id, kind, fleet_id, task_id, runtime_id, state, step, error, updated_at
 FROM operations WHERE state IN ('running', 'blocked', 'failed') ORDER BY updated_at;
SELECT id, fleet_id, task_id, target_runtime_id, origin, state, evidence
 FROM messages WHERE state IN
 ('held', 'queued', 'dispatching', 'accepted', 'turn-observed', 'delivery-unknown');
SELECT id, event_id, fleet_id, runtime_id, batch_id, state, outcome
 FROM event_receipts WHERE state <> 'acknowledged';
SELECT id, fleet_id, runtime_id, message_id, state FROM wake_batches
 WHERE state NOT IN ('finished', 'released');
SELECT seq, kind, fleet_id, task_id, runtime_id, operation_id, created_at
 FROM events ORDER BY seq DESC LIMIT 30;
COMMIT;
SQL
```

Columns/states come from [001.sql](../schema/001.sql); model variant additions are in
[002.sql](../schema/002.sql). These examples omit message bodies and credentials; evidence may
still be sensitive. Keep inspection local. Do not use `immutable=1` to bypass a live database's WAL, and
do not remove WAL/SHM files to make a read succeed. If inspection fails, preserve the evidence and ask
for maintenance rather than migrating or creating a database just to inspect it.

**`M-x fleet-dashboard` is stateful startup, not passive inspection.**
[fleet-dashboard-ensure-started](../lisp/fleet.el) calls
[fleet-supervisor-start](../lisp/fleet-supervisor.el): acquisition can publish ownership, open/migrate the
store, start timers and reconcile runtimes; the public startup path then starts the RPC socket for an
owner. A second Emacs may enter read-only mode, but requesting a dashboard is still an acquisition
attempt. Do not call `fleet-supervisor-store` for passive inspection: it only returns an already-open
store or signals `not-started`; following its suggestion to open the dashboard activates the path above.
Even `fleet-store-open` with its read-only flag is not the passive CLI path: it ensures the parent,
opens SQLite and runs schema checks through [fleet-store--migrate](../lisp/fleet-store.el).

## Emacs crashed or was killed

1. Inspect the root, `owner.json`, runtime rows and running operations first. An unreleased descriptor
   naming another live Emacs on the same boot with matching kernel start ticks normally refuses takeover;
   act in that Emacs. Acquisition uses a kernel `flock` helper to serialize owners. Do not delete the lock
   or descriptor to bypass ownership.
2. With owner approval to acquire/reconcile, run `M-x fleet-dashboard`. For nonterminal runtime rows,
   [fleet-core-reconcile-runtimes](../lisp/fleet-core.el) requests stops against their recorded exact units,
   records outcomes and marks affected active tasks `suspended`. Suspension is not itself stop proof.
3. Review the resulting runtime **and operation** evidence before further work. Startup reconciliation
   does not automatically restart operators. `M-x fleet-new` on an existing fleet offers resume when
   parked, or an explicit commander start when active without a live commander. Resume marks the fleet
   active; unfinished operators start only on request. Review pending work before approving model turns.

When reached, [fleet-core-resume-operations](../lisp/fleet-core.el) handles `brief-publish` by hash evidence,
`fleet-retire` at the `renaming` step, interrupted starts/stops by failure, `fleet-park` by continuation,
and interrupted `task-teardown` in `closing` by refusal so it can be rerun. **Actual gaps:** an empty
nonterminal runtime set returns before calling `fleet-core-resume-operations`, and `task-retask` has no
handler there. Do not assume all journal entries resolved because startup returned. See
[recovery and delivery gaps](known-gaps.md#recovery-and-delivery).

**Source-review gap, not a demonstrated fail-closed guarantee:**
[fleet-supervisor-acquire](../lisp/fleet-supervisor.el) parses the previous descriptor under `ignore-errors`;
malformed owner JSON can be treated as no descriptor, rather than an explicit corrupt-owner refusal.
The live-descriptor guard and `flock` do not establish the stronger design aspiration for corrupt owner
metadata. Preserve a corrupt descriptor and require investigation; do not “repair” it by guessing.
See [fail-closed evidence](known-gaps.md#fail-closed-evidence).

## A service will not stop (`stop-unknown`, fleet stays `parking`)

In an already-started owner, `M-x fleet-doctor` reports nonterminal runtimes with asynchronous systemd and
cgroup inspection. It is not purely an offline file viewer: [fleet-doctor](../lisp/fleet.el) also invokes
compatibility/version checks, and its store section exists only when a store is already open. Use the
passive queries above if startup or native diagnostics are not authorized.

Inspect the **exact `runtimes.unit`** with `systemctl --user status` and `journalctl --user -u`; do not
infer an identity from a task name or use wildcard stops. A failed systemd query yields `stop-unknown` in
[fleet-runtime-verdict](../lisp/fleet-runtime.el); fix the manager and re-evaluate evidence rather than
forcing replacement/teardown. Cancellation, a missing chat buffer, or a successful stop request is not
proof of execution death. There is no routine force/discard flag.

**Source-review gap:** [fleet-runtime-cgroup-populated](../lisp/fleet-runtime.el) returns `absent` for both
missing/empty cgroup identity and an unreadable `cgroup.events` file. `fleet-runtime-verdict` accepts
`absent` alongside an empty cgroup under its settled/inactive-or-not-found conditions. Thus “all missing
or unreadable cgroup evidence fails closed” is a design aspiration, not current proven behavior. Treat
ambiguous evidence as an investigation blocker, not certification that no process survives; see
[fail-closed evidence](known-gaps.md#fail-closed-evidence).

## Lease helper died while Emacs lived

[fleet-supervisor--fence](../lisp/fleet-supervisor.el) fences subsequent admissions when the helper dies;
services can remain under systemd. Park may be refused in that fenced owner. The recovery entry points
are `fleet-supervisor-stop` and later approved dashboard acquisition in that same Emacs, whose PID is
excluded by `fleet-supervisor--previous-owner-alive-p`. This is **not** a generic shutdown/restart sequence:
`fleet-supervisor-stop` neither stops services nor releases a live lease nor stops RPC. Inspect lease,
socket, callbacks and runtimes first; review the shutdown distinctions below with the owner.

## Delivery unknown and held messages

A `dispatching` message without acceptance or running evidence within the watchdog bound becomes
`delivery-unknown`. The lane stays blocked and associated wake claims can become `held-unknown`.
Inspect the chat with `RET` and the message/receipt evidence; do not blindly resend or equate reading
with acknowledgment. The empty-turn retry path is distinct from unknown delivery and is not proof that
a missing response had no side effects; see [native acceptance limits](testing.md#native-acceptance-and-historical-evidence).

For the commander lane, owner-approved `fleet-commander-replace` stops the predecessor and prepares a
fresh commander with handoff context. [fleet-supervisor-on-commander-replaced](../lisp/fleet-supervisor.el)
moves that predecessor's claimed/held-unknown receipts to `needs-reconciliation` and cancels its queued
messages. This does not assert that earlier actions were undone or replay is safe.

For operators, park/resume retains work but is **not a complete delivery-reconciliation mechanism**.
[fleet-core-park-fleet](../lisp/fleet-core.el) holds queued operator messages;
`fleet-core-resume-fleet` changes held messages back to queued without changing `target_runtime_id`.
They still target the old runtime, and [fleet-supervisor--target-current-p](../lisp/fleet-supervisor.el)
requires the current runtime/brief. Do not assume a replacement receives them, or manually rewrite their
targets/states as routine recovery. Escalate unresolved intent with its evidence; see
[recovery and delivery](known-gaps.md#recovery-and-delivery).

## Teardown refused

Keep the printed paths, OIDs and refusal evidence. Causes include dirty/untracked/ignored content,
unverified deliverables, an unmet delivery contract, HEAD/branch mismatch or a tip without a surviving
ref, and — for a lieutenant's task while a request to it is open — `report-pending`: the verified result
has not been named in a `fleet_report` (`task_ids`; [lieutenants §4](lieutenants.md#4-delegation-protocol)).
Fix the specific cause (preserve/commit, push, verify, report, or explicitly retask), then rerun dashboard
`t`. See [fleet-core-teardown-task](../lisp/fleet-core.el) and the evidence/authorization code in
[fleet-git.el](../lisp/fleet-git.el). Never discard by inference; deliberate disposal is a separate human
decision outside normal teardown, not a recommended refusal workaround. Native dirty-refusal acceptance
remains [unverified](testing.md#native-acceptance-and-historical-evidence).

## Backup and restore

**No routine state surgery:** do not edit SQLite lifecycle/message/receipt/operation rows, delete
ownership files, substitute stop evidence, or copy old artifacts over a live fleet to clear a refusal.
Restore is owner-approved maintenance, not a diagnostic probe. **Never test a restore on live state.**

[fleet-store-backup](../lisp/fleet-store.el) uses `VACUUM INTO` for a consistent database-only online copy
that includes committed state visible through SQLite's WAL. **It unlinks an existing destination before
copying. Use a fresh, non-existing destination in a protected backup directory; never a previous backup
or the source database path.** Pre-migration backups are likewise database-only, and are made when
upgrading an existing nonzero schema by `fleet-store--migrate`.

A DB backup and a separately copied `fleets/` tree are **not an atomic combined snapshot**. A restorable
maintenance set requires an owner-reviewed plan to quiesce **all fleets, operators and commanders** using
the affected roots, plus external artifact writers/jobs and pending operations/asynchronous callbacks.
Account for each fleet's recorded `artifact_root` (including archives), repositories/worktrees and local
`refs/fleet/retained/<task>` refs; those refs are not off-machine backups. Record the root mapping and
snapshot revision with the backup, without exposing credentials.

Do not collapse these distinct operations into an unsafe generic sequence:

| Symbol | Actual scope |
|---|---|
| [fleet-core-park-fleet](../lisp/fleet-core.el) | Stops that fleet's operators; retains its commander and external jobs. Completion is asynchronous. |
| [fleet-core-stop-commander](../lisp/fleet-core.el) | Stops that fleet's commander; leaves operators alone. |
| [fleet-supervisor-release](../lisp/fleet-supervisor.el) | While owner, refuses nonterminal runtime rows; otherwise marks released and drops the lease. Does not close the store/timers or stop RPC. |
| [fleet-supervisor-stop](../lisp/fleet-supervisor.el) | Closes this Emacs's store and supervisor timers/hooks; does not stop runtimes, release the lease or stop RPC. |
| [fleet-rpc-stop](../lisp/fleet-rpc.el) | Stops the listening socket server and removes the socket path; not a runtime stop, lease release or blanket proof all accepted connections/callbacks are gone. |

Verify these source implementations and every affected runtime/operation before maintenance. Releasing
ownership too early permits another acquirer; closing a store while work is pending can leave callbacks
against a closed handle. There is no universal safe paste-and-run order documented here.

For restore, approve the exact source backup, fresh preservation copy of the current state, destinations
and compatible Fleet schema/code first. Establish quiescence and **no open database handles** in owners,
readers or inspection tools, plus no remaining writers/callbacks, before replacing anything. SQLite WAL
awareness is essential: a raw copy of only `fleet.sqlite3` can omit committed WAL data. Use a consistent
SQLite backup, or a coordinated closed-state capture accounting for WAL/SHM; never blindly remove live
sidecars or mix old sidecars with a restored DB. Restore the matching database and artifacts only under
the approved plan. Validation/rehearsal belongs in separate disposable roots with no production writers;
subsequent dashboard startup is an explicit stateful acquisition/migration/reconciliation decision, not
a passive check of the restored files.

## ECA upgrade removed something Fleet uses

`M-x fleet-doctor` names missing symbols on its `ECA` line; version numbers alone do not certify or reject
compatibility. See [ECA compatibility](eca-compatibility.md),
[authority and interface](known-gaps.md#authority-and-interface), and
[verification and diagnostics](known-gaps.md#verification-and-diagnostics). Passive SQLite/file inspection
is available without starting Fleet. Stopping an exact unit is an owner-approved action and still needs
observed evidence; neither compatibility diagnostics nor these recovery notes certify native behavior.
