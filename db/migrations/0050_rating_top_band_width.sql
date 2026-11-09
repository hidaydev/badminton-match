-- 0050: the open top tier's assumed strength becomes configuration.
--
-- `tierStrength` reads the midpoint of a closed band, but the top band has a
-- null maximum, so the old code assumed 100 points above its floor. Every other
-- business number in the rating formula arrives from `platform.config`; this
-- one was the last literal, which is why changing it needed a rebuild (SQ-20).
-- The seed carries the same row for a fresh database.
insert into platform.config
  (key, value_type, value, min_value, max_value, scope, description)
values
  ('rating.top_band_width', 'int', '100', 1, 10000, 'platform',
   'Strength assumed above the floor of the open-ended top tier band')
on conflict (key) do update set
  value_type = excluded.value_type,
  value = excluded.value,
  min_value = excluded.min_value,
  max_value = excluded.max_value,
  scope = excluded.scope,
  description = excluded.description;

-- The trigger from 0024 bumps this on every write; the explicit bump makes the
-- reload intent obvious and survives a database without the trigger.
update platform.config_version set version = version + 1;
