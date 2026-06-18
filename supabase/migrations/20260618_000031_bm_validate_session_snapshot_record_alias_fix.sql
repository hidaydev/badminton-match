create or replace function bm.validate_session_snapshot(p_snapshot jsonb)
returns void
language plpgsql
security definer
set search_path = bm, public
as $$
declare
  v_courts integer := coalesce(nullif(p_snapshot->'session'->>'courts', '')::integer, 0);
  v_player_count integer;
  v_schedule_count integer;
begin
  if p_snapshot is null then
    raise exception 'session snapshot must not be null';
  end if;

  if jsonb_typeof(p_snapshot) <> 'object' then
    raise exception 'session snapshot must be a json object';
  end if;

  if jsonb_typeof(coalesce(p_snapshot->'session', 'null'::jsonb)) <> 'object' then
    raise exception 'session snapshot.session must be an object';
  end if;

  if coalesce(p_snapshot->'session'->>'date', '') = '' then
    raise exception 'session snapshot.session.date must not be blank';
  end if;

  perform (p_snapshot->'session'->>'date')::date;

  if coalesce(p_snapshot->'session'->>'sessionStart', '') <> '' then
    perform (p_snapshot->'session'->>'sessionStart')::time;
  end if;

  if coalesce(p_snapshot->'session'->>'slotMinutes', '') <> ''
     and (p_snapshot->'session'->>'slotMinutes')::integer <= 0 then
    raise exception 'session snapshot.session.slotMinutes must be positive';
  end if;

  if jsonb_typeof(coalesce(p_snapshot->'players', 'null'::jsonb)) <> 'array' then
    raise exception 'session snapshot.players must be an array';
  end if;

  if jsonb_typeof(coalesce(p_snapshot->'fixMatches', 'null'::jsonb)) <> 'array' then
    raise exception 'session snapshot.fixMatches must be an array';
  end if;

  if jsonb_typeof(coalesce(p_snapshot->'schedule', 'null'::jsonb)) <> 'array' then
    raise exception 'session snapshot.schedule must be an array';
  end if;

  if jsonb_typeof(coalesce(p_snapshot->'playedGames', 'null'::jsonb)) <> 'array' then
    raise exception 'session snapshot.playedGames must be an array';
  end if;

  if jsonb_typeof(coalesce(p_snapshot->'gameScores', 'null'::jsonb)) <> 'object' then
    raise exception 'session snapshot.gameScores must be an object';
  end if;

  if p_snapshot ? 'absentPlayers'
     and jsonb_typeof(coalesce(p_snapshot->'absentPlayers', 'null'::jsonb)) <> 'array' then
    raise exception 'session snapshot.absentPlayers must be an array when present';
  end if;

  select count(*)
  into v_player_count
  from jsonb_array_elements(p_snapshot->'players') as player_item(value);

  if exists (
    select 1
    from jsonb_array_elements(p_snapshot->'players') as player_item(value)
    where jsonb_typeof(player_item.value) <> 'object'
       or trim(coalesce(player_item.value->>'id', '')) = ''
       or trim(coalesce(player_item.value->>'name', '')) = ''
       or coalesce(player_item.value->>'gender', 'M') not in ('M', 'F')
       or coalesce(nullif(player_item.value->>'tier', '')::integer, 1) not between 1 and 4
  ) then
    raise exception 'session players must contain non-blank id/name and valid gender/tier values';
  end if;

  if exists (
    select 1
    from (
      select trim(player_item.value->>'id') as player_ref, count(*) as c
      from jsonb_array_elements(p_snapshot->'players') as player_item(value)
      group by trim(player_item.value->>'id')
      having count(*) > 1
    ) dup_player
  ) then
    raise exception 'session player ids must be unique';
  end if;

  if p_snapshot->'session' ? 'playerCount'
     and coalesce(nullif(p_snapshot->'session'->>'playerCount', '')::integer, -1) <> v_player_count then
    raise exception 'session snapshot.session.playerCount must match players length';
  end if;

  if p_snapshot->'session' ? 'courts' and v_courts < 0 then
    raise exception 'session snapshot.session.courts must be non-negative';
  end if;

  if p_snapshot->'session' ? 'courtNames'
     and jsonb_typeof(coalesce(p_snapshot->'session'->'courtNames', 'null'::jsonb)) <> 'array' then
    raise exception 'session snapshot.session.courtNames must be an array';
  end if;

  if p_snapshot->'session' ? 'courtTimes'
     and jsonb_typeof(coalesce(p_snapshot->'session'->'courtTimes', 'null'::jsonb)) <> 'array' then
    raise exception 'session snapshot.session.courtTimes must be an array';
  end if;

  if p_snapshot->'session' ? 'slotsPerCourt'
     and jsonb_typeof(coalesce(p_snapshot->'session'->'slotsPerCourt', 'null'::jsonb)) <> 'array' then
    raise exception 'session snapshot.session.slotsPerCourt must be an array';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(coalesce(p_snapshot->'session'->'courtTimes', '[]'::jsonb)) as court_time(value)
    where jsonb_typeof(court_time.value) <> 'object'
       or coalesce(court_time.value->>'start', '') = ''
       or coalesce(court_time.value->>'end', '') = ''
       or (court_time.value->>'end')::time <= (court_time.value->>'start')::time
  ) then
    raise exception 'session courtTimes entries must contain valid ascending start/end times';
  end if;

  if exists (
    select 1
    from jsonb_array_elements_text(coalesce(p_snapshot->'session'->'slotsPerCourt', '[]'::jsonb)) as slot_count(value)
    where nullif(slot_count.value, '')::integer < 0
  ) then
    raise exception 'session slotsPerCourt values must be non-negative';
  end if;

  select count(*)
  into v_schedule_count
  from jsonb_array_elements(p_snapshot->'schedule') as schedule_item(value);

  if p_snapshot->'session' ? 'totalGames'
     and coalesce(nullif(p_snapshot->'session'->>'totalGames', '')::integer, -1) <> v_schedule_count then
    raise exception 'session snapshot.session.totalGames must match schedule length';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_snapshot->'schedule') as schedule_item(value)
    where jsonb_typeof(schedule_item.value) <> 'object'
       or nullif(schedule_item.value->>'slot', '') is null
       or nullif(schedule_item.value->>'court', '') is null
       or (schedule_item.value->>'slot')::integer < 0
       or (schedule_item.value->>'court')::integer < 0
       or jsonb_typeof(coalesce(schedule_item.value->'teamA', 'null'::jsonb)) <> 'array'
       or jsonb_typeof(coalesce(schedule_item.value->'teamB', 'null'::jsonb)) <> 'array'
       or jsonb_array_length(schedule_item.value->'teamA') <> 2
       or jsonb_array_length(schedule_item.value->'teamB') <> 2
  ) then
    raise exception 'session schedule entries must have non-negative slot/court and 2 players per team';
  end if;

  if exists (
    select 1
    from (
      select
        (schedule_item.value->>'slot')::integer as slot_index,
        (schedule_item.value->>'court')::integer as court_index,
        count(*) as c
      from jsonb_array_elements(p_snapshot->'schedule') as schedule_item(value)
      group by 1, 2
      having count(*) > 1
    ) dup_game
  ) then
    raise exception 'session schedule must not repeat slot/court combinations';
  end if;

  if exists (
    select 1
    from (
      select trim(team_a.value) as player_ref
      from jsonb_array_elements(p_snapshot->'schedule') as schedule_item(value)
      cross join lateral jsonb_array_elements_text(schedule_item.value->'teamA') as team_a(value)

      union all

      select trim(team_b.value)
      from jsonb_array_elements(p_snapshot->'schedule') as schedule_item(value)
      cross join lateral jsonb_array_elements_text(schedule_item.value->'teamB') as team_b(value)
    ) scheduled_ref
    left join (
      select trim(player_item.value->>'id') as player_ref
      from jsonb_array_elements(p_snapshot->'players') as player_item(value)
    ) players
      on players.player_ref = scheduled_ref.player_ref
    where scheduled_ref.player_ref = ''
       or players.player_ref is null
  ) then
    raise exception 'session schedule must only reference known non-blank player ids';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_snapshot->'schedule') as schedule_item(value)
    where (
      select count(*)
      from (
        select trim(team_a.value) as player_ref
        from jsonb_array_elements_text(schedule_item.value->'teamA') as team_a(value)
        union all
        select trim(team_b.value)
        from jsonb_array_elements_text(schedule_item.value->'teamB') as team_b(value)
      ) all_players
    ) <> (
      select count(distinct player_ref)
      from (
        select trim(team_a.value) as player_ref
        from jsonb_array_elements_text(schedule_item.value->'teamA') as team_a(value)
        union all
        select trim(team_b.value)
        from jsonb_array_elements_text(schedule_item.value->'teamB') as team_b(value)
      ) all_players
    )
  ) then
    raise exception 'session schedule entries must not repeat a player within the same game';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_snapshot->'fixMatches') as fix_match_item(value)
    where jsonb_typeof(fix_match_item.value) <> 'object'
       or jsonb_typeof(coalesce(fix_match_item.value->'slots', 'null'::jsonb)) <> 'array'
       or jsonb_array_length(fix_match_item.value->'slots') > 4
  ) then
    raise exception 'session fixMatches entries must contain a slots array with at most 4 items';
  end if;

  if exists (
    select 1
    from (
      select coalesce(nullif(fix_match_item.value->>'id', ''), format('fix-%s', fix_match_item.ordinality - 1)) as legacy_ref, count(*) as c
      from jsonb_array_elements(p_snapshot->'fixMatches') with ordinality as fix_match_item(value, ordinality)
      group by 1
      having count(*) > 1
    ) dup_fix_match
  ) then
    raise exception 'session fixMatches ids must be unique';
  end if;

  if exists (
    select 1
    from (
      select nullif(trim(slot.value), '') as player_ref
      from jsonb_array_elements(p_snapshot->'fixMatches') as fix_match_item(value)
      cross join lateral jsonb_array_elements_text(coalesce(fix_match_item.value->'slots', '[]'::jsonb)) as slot(value)
    ) fix_ref
    left join (
      select trim(player_item.value->>'id') as player_ref
      from jsonb_array_elements(p_snapshot->'players') as player_item(value)
    ) players
      on players.player_ref = fix_ref.player_ref
    where fix_ref.player_ref is not null
      and players.player_ref is null
  ) then
    raise exception 'session fixMatches must only reference known player ids';
  end if;

  if exists (
    select 1
    from (
      select nullif(trim(absent_player.value), '') as player_ref
      from jsonb_array_elements_text(coalesce(p_snapshot->'absentPlayers', '[]'::jsonb)) as absent_player(value)
    ) absent_ref
    left join (
      select trim(player_item.value->>'id') as player_ref
      from jsonb_array_elements(p_snapshot->'players') as player_item(value)
    ) players
      on players.player_ref = absent_ref.player_ref
    where absent_ref.player_ref is null
       or players.player_ref is null
  ) then
    raise exception 'session absentPlayers must only reference known non-blank player ids';
  end if;

  if exists (
    select 1
    from (
      select player_ref, count(*) as c
      from (
        select nullif(trim(absent_player.value), '') as player_ref
        from jsonb_array_elements_text(coalesce(p_snapshot->'absentPlayers', '[]'::jsonb)) as absent_player(value)
      ) absent_ref
      group by player_ref
      having count(*) > 1
    ) dup_absent
  ) then
    raise exception 'session absentPlayers must not contain duplicates';
  end if;

  if exists (
    select 1
    from (
      select played_game.value as game_key
      from jsonb_array_elements_text(p_snapshot->'playedGames') as played_game(value)
    ) played_ref
    left join (
      select concat((schedule_item.value->>'slot')::integer, '-', (schedule_item.value->>'court')::integer) as game_key
      from jsonb_array_elements(p_snapshot->'schedule') as schedule_item(value)
    ) schedule_keys
      on schedule_keys.game_key = played_ref.game_key
    where schedule_keys.game_key is null
  ) then
    raise exception 'session playedGames must only reference scheduled games';
  end if;

  if exists (
    select 1
    from (
      select played_game.value as game_key, count(*) as c
      from jsonb_array_elements_text(p_snapshot->'playedGames') as played_game(value)
      group by played_game.value
      having count(*) > 1
    ) dup_played
  ) then
    raise exception 'session playedGames must not contain duplicates';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_snapshot->'schedule') as schedule_item(value)
    where exists (
      select 1
      from jsonb_each(p_snapshot->'gameScores') as score_entry(key, value)
      where score_entry.key = concat((schedule_item.value->>'slot')::integer, '-', (schedule_item.value->>'court')::integer)
    )
      and not exists (
        select 1
        from jsonb_array_elements_text(p_snapshot->'playedGames') as played_game(value)
        where played_game.value = concat((schedule_item.value->>'slot')::integer, '-', (schedule_item.value->>'court')::integer)
      )
  ) then
    raise exception 'session gameScores must only exist for games listed in playedGames';
  end if;

  if exists (
    select 1
    from jsonb_each(p_snapshot->'gameScores') as score_entry(key, value)
    left join (
      select concat((schedule_item.value->>'slot')::integer, '-', (schedule_item.value->>'court')::integer) as game_key
      from jsonb_array_elements(p_snapshot->'schedule') as schedule_item(value)
    ) schedule_keys
      on schedule_keys.game_key = score_entry.key
    where schedule_keys.game_key is null
       or jsonb_typeof(score_entry.value) <> 'object'
       or nullif(score_entry.value->>'a', '') is null
       or nullif(score_entry.value->>'b', '') is null
       or (score_entry.value->>'a')::integer not between 0 and 99
       or (score_entry.value->>'b')::integer not between 0 and 99
       or (score_entry.value->>'a')::integer = (score_entry.value->>'b')::integer
  ) then
    raise exception 'session gameScores must reference scheduled games and contain valid non-tied scores';
  end if;
end;
$$;
