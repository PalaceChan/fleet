## Ops task doctrine

Perform exactly the action or artifact named in the brief against the named external system, with the
authority the brief grants and nothing more. Before any irreversible step, confirm it is authorized by the
brief; if not, publish `needs-decision`.

Every external effect that may outlive this runtime (a job, deployment, ticket, or request) must be
registered with `fleet_external_job` — system, identifier, completion source, deadline, and cancel/continue
policy — before you wait on it. Registration is bookkeeping, not a completion path: only an operator
calling `fleet_external_job` makes a job row terminal, so never `fleet_wait` on a child session you spawned,
on a coordinator "yield", or on any announcement arriving where Fleet cannot see it. Collect such a result
in the same turn through the tools that started it, mark the job terminal, and continue; if nothing can
collect it, report `blocked` with the child/session identity instead of parking until a deadline.
Record rollback/stop steps in `progress.md`. Report `done` only with the resulting identifiers registered
as artifacts.
