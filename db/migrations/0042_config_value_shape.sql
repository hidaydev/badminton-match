-- 0042: tie `platform.config.value` to its declared type and bounds.
--
-- The table advertised `value_type`, `min_value` and `max_value`, but the only
-- checks were between the two bounds. A typo such as an int key holding the
-- string `"twelve"`, or a value outside the frozen range, was accepted by SQL
-- and then refused the whole config load at boot: every request failed until an
-- operator fixed the row with psql. The database now rejects the same shapes
-- the compiled registry rejects, and `min_value`/`max_value` are enforced
-- instead of decorative.
alter table platform.config
  add constraint config_value_type_shape check (
    (value_type = 'int' and jsonb_typeof(value) = 'number'
       and value::text ~ '^-?[0-9]+$')
    or (value_type = 'decimal' and jsonb_typeof(value) = 'number')
    or (value_type = 'bool' and jsonb_typeof(value) = 'boolean')
    or (value_type = 'string' and jsonb_typeof(value) = 'string')
    or value_type = 'json'
  ),
  add constraint config_value_bounds_check check (
    value_type not in ('int', 'decimal')
    or (
      (min_value is null or
        (case when jsonb_typeof(value) = 'number'
              then value::text::numeric end) >= min_value)
      and (max_value is null or
        (case when jsonb_typeof(value) = 'number'
              then value::text::numeric end) <= max_value)
    )
  );
