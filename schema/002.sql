-- Fleet schema v2: per-task and per-fleet model variant.
-- Model ids themselves already live in tasks.model / fleets.commander_model / runtimes.model;
-- the ECA model catalog observed at runtime is cached in meta (keys eca_models, eca_default_model,
-- eca_variants) by the supervisor so fleet-new can offer completion before any runtime exists.

ALTER TABLE tasks ADD COLUMN variant TEXT;
ALTER TABLE fleets ADD COLUMN commander_variant TEXT;
