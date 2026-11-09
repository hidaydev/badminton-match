-- 0044: remove the empty v1 map that only the handbook still named.
--
-- `platform.import_row_map` was created before `import.row_map`
-- (`0015_import.sql`) and never written: the loader reads and writes
-- `import.row_map`. No code, route or tool reads this table, so the previous
-- image does not need it and a plain drop is safe under the expand/contract
-- rule.
drop table if exists platform.import_row_map;
