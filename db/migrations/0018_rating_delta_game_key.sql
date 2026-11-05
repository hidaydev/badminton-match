-- 0018: a rating event covers a whole session, but a player can appear in
-- several of its games on the same side. The old unique key collapsed every
-- game after the first, so points and win/loss counts were short. The game key
-- keeps one delta per game while the event stays per session.

alter table rating.deltas
  add column game_key text not null default '';

alter table rating.deltas
  drop constraint deltas_unique_per_side;

alter table rating.deltas
  add constraint deltas_unique_per_side
    unique (event_id, side, player_id, game_key);
