-- Run this after:
-- 1. supabase/migrations/20260617_000003_bm_normalized_schema.sql
-- 2. supabase/seeds/20260617_bm_identity_seed.sql
-- 3. supabase/seeds/20260617_bm_backfill.sql

-- Session count parity
select
  (select count(*) from badminton_match.sessions) as legacy_sessions,
  (select count(*) from bm.sessions) as bm_sessions;

-- Per-session summary parity
with legacy_summary as (
  select
    s.id,
    coalesce(s.snapshot->'session'->>'title', '') as title,
    coalesce(s.snapshot->'session'->>'date', '') as session_date,
    coalesce(jsonb_array_length(coalesce(s.snapshot->'players', '[]'::jsonb)), 0) as player_count,
    coalesce(jsonb_array_length(coalesce(s.snapshot->'fixMatches', '[]'::jsonb)), 0) as fix_match_count,
    coalesce(jsonb_array_length(coalesce(s.snapshot->'schedule', '[]'::jsonb)), 0) as scheduled_game_count,
    coalesce(jsonb_array_length(coalesce(s.snapshot->'playedGames', '[]'::jsonb)), 0) as played_game_count,
    coalesce((
      select count(*)
      from jsonb_object_keys(coalesce(s.snapshot->'gameScores', '{}'::jsonb))
    ), 0) as score_count,
    coalesce(jsonb_array_length(coalesce(s.snapshot->'absentPlayers', '[]'::jsonb)), 0) as absent_count
  from badminton_match.sessions s
),
bm_summary as (
  select
    s.id,
    s.title,
    s.session_date::text as session_date,
    coalesce(player_counts.player_count, 0) as player_count,
    coalesce(fix_counts.fix_match_count, 0) as fix_match_count,
    coalesce(game_counts.scheduled_game_count, 0) as scheduled_game_count,
    coalesce(played_counts.played_game_count, 0) as played_game_count,
    coalesce(score_counts.score_count, 0) as score_count,
    coalesce(absent_counts.absent_count, 0) as absent_count
  from bm.sessions s
  left join (
    select session_id, count(*)::integer as player_count
    from bm.session_players
    group by session_id
  ) player_counts on player_counts.session_id = s.id
  left join (
    select session_id, count(*)::integer as fix_match_count
    from bm.fix_matches
    group by session_id
  ) fix_counts on fix_counts.session_id = s.id
  left join (
    select session_id, count(*)::integer as scheduled_game_count
    from bm.scheduled_games
    group by session_id
  ) game_counts on game_counts.session_id = s.id
  left join (
    select sg.session_id, count(*)::integer as played_game_count
    from bm.scheduled_games sg
    join bm.game_progress gp on gp.scheduled_game_id = sg.id
    where gp.is_played
    group by sg.session_id
  ) played_counts on played_counts.session_id = s.id
  left join (
    select sg.session_id, count(*)::integer as score_count
    from bm.scheduled_games sg
    join bm.game_scores gs on gs.scheduled_game_id = sg.id
    group by sg.session_id
  ) score_counts on score_counts.session_id = s.id
  left join (
    select session_id, count(*)::integer as absent_count
    from bm.session_players
    where is_absent
    group by session_id
  ) absent_counts on absent_counts.session_id = s.id
)
select
  coalesce(l.id, b.id) as session_id,
  l.title as legacy_title,
  b.title as bm_title,
  l.session_date as legacy_date,
  b.session_date as bm_date,
  l.player_count as legacy_player_count,
  b.player_count as bm_player_count,
  l.fix_match_count as legacy_fix_match_count,
  b.fix_match_count as bm_fix_match_count,
  l.scheduled_game_count as legacy_scheduled_game_count,
  b.scheduled_game_count as bm_scheduled_game_count,
  l.played_game_count as legacy_played_game_count,
  b.played_game_count as bm_played_game_count,
  l.score_count as legacy_score_count,
  b.score_count as bm_score_count,
  l.absent_count as legacy_absent_count,
  b.absent_count as bm_absent_count
from legacy_summary l
full outer join bm_summary b
  on b.id = l.id
where l.id is null
   or b.id is null
   or l.title <> b.title
   or l.session_date <> b.session_date
   or l.player_count <> b.player_count
   or l.fix_match_count <> b.fix_match_count
   or l.scheduled_game_count <> b.scheduled_game_count
   or l.played_game_count <> b.played_game_count
   or l.score_count <> b.score_count
   or l.absent_count <> b.absent_count
order by coalesce(l.session_date, b.session_date), coalesce(l.id, b.id);

-- Compatibility snapshot parity.
-- If this returns rows, inspect the snapshots closely.
select
  s.id as session_id,
  s.snapshot as legacy_snapshot,
  bm.get_session_snapshot_compat(s.id) as bm_snapshot
from badminton_match.sessions s
where s.snapshot is distinct from bm.get_session_snapshot_compat(s.id)
order by s.session_date, s.id;

-- Identity sanity checks
select p.canonical_name
from bm.players p
left join bm.player_aliases pa
  on pa.alias_name = bm.normalize_player_name(p.canonical_name)
 and pa.player_id = p.id
where pa.alias_name is null
order by p.canonical_name;

select
  pa.alias_name,
  count(*) as alias_rows
from bm.player_aliases pa
group by pa.alias_name
having count(*) > 1
order by pa.alias_name;

select
  sp.session_id,
  p.canonical_name,
  count(*) as duplicate_memberships
from bm.session_players sp
join bm.players p
  on p.id = sp.player_id
group by sp.session_id, p.canonical_name
having count(*) > 1
order by sp.session_id, p.canonical_name;
