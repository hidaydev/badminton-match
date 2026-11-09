-- Deterministic fixture for the v2 parity corpus (T-071).
--
-- Applied by `./task parity v2 reset` after migrate + seed. Every id and value
-- is fixed so a rebuild produces the same rows; the share link is inserted by
-- the parity tool because its ciphertext needs the real keyring.
--
-- Contract data: one community ("parity") with an admin, a host and a member,
-- an outsider in a second community, four players, a locked session with a
-- played game, a draft session, a deletable draft session, a completed classic
-- tournament with a scored match and a signed-off team tournament.

truncate
  session.participants, session.games, session.courts, session.links,
  session.sessions,
  tournament.team_partai, tournament.team_matches, tournament.team_players,
  tournament.teams, tournament.groups, tournament.matches, tournament.pairs,
  tournament.tournaments,
  player.claims, player.merge_log, player.aliases, player.players,
  rating.events, rating.player_state, rating.snapshots,
  rating.sources, achievement.earned,
  community.join_request, community.invite, community.settings,
  community.membership,
  account.audit, account.sessions,
  platform.ws_ticket, platform.idempotency_keys, platform.outbox
  restart identity cascade;

delete from platform.community;
delete from platform.user;

insert into platform.community (id, slug, name, timezone) values
  ('10000000-0000-4000-8000-000000000001', 'parity', 'Parity Club', 'Asia/Jakarta'),
  ('10000000-0000-4000-8000-000000000002', 'foreign', 'Foreign Club', 'Asia/Jakarta');

insert into platform.user
  (id, google_sub, email_hash, display_name, is_platform_owner) values
  ('20000000-0000-4000-8000-000000000001', 'sub-owner', 'hash-owner', 'Owner', true),
  ('20000000-0000-4000-8000-000000000002', 'sub-admin', 'hash-admin', 'Admin', false),
  ('20000000-0000-4000-8000-000000000003', 'sub-host', 'hash-host', 'Host', false),
  ('20000000-0000-4000-8000-000000000004', 'sub-member', 'hash-member', 'Member', false),
  ('20000000-0000-4000-8000-000000000005', 'sub-outsider', 'hash-outsider', 'Outsider', false),
  ('20000000-0000-4000-8000-000000000006', 'sub-applicant', 'hash-applicant', 'Applicant', false);

-- Tokens are local fixtures, not secrets: each is the SHA-256 preimage of the
-- cookie the corpus sends ("parity-<role>-token").
insert into account.sessions (user_id, token_hash, absolute_expires_at)
select id,
       sha256(convert_to(case
         when google_sub = 'sub-owner' then 'parity-owner-token'
         when google_sub = 'sub-admin' then 'parity-admin-token'
         when google_sub = 'sub-host' then 'parity-host-token'
         when google_sub = 'sub-member' then 'parity-member-token'
         when google_sub = 'sub-outsider' then 'parity-outsider-token'
         else 'parity-applicant-token'
       end, 'UTF8')),
       now() + interval '30 days'
from platform.user;

insert into community.membership (community_id, user_id, role) values
  ('10000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-000000000001', 'admin'),
  ('10000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-000000000002', 'admin'),
  ('10000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-000000000003', 'host'),
  ('10000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-000000000004', 'member'),
  ('10000000-0000-4000-8000-000000000002', '20000000-0000-4000-8000-000000000005', 'admin');

insert into community.settings (community_id, values) values
  ('10000000-0000-4000-8000-000000000001',
   '{"community.directory_enabled": true, "community.join_requests_enabled": true}');

