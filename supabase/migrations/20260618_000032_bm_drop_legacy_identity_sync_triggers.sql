drop trigger if exists bm_fix_match_slots_sync_identities on bm.fix_match_slots;
drop trigger if exists bm_scheduled_game_players_sync_identities on bm.scheduled_game_players;
drop trigger if exists bm_game_progress_sync_scheduled_game_identity on bm.game_progress;
drop trigger if exists bm_game_scores_sync_scheduled_game_identity on bm.game_scores;

drop function if exists bm.sync_fix_match_slot_identities();
drop function if exists bm.sync_scheduled_game_player_identities();
drop function if exists bm.sync_scheduled_game_identity();
