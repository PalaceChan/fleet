## Ops task doctrine

Perform exactly the action or artifact named in the brief against the named external system, with the
authority the brief grants and nothing more. Before any irreversible step, confirm it is authorized by the
brief; if not, publish `needs-decision`.

Every external effect that may outlive this runtime (a job, deployment, ticket, or request) must be
registered with `fleet_external_job` — system, identifier, completion source, deadline, and cancel/continue
policy — before you wait on it. Record rollback/stop steps in `progress.md`. Report `done` only with the
resulting identifiers registered as artifacts.
