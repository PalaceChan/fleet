-- Fleet schema v3: lieutenants (docs/lieutenants.md).
-- A lieutenant is a fleet whose parent_id names its root fleet; its commander runtime is the
-- lieutenant.  Existing fleets keep parent_id NULL and behave as before.  One level only
-- (enforced by fleet-core, not the schema).

ALTER TABLE fleets ADD COLUMN parent_id TEXT REFERENCES fleets (id);
ALTER TABLE fleets ADD COLUMN charter TEXT;

-- Names are unique per parent: two roots cannot both have a lieutenant called `frontend` clash-free,
-- and a lieutenant may share a name with an unrelated root.  Selectors are written root/child.
DROP INDEX fleets_active_name;
CREATE UNIQUE INDEX fleets_active_name ON fleets (COALESCE(parent_id, ''), name) WHERE lifecycle <> 'archived';
CREATE INDEX fleets_parent ON fleets (parent_id);

-- A delegation from a root commander to one of its lieutenants.  The request text is the message
-- queued on the lieutenant's lane (message_id); reports back are actionable `lieutenant-report`
-- events in the parent fleet carrying request_id.
CREATE TABLE requests (
  id               TEXT PRIMARY KEY,
  parent_fleet_id  TEXT NOT NULL REFERENCES fleets (id),
  child_fleet_id   TEXT NOT NULL REFERENCES fleets (id),
  subject          TEXT NOT NULL,
  state            TEXT NOT NULL CHECK (state IN ('open','settled')),
  outcome          TEXT CHECK (outcome IS NULL OR outcome IN ('done','failed','partial')),
  summary          TEXT,
  message_id       TEXT,
  created_at       TEXT NOT NULL,
  updated_at       TEXT NOT NULL
);
CREATE INDEX requests_child_state ON requests (child_fleet_id, state);
CREATE INDEX requests_parent_state ON requests (parent_fleet_id, state);
