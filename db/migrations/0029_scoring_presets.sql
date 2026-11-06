-- 0029: one slot is one match, and a match is a list of sets.
--
-- The flat score columns stay for one release: they are the backfill source and
-- the rollback path. Nothing writes them after this migration; every reader
-- moves to session.game_results.
--
-- Existing sessions were played in the MAJADU 30 format, so their frozen rules
-- use target 30. v1 rated them with rating.score_target = 21; that was the bug
-- this migration fixes, and because points are projected on read the correction
-- is retroactive without a data migration.

alter table session.sessions
  add column scoring_preset text not null default 'legacy_v1',
  add column scoring_rules jsonb not null default '{
    "id": "legacy_v1",
    "label": "v1 scoring",
    "mode": "legacy",
    "gamesToWin": 1,
    "pointsToWin": 30,
    "winBy": 1,
    "deuceAt": null,
    "maxPoints": 99,
    "changeEndsAt": 15
  }'::jsonb;

alter table session.games
  add constraint games_identity_unique
  unique (community_id, session_id, round_no, court_no);

create table session.game_sets (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null,
  session_id uuid not null,
  round_no integer not null,
  court_no integer not null,
  set_no integer not null,
  score_a integer not null,
  score_b integer not null,
  created_at timestamptz not null default now(),
  constraint game_sets_match_fk
    foreign key (community_id, session_id, round_no, court_no)
    references session.games (community_id, session_id, round_no, court_no)
    on delete cascade,
  constraint game_sets_set_unique
    unique (session_id, round_no, court_no, set_no),
  constraint game_sets_set_no_check check (set_no between 1 and 9),
  constraint game_sets_score_range check (
    score_a between 0 and 99 and score_b between 0 and 99),
  constraint game_sets_not_tied check (score_a <> score_b)
);

insert into session.game_sets
  (community_id, session_id, round_no, court_no, set_no, score_a, score_b)
select community_id, session_id, round_no, court_no, 1, score_a, score_b
from session.games
where score_a is not null and score_b is not null;

create view session.game_results as
select
  g.id,
  g.community_id,
  g.session_id,
  g.round_no,
  g.court_no,
  g.status,
  g.side_a1,
  g.side_a2,
  g.side_b1,
  g.side_b2,
  s.scoring_preset,
  (s.scoring_rules->>'gamesToWin')::int     as games_to_win,
  (s.scoring_rules->>'pointsToWin')::int    as points_to_win,
  coalesce(t.sets_played, 0)                as sets_played,
  coalesce(t.sets_a, 0)                     as sets_a,
  coalesce(t.sets_b, 0)                     as sets_b,
  coalesce(t.points_a, 0)                   as points_a,
  coalesce(t.points_b, 0)                   as points_b,
  case
    when coalesce(t.sets_a, 0) >= (s.scoring_rules->>'gamesToWin')::int
      then 'a'
    when coalesce(t.sets_b, 0) >= (s.scoring_rules->>'gamesToWin')::int
      then 'b'
    else ''
  end                                       as winner
from session.games g
join session.sessions s
  on s.community_id = g.community_id and s.id = g.session_id
left join lateral (
  select count(*)::int                                         as sets_played,
         count(*) filter (where x.score_a > x.score_b)::int    as sets_a,
         count(*) filter (where x.score_b > x.score_a)::int    as sets_b,
         sum(x.score_a)::int                                   as points_a,
         sum(x.score_b)::int                                   as points_b
  from session.game_sets x
  where x.community_id = g.community_id
    and x.session_id = g.session_id
    and x.round_no = g.round_no
    and x.court_no = g.court_no
) t on true;

-- Configuration. The list is platform-wide; the default is community-scoped.
insert into platform.config
  (key, value_type, value, min_value, max_value, scope, description)
values
  ('session.scoring_presets', 'json',
   '[{"id":"majadu30","label":"MAJADU 30","gamesToWin":1,"pointsToWin":30,"winBy":1,"deuceAt":null,"maxPoints":30,"changeEndsAt":15},{"id":"classic21","label":"Classic BO3 21","gamesToWin":2,"pointsToWin":21,"winBy":2,"deuceAt":20,"maxPoints":30,"changeEndsAt":11},{"id":"bwf15","label":"New BWF BO3 15","gamesToWin":2,"pointsToWin":15,"winBy":2,"deuceAt":14,"maxPoints":21,"changeEndsAt":8}]',
   null, null, 'platform', 'Selectable match formats'),
  ('session.default_scoring_preset', 'string', '"majadu30"',
   null, null, 'community', 'Format chosen by default in the session wizard')
on conflict (key) do update set
  value_type = excluded.value_type,
  value = excluded.value,
  min_value = excluded.min_value,
  max_value = excluded.max_value,
  scope = excluded.scope,
  description = excluded.description;

-- Sessions carry their own target now. This key remains only as a fallback for
-- a row without a snapshot, so make the fallback match the played format.
update platform.config
   set value = '30',
       description = 'Fallback score target for a session without a frozen preset'
 where key = 'rating.score_target';

-- The trigger from 0024 already bumps this on every write; the explicit bump
-- makes the reload intent obvious and survives a database without the trigger.
update platform.config_version set version = version + 1;