insert into player.players (id, community_id, canonical_name, tier, gender) values
  ('30000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001', 'Alice', 'B', 'F'),
  ('30000000-0000-4000-8000-000000000002', '10000000-0000-4000-8000-000000000001', 'Budi', 'C+', 'M'),
  ('30000000-0000-4000-8000-000000000003', '10000000-0000-4000-8000-000000000001', 'Candra', 'C', 'M'),
  ('30000000-0000-4000-8000-000000000004', '10000000-0000-4000-8000-000000000001', 'Dewi', 'D+', 'F'),
  ('30000000-0000-4000-8000-000000000005', '10000000-0000-4000-8000-000000000001', 'Eka', 'C', 'F'),
  ('30000000-0000-4000-8000-000000000006', '10000000-0000-4000-8000-000000000001', 'Fajar', 'B', 'M'),
  ('30000000-0000-4000-8000-000000000007', '10000000-0000-4000-8000-000000000002', 'Eko', 'B+', 'M'),
  ('30000000-0000-4000-8000-000000000008', '10000000-0000-4000-8000-000000000001', 'Temp', 'D', 'M'),
  ('30000000-0000-4000-8000-000000000009', '10000000-0000-4000-8000-000000000001', 'Merge Source', 'D', 'F');

insert into rating.player_state
  (community_id, player_id, games_played, wins, losses) values
  ('10000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000001', 4, 2, 2),
  ('10000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000002', 4, 2, 2),
  ('10000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000003', 4, 3, 1),
  ('10000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000004', 4, 1, 3);

insert into rating.snapshots (community_id, player_id, taken_on, rating) values
  ('10000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000001', '2026-10-27', 1250),
  ('10000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000003', '2026-10-27', 1310);

-- Locked session: two courts, four participants, one played game and one
-- scheduled game. The played game is what the session rating path consumes.
insert into session.sessions
  (id, community_id, title, session_date, start_time, slot_minutes, status,
   source, version) values
  ('40000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001',
   'Tuesday Night', '2026-11-03', '19:00', 30, 'locked', 'manual', 1),
  ('40000000-0000-4000-8000-000000000002', '10000000-0000-4000-8000-000000000001',
   'Draft Night', '2026-11-10', '19:00', 30, 'draft', 'manual', 1),
  ('40000000-0000-4000-8000-000000000003', '10000000-0000-4000-8000-000000000001',
   'Delete Me', '2026-11-17', '19:00', 30, 'draft', 'manual', 1),
  ('40000000-0000-4000-8000-000000000004', '10000000-0000-4000-8000-000000000002',
   'Foreign Night', '2026-11-03', '19:00', 30, 'draft', 'manual', 1);

-- The rating ingest gate is an approval stamp, not just the status.
update session.sessions set approved_at = '2026-11-03T10:00:00Z'
where id = '40000000-0000-4000-8000-000000000001';

insert into session.courts
  (id, community_id, session_id, court_index, court_name, start_time, end_time) values
  ('41000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001',
   '40000000-0000-4000-8000-000000000001', 0, 'Court 1', '19:00', '21:00'),
  ('41000000-0000-4000-8000-000000000002', '10000000-0000-4000-8000-000000000001',
   '40000000-0000-4000-8000-000000000001', 1, 'Court 2', '19:00', '21:00');

insert into session.participants
  (id, community_id, session_id, player_id) values
  ('42000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001',
   '40000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000001'),
  ('42000000-0000-4000-8000-000000000002', '10000000-0000-4000-8000-000000000001',
   '40000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000002'),
  ('42000000-0000-4000-8000-000000000003', '10000000-0000-4000-8000-000000000001',
   '40000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000003'),
  ('42000000-0000-4000-8000-000000000004', '10000000-0000-4000-8000-000000000001',
   '40000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000004');

insert into session.games
  (id, community_id, session_id, round_no, court_no, score_a, score_b, status,
   side_a1, side_a2, side_b1, side_b2) values
  ('43000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001',
   '40000000-0000-4000-8000-000000000001', 0, 0, 21, 18, 'played',
   '30000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000002',
   '30000000-0000-4000-8000-000000000003', '30000000-0000-4000-8000-000000000004'),
  ('43000000-0000-4000-8000-000000000002', '10000000-0000-4000-8000-000000000001',
   '40000000-0000-4000-8000-000000000001', 0, 1, null, null, 'scheduled',
   '30000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000003',
   '30000000-0000-4000-8000-000000000002', '30000000-0000-4000-8000-000000000004');

