-- Synthetic v1 data for parity runs. Fixed identifiers keep recordings stable
-- between machines; nothing here is real player data.
begin;

delete from bm.rating_deltas;
delete from bm.rating_events;
delete from bm.rating_players;
delete from bm.scheduled_game_players;
delete from bm.scheduled_games;
delete from bm.session_courts;
delete from bm.session_players;
delete from bm.tournament_team_match_games;
delete from bm.tournament_team_matches;
delete from bm.tournament_team_players;
delete from bm.tournament_teams;
delete from bm.tournament_matches;
delete from bm.tournament_pair_players;
delete from bm.tournament_pairs;
delete from bm.tournament_groups;
delete from bm.tournaments;
delete from bm.sessions;
delete from bm.players;

insert into bm.players (id, canonical_name, tier, registered_at, gender) values
  ('11111111-1111-1111-1111-111111111101', 'Andi', 'C',  '2025-01-05', 'M'),
  ('11111111-1111-1111-1111-111111111102', 'Budi', 'C+', '2025-01-05', 'M'),
  ('11111111-1111-1111-1111-111111111103', 'Chandra', 'B', '2025-02-11', 'M'),
  ('11111111-1111-1111-1111-111111111104', 'Dewi', 'B+', '2025-02-11', 'F'),
  ('11111111-1111-1111-1111-111111111105', 'Eka', 'C', '2025-03-02', 'F'),
  ('11111111-1111-1111-1111-111111111106', 'Fajar', 'D+', '2025-03-02', 'M'),
  ('11111111-1111-1111-1111-111111111107', 'Gita', 'A', '2025-04-19', 'F'),
  ('11111111-1111-1111-1111-111111111108', 'Hadi', 'A+', '2025-04-19', 'M');

insert into bm.sessions
  (id, share_code, title, session_date, session_start, slot_minutes, status, source,
   session_tier_count, include_absent_players, include_tier_count, version)
values
  ('22222222-2222-2222-2222-222222222201', 'v1demo0001', 'Tuesday Night',
   '2026-10-27', '19:00', 30, 'published', 'manual', 3, false, true, 3),
  ('22222222-2222-2222-2222-222222222202', 'v1demo0002', 'Thursday Night',
   '2026-10-29', '19:30', 30, 'draft', 'manual', 3, false, false, 1);

insert into bm.session_courts (session_id, court_index, court_name, start_time, end_time)
values
  ('22222222-2222-2222-2222-222222222201', 0, 'Court 1', '19:00', '21:00'),
  ('22222222-2222-2222-2222-222222222201', 1, 'Court 2', '19:00', '21:00');

insert into bm.session_players
  (player_id, player_ref, source_name, sort_order, gender, tier, is_absent, session_id)
values
  ('11111111-1111-1111-1111-111111111101', 'p1', 'Andi', 0, 'M', 3, false, '22222222-2222-2222-2222-222222222201'),
  ('11111111-1111-1111-1111-111111111102', 'p2', 'Budi', 1, 'M', 4, false, '22222222-2222-2222-2222-222222222201'),
  ('11111111-1111-1111-1111-111111111103', 'p3', 'Chandra', 2, 'M', 5, false, '22222222-2222-2222-2222-222222222201'),
  ('11111111-1111-1111-1111-111111111104', 'p4', 'Dewi', 3, 'F', 6, false, '22222222-2222-2222-2222-222222222201'),
  ('11111111-1111-1111-1111-111111111105', 'p5', 'Eka', 4, 'F', 3, false, '22222222-2222-2222-2222-222222222201'),
  ('11111111-1111-1111-1111-111111111106', 'p6', 'Fajar', 5, 'M', 2, false, '22222222-2222-2222-2222-222222222201'),
  ('11111111-1111-1111-1111-111111111107', 'p7', 'Gita', 6, 'F', 7, false, '22222222-2222-2222-2222-222222222201'),
  ('11111111-1111-1111-1111-111111111108', 'p8', 'Hadi', 7, 'M', 8, false, '22222222-2222-2222-2222-222222222201');

insert into bm.scheduled_games
  (session_id, slot_index, court_index, status, source, is_played, played_order,
   legacy_order, score_a, score_b, version)
values
  ('22222222-2222-2222-2222-222222222201', 0, 0, 'played', 'generator', true, 1, 1, 21, 18, 2),
  ('22222222-2222-2222-2222-222222222201', 0, 1, 'played', 'generator', true, 2, 2, 15, 21, 2),
  ('22222222-2222-2222-2222-222222222201', 1, 0, 'scheduled', 'generator', false, null, 3, null, null, 1);

insert into bm.rating_players (player_id, games_played, wins, losses, last_played_at)
values
  ('11111111-1111-1111-1111-111111111101', 2, 1, 1, '2026-10-27'),
  ('11111111-1111-1111-1111-111111111102', 2, 1, 1, '2026-10-27'),
  ('11111111-1111-1111-1111-111111111103', 2, 2, 0, '2026-10-27'),
  ('11111111-1111-1111-1111-111111111104', 2, 0, 2, '2026-10-27');

insert into bm.tournaments (id, share_code, name, event_date, format, version)
values ('33333333-3333-3333-3333-333333333301', 'v1tour0001', 'Autumn Cup',
        '2026-10-25', 'classic', 1);

insert into bm.tournament_pairs (id, tournament_id, pair_name, seed)
values
  ('44444444-4444-4444-4444-444444444401', '33333333-3333-3333-3333-333333333301', 'Andi / Budi', 1),
  ('44444444-4444-4444-4444-444444444402', '33333333-3333-3333-3333-333333333301', 'Chandra / Dewi', 2);

insert into bm.tournament_matches
  (tournament_id, phase, pair_a_id, pair_b_id, score_a, score_b, match_order, match_key)
values
  ('33333333-3333-3333-3333-333333333301', 'final',
   '44444444-4444-4444-4444-444444444401', '44444444-4444-4444-4444-444444444402',
   21, 17, 1, 'final-1');

commit;
