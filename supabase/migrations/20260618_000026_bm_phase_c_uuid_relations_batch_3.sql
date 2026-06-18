alter table bm.fix_match_slots
  drop constraint if exists bm_fix_match_slots_internal_id_key,
  drop constraint if exists fix_match_slots_pkey;

alter table bm.fix_match_slots
  add constraint fix_match_slots_pkey primary key (internal_id);

alter table bm.fix_match_slots
  drop column if exists id;

alter table bm.scheduled_game_players
  drop constraint if exists bm_scheduled_game_players_internal_id_key,
  drop constraint if exists scheduled_game_players_pkey;

alter table bm.scheduled_game_players
  add constraint scheduled_game_players_pkey primary key (internal_id);

alter table bm.scheduled_game_players
  drop column if exists id;
