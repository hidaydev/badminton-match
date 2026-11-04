-- 0009: alternate names used to recognise the same person in imports.
--
-- The canonical name stays the identity; aliases are lookup keys with the same
-- normalisation as player.players.canonical_key, unique inside a community so
-- two players cannot answer to the same alternate name.

create table player.aliases (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null,
  player_id uuid not null,
  alias text not null,
  alias_key text generated always as (
    btrim(regexp_replace(lower(alias), '\s+', ' ', 'g'))
  ) stored,
  created_at timestamptz not null default now(),
  constraint aliases_player_fk foreign key (community_id, player_id)
    references player.players (community_id, id) on delete cascade,
  constraint aliases_key_unique unique (community_id, alias_key),
  constraint aliases_not_blank check (btrim(alias) <> '')
);

create index aliases_player_idx on player.aliases (community_id, player_id);

grant select, insert, update, delete on player.aliases to bm2_app;
