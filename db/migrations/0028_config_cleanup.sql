-- 0028: drop the registry keys nothing reads and add the numbers the API had
-- hardcoded. `ingest.ticker_minutes` has no ticker, `security.read_timeout_ms`
-- never reached the server, and the export sizes are drawn in the browser, so
-- the platform rows could not affect the consumer.
delete from platform.config
 where key in ('ingest.ticker_minutes',
               'security.read_timeout_ms',
               'export.post_width',
               'export.post_height',
               'export.story_width',
               'export.story_height');

insert into platform.config
  (key, value_type, value, min_value, max_value, scope, description)
values
  ('share.link_ttl_days', 'int', '30', 1, 365, 'platform',
   'Lifetime of a public share link'),
  ('api.page_size_max', 'int', '500', 1, 10000, 'platform',
   'Largest accepted page size'),
  ('session.slot_minutes_default', 'int', '30', 1, 240, 'platform',
   'Slot length used when a new session omits it')
on conflict (key) do update set
  value_type = excluded.value_type,
  value = excluded.value,
  min_value = excluded.min_value,
  max_value = excluded.max_value,
  scope = excluded.scope,
  description = excluded.description;

-- The trigger from 0024 already bumps this on every write; the explicit bump
-- makes the reload intent obvious and survives a database without the trigger.
update platform.config_version set version = version + 1;