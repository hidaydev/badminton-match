-- 0010: who plays in a session, and who stands on which side of a game.
--
-- The schedule is relational, not a JSON snapshot: a participant is a player in
-- a session, and a game names up to two players per side. Rating ingest needs
-- exactly this mapping to turn a score into a delta per player.

create table session.participants (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null,
  session_id uuid not null,
  player_id uuid not null,
  is_absent boolean not null default false,
  created_at timestamptz not null default now(),
  constraint participants_session_fk foreign key (community_id, session_id)
    references session.sessions (community_id, id) on delete cascade,
  constraint participants_player_fk foreign key (community_id, player_id)
    references player.players (community_id, id) on delete restrict,
  constraint participants_session_player_unique unique (session_id, player_id)
);

create index participants_community_session_idx
  on session.participants (community_id, session_id);
create index participants_community_player_idx
  on session.participants (community_id, player_id);

grant select, insert, update, delete on session.participants to bm2_app;

-- Four slots, like v1: singles uses one slot per side, doubles uses two.
-- A NULL slot is an empty position, not a player.
alter table session.games
  add column if not exists side_a1 uuid,
  add column if not exists side_a2 uuid,
  add column if not exists side_b1 uuid,
  add column if not exists side_b2 uuid;

alter table session.games
  add constraint games_side_a1_fk foreign key (session_id, side_a1)
    references session.participants (session_id, player_id),
  add constraint games_side_a2_fk foreign key (session_id, side_a2)
    references session.participants (session_id, player_id),
  add constraint games_side_b1_fk foreign key (session_id, side_b1)
    references session.participants (session_id, player_id),
  add constraint games_side_b2_fk foreign key (session_id, side_b2)
    references session.participants (session_id, player_id);

alter table session.games
  add constraint games_distinct_sides check (
    side_a1 is distinct from side_b1 and
    side_a1 is distinct from side_b2 and
    side_a2 is distinct from side_b1 and
    side_a2 is distinct from side_b2 and
    (side_a1 is null or side_a2 is null or side_a1 <> side_a2) and
    (side_b1 is null or side_b2 is null or side_b1 <> side_b2));