-- v2 reads the result from the sets; the scored fixture game is one set.
insert into session.game_sets
  (community_id, session_id, round_no, court_no, set_no, score_a, score_b) values
  ('10000000-0000-4000-8000-000000000001', '40000000-0000-4000-8000-000000000001',
   0, 0, 1, 21, 18);

-- A completed classic tournament: four pairs, one group, one scored match.
insert into tournament.tournaments
  (id, community_id, name, status, event_date, version, format) values
  ('60000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001',
   'Parity Classic', 'completed', '2026-10-25', 1, 'classic'),
  ('60000000-0000-4000-8000-000000000002', '10000000-0000-4000-8000-000000000001',
   'Parity Team', 'completed', '2026-10-26', 1, 'team'),
  ('60000000-0000-4000-8000-000000000003', '10000000-0000-4000-8000-000000000001',
   'Parity Draft', 'draft', '2026-11-20', 1, 'classic');

insert into tournament.pairs
  (id, community_id, tournament_id, display_name, player_a_id, player_b_id) values
  ('61000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001',
   '60000000-0000-4000-8000-000000000001', 'Alice/Budi',
   '30000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000002'),
  ('61000000-0000-4000-8000-000000000002', '10000000-0000-4000-8000-000000000001',
   '60000000-0000-4000-8000-000000000001', 'Candra/Dewi',
   '30000000-0000-4000-8000-000000000003', '30000000-0000-4000-8000-000000000004');

insert into tournament.pairs
  (id, community_id, tournament_id, display_name, player_a_id, player_b_id) values
  ('61000000-0000-4000-8000-000000000011', '10000000-0000-4000-8000-000000000001',
   '60000000-0000-4000-8000-000000000003', 'Alice/Candra',
   '30000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000003'),
  ('61000000-0000-4000-8000-000000000012', '10000000-0000-4000-8000-000000000001',
   '60000000-0000-4000-8000-000000000003', 'Budi/Dewi',
   '30000000-0000-4000-8000-000000000002', '30000000-0000-4000-8000-000000000004');

insert into tournament.groups
  (community_id, tournament_id, group_id, pair_id, position) values
  ('10000000-0000-4000-8000-000000000001', '60000000-0000-4000-8000-000000000001',
   'A', '61000000-0000-4000-8000-000000000001', 0),
  ('10000000-0000-4000-8000-000000000001', '60000000-0000-4000-8000-000000000001',
   'A', '61000000-0000-4000-8000-000000000002', 1);

insert into tournament.matches
  (id, community_id, tournament_id, round_no, pair_a_id, pair_b_id, score_a,
   score_b, status, phase, group_id, match_key, match_order) values
  ('62000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001',
   '60000000-0000-4000-8000-000000000001', 0,
   '61000000-0000-4000-8000-000000000001', '61000000-0000-4000-8000-000000000002',
   21, 15, 'played', 'group', 'A', 'group-A-0', 0),
  ('62000000-0000-4000-8000-000000000011', '10000000-0000-4000-8000-000000000001',
   '60000000-0000-4000-8000-000000000003', 0,
   '61000000-0000-4000-8000-000000000011', '61000000-0000-4000-8000-000000000012',
   null, null, 'scheduled', 'group', 'A', 'group-A-0', 0);

