-- Fleet schema v1.  Applied by fleet-store.el inside one transaction.
-- Typed tables are authoritative current facts; `events` is an audit/delivery log.
-- Booleans are INTEGER 0/1; timestamps are UTC ISO-8601 text; JSON columns hold serialized plists.

CREATE TABLE meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE fleets (
  id                   TEXT PRIMARY KEY,
  name                 TEXT NOT NULL,
  lifecycle            TEXT NOT NULL CHECK (lifecycle IN ('active','parking','parked','retiring','archived')),
  supervision          INTEGER NOT NULL DEFAULT 1,
  artifact_root        TEXT NOT NULL,          -- absolute; managed paths are relative to this
  context_path         TEXT,                   -- relative: commander/context.md
  commander_model      TEXT,
  commander_agent      TEXT,
  commander_runtime_id TEXT,
  entity_revision      INTEGER NOT NULL DEFAULT 1,
  created_at           TEXT NOT NULL,
  updated_at           TEXT NOT NULL
);
CREATE UNIQUE INDEX fleets_active_name ON fleets (name) WHERE lifecycle <> 'archived';

CREATE TABLE tasks (
  id                   TEXT PRIMARY KEY,
  fleet_id             TEXT NOT NULL REFERENCES fleets (id),
  name                 TEXT NOT NULL,
  kind                 TEXT NOT NULL CHECK (kind IN ('change','study','ops')),
  lifecycle            TEXT NOT NULL CHECK (lifecycle IN ('draft','ready','active','suspended','closing','archived')),
  phase                TEXT CHECK (phase IS NULL OR phase IN ('working','needs-decision','blocked','paused','done','failed')),
  detail               TEXT,
  detail_at            TEXT,
  brief_revision       INTEGER NOT NULL DEFAULT 0,
  brief_hash           TEXT,
  brief_path           TEXT,                   -- relative immutable revision path
  repo_path            TEXT,                   -- canonical primary clone (change) or read context
  repo_common_dir      TEXT,
  workspace_path       TEXT,                   -- canonical worktree or task-local dir
  workspace_ownership  TEXT CHECK (workspace_ownership IS NULL OR workspace_ownership IN ('fleet','adopted')),
  branch               TEXT,
  branch_ownership     TEXT CHECK (branch_ownership IS NULL OR branch_ownership IN ('fleet','adopted')),
  base_ref             TEXT,
  base_oid             TEXT,
  remote               TEXT,
  target_ref           TEXT,
  delivery_mode        TEXT CHECK (delivery_mode IS NULL OR delivery_mode IN ('remote-review','local-ready','integrated')),
  current_runtime_id   TEXT,
  wait_reason          TEXT,
  wait_deadline        TEXT,
  wait_job_id          TEXT,
  model                TEXT,
  entity_revision      INTEGER NOT NULL DEFAULT 1,
  created_at           TEXT NOT NULL,
  updated_at           TEXT NOT NULL
);
CREATE UNIQUE INDEX tasks_active_name ON tasks (fleet_id, name) WHERE lifecycle <> 'archived';
CREATE INDEX tasks_fleet ON tasks (fleet_id);

CREATE TABLE task_dependencies (
  task_id            TEXT NOT NULL REFERENCES tasks (id),
  depends_on_id      TEXT NOT NULL REFERENCES tasks (id),
  satisfied_revision INTEGER,                  -- brief revision of the prerequisite that satisfied it
  PRIMARY KEY (task_id, depends_on_id)
);

CREATE TABLE runtimes (
  id                    TEXT PRIMARY KEY,
  owner_epoch           TEXT NOT NULL,
  role                  TEXT NOT NULL CHECK (role IN ('commander','operator')),
  fleet_id              TEXT NOT NULL REFERENCES fleets (id),
  task_id               TEXT REFERENCES tasks (id),
  unit                  TEXT NOT NULL,
  invocation_id         TEXT,
  control_group         TEXT,
  boot_id               TEXT,
  main_pid              INTEGER,
  chat_id               TEXT,
  model                 TEXT,
  agent                 TEXT,
  variant               TEXT,
  lifecycle             TEXT NOT NULL CHECK (lifecycle IN ('launching','starting','ready','stopping','stopped','stop-unknown','never-launched','lost')),
  credential_hash       TEXT,
  credential_revoked    INTEGER NOT NULL DEFAULT 0,
  launch_evidence       TEXT,
  stop_evidence         TEXT,
  connection_state      TEXT,                  -- connecting / ready / lost
  turn_state            TEXT,                  -- idle / running / stopping
  pending_question      TEXT,                  -- JSON
  pending_approvals     TEXT,                  -- JSON array of tool call ids
  active_tool           TEXT,                  -- JSON {id,name,since}
  last_activity_at      TEXT,
  observation_revision  INTEGER NOT NULL DEFAULT 0,
  created_at            TEXT NOT NULL,
  updated_at            TEXT NOT NULL
);
CREATE INDEX runtimes_fleet ON runtimes (fleet_id);
CREATE INDEX runtimes_task ON runtimes (task_id);

CREATE TABLE events (
  seq          INTEGER PRIMARY KEY AUTOINCREMENT,
  id           TEXT NOT NULL UNIQUE,
  fleet_id     TEXT REFERENCES fleets (id),
  task_id      TEXT,
  runtime_id   TEXT,
  kind         TEXT NOT NULL,
  payload      TEXT,
  source       TEXT,
  actor        TEXT,
  operation_id TEXT,
  actionable   INTEGER NOT NULL DEFAULT 0,
  created_at   TEXT NOT NULL
);
CREATE INDEX events_fleet_seq ON events (fleet_id, seq);

