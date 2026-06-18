create index if not exists bm_session_players_player_session_recent_idx
  on bm.session_players (player_id, session_internal_id, updated_at desc, internal_id desc);

create index if not exists bm_scheduled_game_players_session_player_game_idx
  on bm.scheduled_game_players (session_player_internal_id, scheduled_game_internal_id);