-- Team tournament: six teams, six classes each, one played team match with a
-- scored partai per band. The source row below marks it signed off.
insert into tournament.teams (id, community_id, tournament_id, seed, team_name) values
  ('63000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001', '60000000-0000-4000-8000-000000000002', 1, 'Red Raptors'),
  ('63000000-0000-4000-8000-000000000002', '10000000-0000-4000-8000-000000000001', '60000000-0000-4000-8000-000000000002', 2, 'White Fury'),
  ('63000000-0000-4000-8000-000000000003', '10000000-0000-4000-8000-000000000001', '60000000-0000-4000-8000-000000000002', 3, 'Blue Bolt'),
  ('63000000-0000-4000-8000-000000000004', '10000000-0000-4000-8000-000000000001', '60000000-0000-4000-8000-000000000002', 4, 'Green Guard'),
  ('63000000-0000-4000-8000-000000000005', '10000000-0000-4000-8000-000000000001', '60000000-0000-4000-8000-000000000002', 5, 'Gold Glide'),
  ('63000000-0000-4000-8000-000000000006', '10000000-0000-4000-8000-000000000001', '60000000-0000-4000-8000-000000000002', 6, 'Black Blade');

insert into tournament.team_players
  (id, community_id, team_id, player_name, player_id, cls)
select
  ('65000000-0000-4000-8000-0000000000' ||
   lpad((team.seed * 10 + cls.slot)::text, 2, '0'))::uuid,
  '10000000-0000-4000-8000-000000000001',
  team.id,
  team.team_name || ' ' || cls.name,
  case when team.seed = 1 then
    ('30000000-0000-4000-8000-00000000000' || (cls.slot + 1)::text)::uuid
  else null end,
  cls.name
from tournament.teams team
cross join (values
  (0, 'A+'), (1, 'A'), (2, 'B+'), (3, 'B'), (4, 'C+'), (5, 'C')
) as cls(slot, name)
where team.tournament_id = '60000000-0000-4000-8000-000000000002'
order by team.seed, cls.slot;

insert into tournament.team_matches
  (id, community_id, tournament_id, phase, match_order, match_key, team_a_id,
   team_b_id) values
  ('64000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001',
   '60000000-0000-4000-8000-000000000002', 'group', 0, 'g-1',
   '63000000-0000-4000-8000-000000000001', '63000000-0000-4000-8000-000000000002'),
  ('64000000-0000-4000-8000-000000000002', '10000000-0000-4000-8000-000000000001',
   '60000000-0000-4000-8000-000000000002', 'final', 1, 'final-1',
   '63000000-0000-4000-8000-000000000001', '63000000-0000-4000-8000-000000000003');

insert into tournament.team_partai
  (id, community_id, team_match_id, partai_index, score_a, score_b) values
  ('66000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001',
   '64000000-0000-4000-8000-000000000001', 0, 21, 18),
  ('66000000-0000-4000-8000-000000000002', '10000000-0000-4000-8000-000000000001',
   '64000000-0000-4000-8000-000000000001', 1, 18, 21),
  ('66000000-0000-4000-8000-000000000003', '10000000-0000-4000-8000-000000000001',
   '64000000-0000-4000-8000-000000000001', 2, 21, 19);

-- One pending claim and one unused invite with fixed ids so the corpus can
-- address them without copying a server-generated value.
insert into player.claims
  (id, community_id, player_id, user_id, status) values
  ('70000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001',
   '30000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-000000000004',
   'pending');

insert into community.join_request
  (id, community_id, user_id, status) values
  ('72000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001',
   '20000000-0000-4000-8000-000000000006', 'pending');

insert into community.invite
  (id, community_id, token_hash, email_hash, role, created_by, expires_at) values
  ('71000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001',
   sha256(convert_to('parity-invite-token', 'UTF8')), 'hash-outsider', 'member',
   '20000000-0000-4000-8000-000000000002', now() + interval '7 days');

-- A fixed rating event so the corpus can address it with PATCH .../rating-sources.
insert into rating.events
  (id, community_id, local_date, event_type, source_id, point_entries) values
  ('80000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001',
   '2026-10-25', 'tournament', '60000000-0000-4000-8000-000000000001', 4);

insert into rating.sources (community_id, source_id, kind, finalized, finalized_at) values
  ('10000000-0000-4000-8000-000000000001', '60000000-0000-4000-8000-000000000002',
   'tournament', true, '2026-10-27T10:00:00Z');
