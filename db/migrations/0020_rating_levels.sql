-- 0020: v1's tournament point ladder as data.
--
-- A tournament is worth `champion_points * round_ratio(placement)`, never the
-- sum of its games. v1 kept that ladder in `bm.rank_point_levels`; it is data,
-- so a new format is a row, not a deploy. The board falls back to the game
-- formula for a format with no enabled row, exactly like v1.

create table rating.levels (
  community_id uuid not null references platform.community(id) on delete cascade,
  kind text not null,
  champion_points numeric(12, 2) not null,
  round_ratios jsonb not null default '{}'::jsonb,
  enabled boolean not null default true,
  updated_at timestamptz not null default now(),
  primary key (community_id, kind),
  constraint levels_champion_non_negative check (champion_points >= 0)
);

grant select, insert, update, delete on rating.levels to bm2_app;
