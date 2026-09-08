# Recovery

Everything Fleet knows is in `~/.local/share/fleet/fleet.sqlite3` (typed tables plus the `events` and
`operations` journals) and the per-fleet artifact trees next to it. ECA conversation history is a
convenience, never the recovery contract.

## Emacs crashed or was killed

1. `M-x fleet-dashboard`. Acquisition checks `owner.json`: if the recorded Emacs pid is alive on this boot
   with the same kernel start time and did not release, Fleet refuses to take over (act in that Emacs). A
   dead pid or a released descriptor permits takeover; the kernel `flock` serializes competing reclaimers.
2. `fleet-core-reconcile-runtimes` runs before anything else: every runtime not proven stopped is stopped
   through its exact unit, evidence is recorded, affected active tasks become `suspended`, and interrupted
   operations are resolved from their journal (`brief-publish` commits or fails by file hash; `fleet-retire`
   finishes a rename that happened before the DB commit; `task-start`/`commander-start`/`runtime-stop` are
   marked failed; `fleet-park` continues; `task-teardown` is refused so you rerun it).
3. Nothing restarts automatically. `M-x fleet-new` → the fleet → *resume*.

## A service will not stop (`stop-unknown`, fleet stays `parking`)

`fleet-doctor` lists nonterminal runtimes with `systemctl show` and cgroup evidence. Inspect with
`systemctl --user status fleet-eca-<uuid>.service` and `journalctl --user -u fleet-eca-<uuid>.service`.
If systemd itself is unreachable (query failure) the verdict is *unknown*, not *stopped* — fix the manager
first. Fleet never replaces or tears down anything while a predecessor is unknown; there is no force flag.

## Lease helper died while Emacs lived

All admissions are fenced immediately ("ownership fenced" on the dashboard). Runtimes keep running under
systemd. Park is impossible in that Emacs; restart Fleet there (`fleet-supervisor-stop`, then
`fleet-dashboard`) — takeover succeeds because the descriptor names the same pid.

## Delivery unknown

A message (human, commander, wake) reached `dispatching` and neither the `prompting` response nor a
`running` status arrived within the bound. Fleet freezes that chat's lane, holds the wake batch's claims as
`held-unknown`, and shows attention. Look at the chat (`RET`). If the model clearly never saw the text,
`fleet-commander-replace` (commander lane) or park + resume (operator lane) reconciles: unresolved claims
become `needs-reconciliation` and appear in the next commander's pending list with a marker. Fleet never
resends the text itself.

## Teardown refused

The refusal names the reason from a single evidence pass: dirty/untracked/ignored content, unverified
deliverable, unsatisfied delivery contract, HEAD/branch mismatch, or a tip without a surviving ref. Fix the
cause (commit, push, verify, or have the commander retask) and rerun `t`. To discard work deliberately, do
it yourself in the worktree with full knowledge of the paths and OIDs the refusal printed, then rerun
teardown; Fleet has no discard mode.

## Backup and restore

While Fleet is running, `(fleet-store-backup (fleet-supervisor-store) "/path/backup.sqlite3")` performs a
consistent `VACUUM INTO` copy (WAL-safe). Copy the `fleets/` tree together with it and note the snapshot
revision. Migrations take a pre-migration backup next to the database automatically. To restore: stop all
runtimes (park, then `fleet-commander-stop`), release ownership, replace `fleet.sqlite3` and `fleets/`, then
`fleet-dashboard`. Git worktrees are the repositories' own responsibility; retention refs
(`refs/fleet/retained/<task>`) are local, not off-machine backups.

## Unsupported ECA pair after an upgrade

`fleet-doctor` names the mismatch. Read-only inspection, artifact viewing and `systemctl --user stop` of
Fleet units all work. Follow `docs/eca-compatibility.md` to re-verify.