CREATE TABLE event_receipts (
  id          TEXT PRIMARY KEY,
  event_id    TEXT NOT NULL REFERENCES events (id),
  fleet_id    TEXT NOT NULL,
  consumer    TEXT NOT NULL DEFAULT 'commander',
  state       TEXT NOT NULL CHECK (state IN ('pending','claimed','acknowledged','held-unknown','needs-reconciliation')),
  batch_id    TEXT,
  runtime_id  TEXT,
  outcome     TEXT,
  acked_at    TEXT,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
);
CREATE UNIQUE INDEX receipts_event_consumer ON event_receipts (event_id, consumer);
CREATE INDEX receipts_fleet_state ON event_receipts (fleet_id, state);

CREATE TABLE messages (
  id                TEXT PRIMARY KEY,
  idempotency_key   TEXT,
  sender            TEXT NOT NULL,             -- logical actor
  fleet_id          TEXT NOT NULL,
  task_id           TEXT,
  target_runtime_id TEXT,
  origin            TEXT NOT NULL CHECK (origin IN ('human','commander','wake','boot','reminder','system')),
  text              TEXT,
  body_path         TEXT,
  body_hash         TEXT,
  state             TEXT NOT NULL CHECK (state IN ('queued','held','dispatching','accepted','turn-observed','finished','rejected','delivery-unknown','cancelled-before-dispatch')),
  request_id        INTEGER,                   -- chat-local request-id sent on the wire
  brief_revision    INTEGER,
  evidence          TEXT,
  created_at        TEXT NOT NULL,
  updated_at        TEXT NOT NULL
);
CREATE UNIQUE INDEX messages_idem ON messages (sender, idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE INDEX messages_target_state ON messages (target_runtime_id, state);

CREATE TABLE operations (
  id                TEXT PRIMARY KEY,
  kind              TEXT NOT NULL,
  fleet_id          TEXT,
  task_id           TEXT,
  runtime_id        TEXT,
  expected_revision INTEGER,
  step              TEXT NOT NULL,
  state             TEXT NOT NULL CHECK (state IN ('running','done','failed','blocked')),
  intent            TEXT,
  evidence          TEXT,
  error             TEXT,
  owner_epoch       TEXT,
  created_at        TEXT NOT NULL,
  updated_at        TEXT NOT NULL
);
CREATE INDEX operations_task_state ON operations (task_id, state);
CREATE INDEX operations_fleet_state ON operations (fleet_id, state);

CREATE TABLE artifacts (
  id                      TEXT PRIMARY KEY,
  task_id                 TEXT NOT NULL REFERENCES tasks (id),
  kind                    TEXT NOT NULL,
  rel_path                TEXT,
  external_ref            TEXT,
  description             TEXT,
  expected_identity       TEXT,
  verified                INTEGER NOT NULL DEFAULT 0,
  verified_brief_revision INTEGER,
  verified_hash           TEXT,
  verified_by             TEXT,
  verification_evidence   TEXT,
  created_at              TEXT NOT NULL,
  updated_at              TEXT NOT NULL
);

CREATE TABLE wake_batches (
  id            TEXT PRIMARY KEY,
  fleet_id      TEXT NOT NULL,
  message_id    TEXT,
  runtime_id    TEXT,
  reminder_used INTEGER NOT NULL DEFAULT 0,
  state         TEXT NOT NULL CHECK (state IN ('queued','delivered','finished','released','needs-reconciliation','held')),
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL
);

CREATE TABLE actions (
  actor          TEXT NOT NULL,                -- logical actor, survives runtime replacement
  action_id      TEXT NOT NULL,
  payload_digest TEXT NOT NULL,
  operation_id   TEXT,
  event_id       TEXT,
  batch_id       TEXT,
  result         TEXT,
  created_at     TEXT NOT NULL,
  PRIMARY KEY (actor, action_id)
);

CREATE TABLE decisions (
  id               TEXT PRIMARY KEY,
  fleet_id         TEXT NOT NULL,
  task_id          TEXT NOT NULL REFERENCES tasks (id),
  brief_revision   INTEGER,
  question         TEXT NOT NULL,
  options          TEXT,
  recommendation   TEXT,
  authority        TEXT NOT NULL CHECK (authority IN ('commander','human')),
  state            TEXT NOT NULL CHECK (state IN ('open','resolved','cancelled')),
  answer           TEXT,
  resolved_by      TEXT,
  evidence         TEXT,
  reply_message_id TEXT,
  created_at       TEXT NOT NULL,
  updated_at       TEXT NOT NULL
);

CREATE TABLE external_jobs (
  id                TEXT PRIMARY KEY,
  fleet_id          TEXT NOT NULL,
  task_id           TEXT NOT NULL REFERENCES tasks (id),
  runtime_id        TEXT,
  system            TEXT NOT NULL,
  job_ref           TEXT NOT NULL,
  state             TEXT NOT NULL CHECK (state IN ('running','completed','failed','cancelled','unknown')),
  completion_source TEXT,
  deadline          TEXT,
  cancel_policy     TEXT,
  disposition       TEXT,
  created_at        TEXT NOT NULL,
  updated_at        TEXT NOT NULL
);

CREATE TABLE resource_claims (
  id           TEXT PRIMARY KEY,
  fleet_id     TEXT NOT NULL,
  kind         TEXT NOT NULL CHECK (kind IN ('workspace','resource')),
  key          TEXT NOT NULL UNIQUE,           -- canonical workspace path or named resource
  task_id      TEXT NOT NULL REFERENCES tasks (id),
  operation_id TEXT,
  created_at   TEXT NOT NULL
);
