-- 0015: the old-id to new-id map the one-time import needs to be re-runnable.
--
-- The v1 database is read once at cutover, but a run that fails halfway must be
-- able to continue without minting a second set of ids. Every imported row gets
-- one entry here; a second run reads it instead of inserting again.
--
-- `community_id` is part of the key, not a detail: the same v1 row belongs to
-- one community in v2, and the map is the only place that relation is written.

create schema if not exists import;

create table import.row_map (
  community_id uuid not null references platform.community(id) on delete cascade,
  entity text not null,
  old_id text not null,
  new_id uuid not null,
  created_at timestamptz not null default now(),
  constraint row_map_pk primary key (community_id, entity, old_id),
  constraint row_map_entity_not_blank check (btrim(entity) <> ''),
  constraint row_map_old_id_not_blank check (btrim(old_id) <> '')
);

create index row_map_new_id_idx on import.row_map (community_id, entity, new_id);

grant usage on schema import to bm2_app, bm2_etl;
grant select, insert, update on import.row_map to bm2_app, bm2_etl;
