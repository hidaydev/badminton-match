--
-- PostgreSQL database dump
--

\restrict mwTE15JZPGuJDPUTPSQnrORGa96Y5goe8JhnSsswcN3uzOfqvVsuVJTJayMwGUy

-- Dumped from database version 18.6 (Debian 18.6-1.pgdg13+2)
-- Dumped by pg_dump version 18.6 (Debian 18.6-1.pgdg13+2)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: bm; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA bm;


--
-- Name: delete_player(uuid, boolean); Type: FUNCTION; Schema: bm; Owner: -
--

CREATE FUNCTION bm.delete_player(p_player_id uuid, p_force boolean DEFAULT false) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'bm', 'public'
    AS $$
declare
  v_canonical text;
  v_alias_count integer;
  v_session_ref_count integer;
  v_session_refs jsonb;
begin
  -- Verify player exists
  select canonical_name into v_canonical
  from bm.players where id = p_player_id;
  if not found then
    raise exception 'player not found: %', p_player_id;
  end if;
  -- Check session_players references (FK has no cascade)
  select count(*) into v_session_ref_count
  from bm.session_players where player_id = p_player_id;
  if v_session_ref_count > 0 and not p_force then
    select coalesce(jsonb_agg(jsonb_build_object(
      'sessionId', sp.session_id,
      'sourceName', sp.source_name
    ) order by sp.session_id), '[]'::jsonb)
    into v_session_refs
    from bm.session_players sp
    where sp.player_id = p_player_id;
    raise exception
      'player % is referenced in % session(s). Use p_force=true to remove. References: %',
      v_canonical, v_session_ref_count, v_session_refs::text;
  end if;
  -- Count aliases for summary (before cascade deletes them)
  select count(*) into v_alias_count from bm.player_aliases where player_id = p_player_id;
  -- Force: remove session_players rows first
  -- (cascade handles: fix_match_slots SET NULL, scheduled_game_players CASCADE)
  if v_session_ref_count > 0 then
    delete from bm.session_players where player_id = p_player_id;
  end if;
  -- Delete the player — ON DELETE CASCADE auto-removes player_aliases
  delete from bm.players where id = p_player_id;
  return jsonb_build_object(
    'deleted', true,
    'playerId', p_player_id,
    'canonicalName', v_canonical,
    'aliases', v_alias_count,
    'sessionRefsRemoved', v_session_ref_count
  );
end;
$$;


--
-- Name: merge_players(uuid, uuid); Type: FUNCTION; Schema: bm; Owner: -
--

CREATE FUNCTION bm.merge_players(p_target uuid, p_source uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'bm', 'public'
    AS $$
declare
  v_target_name text;
  v_source_name text;
  v_aliases integer;
  v_sessions integer;
  v_deltas integer;
  v_snapshots integer;
  v_pairs integer;
  v_team integer;
begin
  select canonical_name into v_target_name from bm.players where id = p_target;
  if not found then raise exception 'target player not found: %', p_target; end if;
  select canonical_name into v_source_name from bm.players where id = p_source;
  if not found then raise exception 'source player not found: %', p_source; end if;
  if p_target = p_source then raise exception 'source and target must be different players'; end if;

  -- Guard: source & target main di sesi yang sama → tidak bisa digabung aman
  if exists (
    select 1 from bm.session_players s
    join bm.session_players t on t.session_id = s.session_id
    where s.player_id = p_source and t.player_id = p_target
  ) then
    raise exception 'cannot merge: source and target played in the same session';
  end if;

  -- 1. player_aliases: pindah semua alias source → target (konflik → skip)
  select count(*) into v_aliases from bm.player_aliases where player_id = p_source;
  insert into bm.player_aliases (player_id, alias_name)
    select p_target, alias_name from bm.player_aliases where player_id = p_source
    on conflict (alias_name) do nothing;
  delete from bm.player_aliases where player_id = p_source;

  -- 2. session_players: pindah source → target
  update bm.session_players set player_id = p_target, updated_at = now()
  where player_id = p_source;
  get diagnostics v_sessions = row_count;

  -- 3. rating_deltas: hapus konflik event, lalu pindah
  delete from bm.rating_deltas rd
  where rd.player_id = p_source
    and exists (select 1 from bm.rating_deltas t where t.event_id = rd.event_id and t.player_id = p_target);
  update bm.rating_deltas set player_id = p_target where player_id = p_source;
  get diagnostics v_deltas = row_count;

  -- 4. rank_snapshots: hapus konflik (as_of, player_id), lalu pindah
  delete from bm.rank_snapshots rs
  where rs.player_id = p_source
    and exists (select 1 from bm.rank_snapshots t where t.as_of = rs.as_of and t.player_id = p_target);
  update bm.rank_snapshots set player_id = p_target where player_id = p_source;
  get diagnostics v_snapshots = row_count;

  -- 5. tournament pairs: hapus konflik pair, lalu pindah
  delete from bm.tournament_pair_players pp
  where pp.player_id = p_source
    and exists (select 1 from bm.tournament_pair_players t where t.pair_id = pp.pair_id and t.player_id = p_target);
  update bm.tournament_pair_players set player_id = p_target where player_id = p_source;
  get diagnostics v_pairs = row_count;

  -- 6. tournament team: pindah player_id (nullable)
  update bm.tournament_team_players set player_id = p_target where player_id = p_source;
  get diagnostics v_team = row_count;

  -- 7. rating_players: target menang, hapus source (caller rebuild rating)
  delete from bm.rating_players where player_id = p_source;

  -- 8. Hapus pemain source
  delete from bm.players where id = p_source;

  return jsonb_build_object(
    'target_player_id', p_target,
    'source_player_id', p_source,
    'aliases_moved', v_aliases,
    'sessions_moved', v_sessions,
    'deltas_moved', v_deltas,
    'snapshots_moved', v_snapshots,
    'pairs_moved', v_pairs,
    'team_moves', v_team
  );
end;
$$;


--
-- Name: normalize_player_name(text); Type: FUNCTION; Schema: bm; Owner: -
--

CREATE FUNCTION bm.normalize_player_name(p_name text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
  select nullif(
    regexp_replace(lower(trim(coalesce(p_name, ''))), '\s+', ' ', 'g'),
    ''
  );
$$;


--
-- Name: set_updated_at(); Type: FUNCTION; Schema: bm; Owner: -
--

CREATE FUNCTION bm.set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  new.updated_at := now();
  return new;
end;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: fix_matches; Type: TABLE; Schema: bm; Owner: -
--

CREATE TABLE bm.fix_matches (
    legacy_ref text NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    session_id uuid CONSTRAINT fix_matches_session_internal_id_not_null NOT NULL,
    internal_id uuid DEFAULT gen_random_uuid() NOT NULL,
    slot_0 uuid,
    slot_1 uuid,
    slot_2 uuid,
    slot_3 uuid,
    CONSTRAINT bm_fix_matches_legacy_ref_not_blank_ck CHECK ((TRIM(BOTH FROM legacy_ref) <> ''::text)),
    CONSTRAINT fix_matches_sort_order_check CHECK ((sort_order >= 0))
);


--
-- Name: idempotency_keys; Type: TABLE; Schema: bm; Owner: -
--

CREATE TABLE bm.idempotency_keys (
    session_id uuid NOT NULL,
    key text NOT NULL,
    response jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL
);


--
-- Name: outbox_events; Type: TABLE; Schema: bm; Owner: -
--

CREATE TABLE bm.outbox_events (
    id bigint NOT NULL,
    session_id uuid NOT NULL,
    aggregate text NOT NULL,
    aggregate_id text NOT NULL,
    event_type text NOT NULL,
    payload jsonb NOT NULL,
    version bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: outbox_events_id_seq; Type: SEQUENCE; Schema: bm; Owner: -
--

CREATE SEQUENCE bm.outbox_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: outbox_events_id_seq; Type: SEQUENCE OWNED BY; Schema: bm; Owner: -
--

ALTER SEQUENCE bm.outbox_events_id_seq OWNED BY bm.outbox_events.id;


--
-- Name: player_achievements; Type: TABLE; Schema: bm; Owner: -
--

CREATE TABLE bm.player_achievements (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    player_id uuid NOT NULL,
    achievement_key text NOT NULL,
    kind text NOT NULL,
    earned_at date NOT NULL,
    value bigint,
    meta jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT player_achievements_kind_check CHECK ((kind = ANY (ARRAY['attendance'::text, 'volume'::text, 'opponent'::text, 'tournament'::text, 'tier'::text, 'rating'::text, 'rank'::text, 'social'::text, 'season'::text])))
);


--
-- Name: player_aliases; Type: TABLE; Schema: bm; Owner: -
--

CREATE TABLE bm.player_aliases (
    alias_name text NOT NULL,
    player_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT player_aliases_alias_name_normalized_ck CHECK ((alias_name = bm.normalize_player_name(alias_name)))
);


--
-- Name: players; Type: TABLE; Schema: bm; Owner: -
--

CREATE TABLE bm.players (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    canonical_name text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    tier text,
    registered_at date,
    gender text DEFAULT 'M'::text NOT NULL,
    CONSTRAINT bm_players_canonical_name_not_blank_ck CHECK ((TRIM(BOTH FROM canonical_name) <> ''::text)),
    CONSTRAINT players_gender_check CHECK ((gender = ANY (ARRAY['M'::text, 'F'::text]))),
    CONSTRAINT players_tier_ck CHECK (((tier IS NULL) OR (tier = ANY (ARRAY['D'::text, 'D+'::text, 'C'::text, 'C+'::text, 'B'::text, 'B+'::text, 'A'::text, 'A+'::text]))))
);


--
-- Name: rank_point_levels; Type: TABLE; Schema: bm; Owner: -
--

CREATE TABLE bm.rank_point_levels (
    kind text NOT NULL,
    champion_points numeric DEFAULT 0 NOT NULL,
    round_ratios jsonb DEFAULT '{}'::jsonb NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT rank_point_levels_champion_ck CHECK ((champion_points >= (0)::numeric))
);


--
-- Name: rank_snapshots; Type: TABLE; Schema: bm; Owner: -
--

CREATE TABLE bm.rank_snapshots (
    as_of date NOT NULL,
    player_id uuid NOT NULL,
    rank integer NOT NULL,
    points numeric NOT NULL,
    captured_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT rank_snapshots_rank_ck CHECK ((rank > 0))
);


--
-- Name: rating_config; Type: TABLE; Schema: bm; Owner: -
--

CREATE TABLE bm.rating_config (
    key text NOT NULL,
    value jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: rating_deltas; Type: TABLE; Schema: bm; Owner: -
--

CREATE TABLE bm.rating_deltas (
    event_id uuid NOT NULL,
    player_id uuid NOT NULL,
    team text NOT NULL,
    outcome text NOT NULL,
    CONSTRAINT rating_deltas_outcome_check CHECK ((outcome = ANY (ARRAY['W'::text, 'L'::text]))),
    CONSTRAINT rating_deltas_team_check CHECK ((team = ANY (ARRAY['A'::text, 'B'::text])))
);


--
-- Name: rating_events; Type: TABLE; Schema: bm; Owner: -
--

CREATE TABLE bm.rating_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    match_key text NOT NULL,
    seq bigint NOT NULL,
    kind text NOT NULL,
    source_id text NOT NULL,
    source_fingerprint text NOT NULL,
    stable_game_id text NOT NULL,
    date date NOT NULL,
    created_at timestamp with time zone NOT NULL,
    game_order text NOT NULL,
    title text NOT NULL,
    score_a integer NOT NULL,
    score_b integer NOT NULL,
    target integer NOT NULL,
    phase text NOT NULL,
    processed_at timestamp with time zone NOT NULL,
    CONSTRAINT rating_events_kind_check CHECK ((kind = ANY (ARRAY['session'::text, 'tournament_classic'::text, 'tournament_team'::text]))),
    CONSTRAINT rating_events_target_check CHECK (((target >= 1) AND (target <= 99)))
);


--
-- Name: rating_events_seq_seq; Type: SEQUENCE; Schema: bm; Owner: -
--

CREATE SEQUENCE bm.rating_events_seq_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rating_events_seq_seq; Type: SEQUENCE OWNED BY; Schema: bm; Owner: -
--

ALTER SEQUENCE bm.rating_events_seq_seq OWNED BY bm.rating_events.seq;


--
-- Name: rating_players; Type: TABLE; Schema: bm; Owner: -
--

CREATE TABLE bm.rating_players (
    player_id uuid NOT NULL,
    games_played integer DEFAULT 0 NOT NULL,
    wins integer DEFAULT 0 NOT NULL,
    losses integer DEFAULT 0 NOT NULL,
    last_played_at date,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT rating_players_games_ck CHECK ((games_played = (wins + losses)))
);


--
-- Name: rating_sources; Type: TABLE; Schema: bm; Owner: -
--

CREATE TABLE bm.rating_sources (
    source_id text NOT NULL,
    source_kind text NOT NULL,
    fingerprint text NOT NULL,
    finalized boolean DEFAULT false NOT NULL,
    last_ingested_seq bigint NOT NULL,
    ingested_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT rating_sources_source_kind_check CHECK ((source_kind = ANY (ARRAY['session'::text, 'tournament_classic'::text, 'tournament_team'::text])))
);


--
-- Name: scheduled_game_players; Type: TABLE; Schema: bm; Owner: -
--

CREATE TABLE bm.scheduled_game_players (
    team text NOT NULL,
    "position" integer NOT NULL,
    scheduled_game_internal_id uuid NOT NULL,
    session_player_internal_id uuid NOT NULL,
    internal_id uuid DEFAULT gen_random_uuid() NOT NULL,
    CONSTRAINT scheduled_game_players_position_check CHECK (("position" = ANY (ARRAY[0, 1]))),
    CONSTRAINT scheduled_game_players_team_check CHECK ((team = ANY (ARRAY['A'::text, 'B'::text])))
);


--
-- Name: scheduled_games; Type: TABLE; Schema: bm; Owner: -
--

CREATE TABLE bm.scheduled_games (
    slot_index integer NOT NULL,
    court_index integer NOT NULL,
    status text NOT NULL,
    source text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    legacy_order integer,
    session_id uuid CONSTRAINT scheduled_games_session_internal_id_not_null NOT NULL,
    internal_id uuid DEFAULT gen_random_uuid() NOT NULL,
    is_played boolean DEFAULT false NOT NULL,
    played_order integer,
    score_a integer,
    score_b integer,
    version bigint DEFAULT 1 NOT NULL,
    skipped_player_refs text[] DEFAULT '{}'::text[] NOT NULL,
    CONSTRAINT scheduled_games_court_index_check CHECK ((court_index >= 0)),
    CONSTRAINT scheduled_games_not_tied_check CHECK ((NOT (is_played AND (score_a IS NOT NULL) AND (score_b IS NOT NULL) AND (score_a = score_b)))),
    CONSTRAINT scheduled_games_score_a_check CHECK (((score_a IS NULL) OR ((score_a >= 0) AND (score_a <= 99)))),
    CONSTRAINT scheduled_games_score_b_check CHECK (((score_b IS NULL) OR ((score_b >= 0) AND (score_b <= 99)))),
    CONSTRAINT scheduled_games_slot_index_check CHECK ((slot_index >= 0)),
    CONSTRAINT scheduled_games_source_check CHECK ((source = ANY (ARRAY['generator'::text, 'manual'::text, 'constraint'::text, 'legacy_snapshot'::text, 'compat_publish'::text]))),
    CONSTRAINT scheduled_games_status_check CHECK ((status = ANY (ARRAY['scheduled'::text, 'played'::text, 'cancelled'::text])))
);


--
-- Name: session_courts; Type: TABLE; Schema: bm; Owner: -
--

CREATE TABLE bm.session_courts (
    court_index integer NOT NULL,
    court_name text DEFAULT ''::text NOT NULL,
    start_time time without time zone NOT NULL,
    end_time time without time zone NOT NULL,
    session_id uuid CONSTRAINT session_courts_session_internal_id_not_null NOT NULL,
    internal_id uuid DEFAULT gen_random_uuid() NOT NULL,
    CONSTRAINT bm_session_courts_time_range_ck CHECK ((end_time > start_time)),
    CONSTRAINT session_courts_court_index_check CHECK ((court_index >= 0))
);


--
-- Name: session_players; Type: TABLE; Schema: bm; Owner: -
--

CREATE TABLE bm.session_players (
    player_id uuid,
    player_ref text NOT NULL,
    source_name text NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    gender text NOT NULL,
    tier integer NOT NULL,
    is_absent boolean DEFAULT false NOT NULL,
    replacement_note text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    absent_order integer,
    session_id uuid CONSTRAINT session_players_session_internal_id_not_null NOT NULL,
    internal_id uuid DEFAULT gen_random_uuid() NOT NULL,
    CONSTRAINT bm_session_players_player_ref_not_blank_ck CHECK ((TRIM(BOTH FROM player_ref) <> ''::text)),
    CONSTRAINT bm_session_players_source_name_not_blank_ck CHECK ((TRIM(BOTH FROM source_name) <> ''::text)),
    CONSTRAINT session_players_absent_order_check CHECK (((absent_order IS NULL) OR (absent_order >= 0))),
    CONSTRAINT session_players_gender_check CHECK ((gender = ANY (ARRAY['M'::text, 'F'::text]))),
    CONSTRAINT session_players_sort_order_check CHECK ((sort_order >= 0)),
    CONSTRAINT session_players_tier_check CHECK (((tier >= 1) AND (tier <= 8)))
);


--
-- Name: sessions; Type: TABLE; Schema: bm; Owner: -
--

CREATE TABLE bm.sessions (
    share_code text CONSTRAINT sessions_id_not_null NOT NULL,
    title text DEFAULT ''::text NOT NULL,
    session_date date NOT NULL,
    session_start time without time zone DEFAULT '00:00:00'::time without time zone NOT NULL,
    slot_minutes integer NOT NULL,
    status text NOT NULL,
    source text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    session_tier_count integer DEFAULT 0 NOT NULL,
    include_absent_players boolean DEFAULT false NOT NULL,
    include_tier_count boolean DEFAULT false NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    id uuid DEFAULT gen_random_uuid() CONSTRAINT sessions_internal_id_not_null NOT NULL,
    CONSTRAINT bm_sessions_share_code_not_blank_ck CHECK ((TRIM(BOTH FROM share_code) <> ''::text)),
    CONSTRAINT bm_sessions_version_positive_ck CHECK ((version > 0)),
    CONSTRAINT sessions_slot_minutes_check CHECK ((slot_minutes > 0)),
    CONSTRAINT sessions_source_check CHECK ((source = ANY (ARRAY['compat_publish'::text, 'legacy_snapshot'::text, 'manual'::text]))),
    CONSTRAINT sessions_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'locked'::text, 'published'::text, 'completed'::text, 'archived'::text])))
);


--
-- Name: tournament_groups; Type: TABLE; Schema: bm; Owner: -
--

CREATE TABLE bm.tournament_groups (
    tournament_id uuid NOT NULL,
    group_id text NOT NULL,
    pair_id uuid NOT NULL,
    "position" integer NOT NULL,
    CONSTRAINT tournament_groups_group_id_check CHECK ((group_id = ANY (ARRAY['A'::text, 'B'::text, 'C'::text, 'D'::text])))
);


--
-- Name: tournament_matches; Type: TABLE; Schema: bm; Owner: -
--

CREATE TABLE bm.tournament_matches (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tournament_id uuid NOT NULL,
    phase text NOT NULL,
    group_id text,
    pair_a_id uuid,
    pair_b_id uuid,
    score_a integer,
    score_b integer,
    pic_player_id uuid,
    match_order integer NOT NULL,
    match_key text NOT NULL,
    CONSTRAINT tournament_matches_group_id_check CHECK (((group_id IS NULL) OR (group_id = ANY (ARRAY['A'::text, 'B'::text, 'C'::text, 'D'::text])))),
    CONSTRAINT tournament_matches_phase_check CHECK ((phase = ANY (ARRAY['group'::text, 'qf'::text, 'sf'::text, '3rd'::text, 'final'::text]))),
    CONSTRAINT tournament_matches_score_a_check CHECK (((score_a IS NULL) OR (score_a >= 0))),
    CONSTRAINT tournament_matches_score_b_check CHECK (((score_b IS NULL) OR (score_b >= 0)))
);


--
-- Name: tournament_pair_players; Type: TABLE; Schema: bm; Owner: -
--

CREATE TABLE bm.tournament_pair_players (
    pair_id uuid NOT NULL,
    player_id uuid NOT NULL
);


--
-- Name: tournament_pairs; Type: TABLE; Schema: bm; Owner: -
--

CREATE TABLE bm.tournament_pairs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tournament_id uuid NOT NULL,
    pair_name text NOT NULL,
    seed integer NOT NULL
);


--
-- Name: tournament_team_match_games; Type: TABLE; Schema: bm; Owner: -
--

CREATE TABLE bm.tournament_team_match_games (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    team_match_id uuid NOT NULL,
    partai_index integer NOT NULL,
    score_a integer,
    score_b integer,
    CONSTRAINT tournament_team_match_games_partai_check CHECK ((partai_index = ANY (ARRAY[0, 1, 2]))),
    CONSTRAINT tournament_team_match_games_score_range_check CHECK (((score_a IS NULL) OR (((score_a >= 0) AND (score_a <= 99)) AND ((score_b >= 0) AND (score_b <= 99))))),
    CONSTRAINT tournament_team_match_games_scores_together_check CHECK (((score_a IS NULL) = (score_b IS NULL)))
);


--
-- Name: tournament_team_matches; Type: TABLE; Schema: bm; Owner: -
--

CREATE TABLE bm.tournament_team_matches (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tournament_id uuid NOT NULL,
    phase text NOT NULL,
    match_order integer NOT NULL,
    match_key text NOT NULL,
    team_a_id uuid,
    team_b_id uuid,
    courts text[] DEFAULT ARRAY['Court 1'::text, 'Court 2'::text, 'Court 3'::text],
    CONSTRAINT tournament_team_matches_phase_check CHECK ((phase = ANY (ARRAY['group'::text, 'final'::text])))
);


--
-- Name: tournament_team_players; Type: TABLE; Schema: bm; Owner: -
--

CREATE TABLE bm.tournament_team_players (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    team_id uuid NOT NULL,
    player_name text NOT NULL,
    player_id uuid,
    cls text NOT NULL,
    CONSTRAINT tournament_team_players_cls_check CHECK ((cls = ANY (ARRAY['A+'::text, 'A'::text, 'B+'::text, 'B'::text, 'C+'::text, 'C'::text])))
);


--
-- Name: tournament_teams; Type: TABLE; Schema: bm; Owner: -
--

CREATE TABLE bm.tournament_teams (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tournament_id uuid NOT NULL,
    seed integer NOT NULL,
    team_name text NOT NULL,
    CONSTRAINT tournament_teams_seed_check CHECK (((seed >= 1) AND (seed <= 6)))
);


--
-- Name: tournaments; Type: TABLE; Schema: bm; Owner: -
--

CREATE TABLE bm.tournaments (
    share_code text CONSTRAINT tournaments_id_not_null NOT NULL,
    name text DEFAULT ''::text NOT NULL,
    event_date date DEFAULT CURRENT_DATE NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    id uuid DEFAULT gen_random_uuid() CONSTRAINT tournaments_internal_id_not_null NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    format text DEFAULT 'classic'::text NOT NULL,
    CONSTRAINT bm_tournaments_share_code_not_blank_ck CHECK ((TRIM(BOTH FROM share_code) <> ''::text)),
    CONSTRAINT bm_tournaments_version_positive_ck CHECK ((version > 0)),
    CONSTRAINT tournaments_format_check CHECK ((format = ANY (ARRAY['classic'::text, 'team'::text])))
);


--
-- Name: outbox_events id; Type: DEFAULT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.outbox_events ALTER COLUMN id SET DEFAULT nextval('bm.outbox_events_id_seq'::regclass);


--
-- Name: rating_events seq; Type: DEFAULT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.rating_events ALTER COLUMN seq SET DEFAULT nextval('bm.rating_events_seq_seq'::regclass);


--
-- Name: fix_matches bm_fix_matches_internal_id_key; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.fix_matches
    ADD CONSTRAINT bm_fix_matches_internal_id_key UNIQUE (internal_id);


--
-- Name: fix_matches bm_fix_matches_session_internal_legacy_ref_key; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.fix_matches
    ADD CONSTRAINT bm_fix_matches_session_internal_legacy_ref_key UNIQUE (session_id, legacy_ref);


--
-- Name: fix_matches bm_fix_matches_session_internal_sort_order_key; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.fix_matches
    ADD CONSTRAINT bm_fix_matches_session_internal_sort_order_key UNIQUE (session_id, sort_order);


--
-- Name: scheduled_game_players bm_scheduled_game_players_game_internal_player_key; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.scheduled_game_players
    ADD CONSTRAINT bm_scheduled_game_players_game_internal_player_key UNIQUE (scheduled_game_internal_id, session_player_internal_id);


--
-- Name: scheduled_game_players bm_scheduled_game_players_game_internal_team_pos_key; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.scheduled_game_players
    ADD CONSTRAINT bm_scheduled_game_players_game_internal_team_pos_key UNIQUE (scheduled_game_internal_id, team, "position");


--
-- Name: scheduled_games bm_scheduled_games_internal_id_key; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.scheduled_games
    ADD CONSTRAINT bm_scheduled_games_internal_id_key UNIQUE (internal_id);


--
-- Name: scheduled_games bm_scheduled_games_session_internal_legacy_order_key; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.scheduled_games
    ADD CONSTRAINT bm_scheduled_games_session_internal_legacy_order_key UNIQUE (session_id, legacy_order);


--
-- Name: scheduled_games bm_scheduled_games_session_internal_slot_court_key; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.scheduled_games
    ADD CONSTRAINT bm_scheduled_games_session_internal_slot_court_key UNIQUE (session_id, slot_index, court_index);


--
-- Name: session_courts bm_session_courts_internal_id_key; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.session_courts
    ADD CONSTRAINT bm_session_courts_internal_id_key UNIQUE (internal_id);


--
-- Name: session_courts bm_session_courts_session_internal_court_key; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.session_courts
    ADD CONSTRAINT bm_session_courts_session_internal_court_key UNIQUE (session_id, court_index);


--
-- Name: session_players bm_session_players_internal_id_key; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.session_players
    ADD CONSTRAINT bm_session_players_internal_id_key UNIQUE (internal_id);


--
-- Name: session_players bm_session_players_session_internal_player_key; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.session_players
    ADD CONSTRAINT bm_session_players_session_internal_player_key UNIQUE (session_id, player_id);


--
-- Name: session_players bm_session_players_session_internal_player_ref_key; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.session_players
    ADD CONSTRAINT bm_session_players_session_internal_player_ref_key UNIQUE (session_id, player_ref);


--
-- Name: session_players bm_session_players_session_internal_sort_order_key; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.session_players
    ADD CONSTRAINT bm_session_players_session_internal_sort_order_key UNIQUE (session_id, sort_order);


--
-- Name: fix_matches fix_matches_pkey; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.fix_matches
    ADD CONSTRAINT fix_matches_pkey PRIMARY KEY (internal_id);


--
-- Name: idempotency_keys idempotency_keys_pkey; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.idempotency_keys
    ADD CONSTRAINT idempotency_keys_pkey PRIMARY KEY (session_id, key);


--
-- Name: outbox_events outbox_events_pkey; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.outbox_events
    ADD CONSTRAINT outbox_events_pkey PRIMARY KEY (id);


--
-- Name: player_achievements player_achievements_pkey; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.player_achievements
    ADD CONSTRAINT player_achievements_pkey PRIMARY KEY (id);


--
-- Name: player_achievements player_achievements_player_id_achievement_key_key; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.player_achievements
    ADD CONSTRAINT player_achievements_player_id_achievement_key_key UNIQUE (player_id, achievement_key);


--
-- Name: player_aliases player_aliases_pkey; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.player_aliases
    ADD CONSTRAINT player_aliases_pkey PRIMARY KEY (alias_name);


--
-- Name: players players_canonical_name_key; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.players
    ADD CONSTRAINT players_canonical_name_key UNIQUE (canonical_name);


--
-- Name: players players_pkey; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.players
    ADD CONSTRAINT players_pkey PRIMARY KEY (id);


--
-- Name: rank_point_levels rank_point_levels_pkey; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.rank_point_levels
    ADD CONSTRAINT rank_point_levels_pkey PRIMARY KEY (kind);


--
-- Name: rank_snapshots rank_snapshots_pkey; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.rank_snapshots
    ADD CONSTRAINT rank_snapshots_pkey PRIMARY KEY (as_of, player_id);


--
-- Name: rating_config rating_config_pkey; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.rating_config
    ADD CONSTRAINT rating_config_pkey PRIMARY KEY (key);


--
-- Name: rating_deltas rating_deltas_pkey; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.rating_deltas
    ADD CONSTRAINT rating_deltas_pkey PRIMARY KEY (event_id, player_id);


--
-- Name: rating_events rating_events_match_key_key; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.rating_events
    ADD CONSTRAINT rating_events_match_key_key UNIQUE (match_key);


--
-- Name: rating_events rating_events_order_uniq; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.rating_events
    ADD CONSTRAINT rating_events_order_uniq UNIQUE (date, created_at, source_id, game_order);


--
-- Name: rating_events rating_events_pkey; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.rating_events
    ADD CONSTRAINT rating_events_pkey PRIMARY KEY (id);


--
-- Name: rating_events rating_events_seq_key; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.rating_events
    ADD CONSTRAINT rating_events_seq_key UNIQUE (seq);


--
-- Name: rating_players rating_players_pkey; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.rating_players
    ADD CONSTRAINT rating_players_pkey PRIMARY KEY (player_id);


--
-- Name: rating_sources rating_sources_pkey; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.rating_sources
    ADD CONSTRAINT rating_sources_pkey PRIMARY KEY (source_id);


--
-- Name: scheduled_game_players scheduled_game_players_pkey; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.scheduled_game_players
    ADD CONSTRAINT scheduled_game_players_pkey PRIMARY KEY (internal_id);


--
-- Name: scheduled_games scheduled_games_pkey; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.scheduled_games
    ADD CONSTRAINT scheduled_games_pkey PRIMARY KEY (internal_id);


--
-- Name: session_courts session_courts_pkey; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.session_courts
    ADD CONSTRAINT session_courts_pkey PRIMARY KEY (internal_id);


--
-- Name: session_players session_players_pkey; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.session_players
    ADD CONSTRAINT session_players_pkey PRIMARY KEY (internal_id);


--
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);


--
-- Name: sessions sessions_share_code_key; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.sessions
    ADD CONSTRAINT sessions_share_code_key UNIQUE (share_code);


--
-- Name: tournament_groups tournament_groups_pkey; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournament_groups
    ADD CONSTRAINT tournament_groups_pkey PRIMARY KEY (tournament_id, group_id, pair_id);


--
-- Name: tournament_groups tournament_groups_tournament_id_group_id_position_key; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournament_groups
    ADD CONSTRAINT tournament_groups_tournament_id_group_id_position_key UNIQUE (tournament_id, group_id, "position");


--
-- Name: tournament_matches tournament_matches_pkey; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournament_matches
    ADD CONSTRAINT tournament_matches_pkey PRIMARY KEY (id);


--
-- Name: tournament_matches tournament_matches_tournament_id_match_key_key; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournament_matches
    ADD CONSTRAINT tournament_matches_tournament_id_match_key_key UNIQUE (tournament_id, match_key);


--
-- Name: tournament_pair_players tournament_pair_players_pkey; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournament_pair_players
    ADD CONSTRAINT tournament_pair_players_pkey PRIMARY KEY (pair_id, player_id);


--
-- Name: tournament_pairs tournament_pairs_pkey; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournament_pairs
    ADD CONSTRAINT tournament_pairs_pkey PRIMARY KEY (id);


--
-- Name: tournament_pairs tournament_pairs_tournament_id_seed_key; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournament_pairs
    ADD CONSTRAINT tournament_pairs_tournament_id_seed_key UNIQUE (tournament_id, seed);


--
-- Name: tournament_team_match_games tournament_team_match_games_pkey; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournament_team_match_games
    ADD CONSTRAINT tournament_team_match_games_pkey PRIMARY KEY (id);


--
-- Name: tournament_team_match_games tournament_team_match_games_unique; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournament_team_match_games
    ADD CONSTRAINT tournament_team_match_games_unique UNIQUE (team_match_id, partai_index);


--
-- Name: tournament_team_matches tournament_team_matches_key_unique; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournament_team_matches
    ADD CONSTRAINT tournament_team_matches_key_unique UNIQUE (tournament_id, match_key);


--
-- Name: tournament_team_matches tournament_team_matches_pkey; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournament_team_matches
    ADD CONSTRAINT tournament_team_matches_pkey PRIMARY KEY (id);


--
-- Name: tournament_team_players tournament_team_players_pkey; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournament_team_players
    ADD CONSTRAINT tournament_team_players_pkey PRIMARY KEY (id);


--
-- Name: tournament_team_players tournament_team_players_team_cls_unique; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournament_team_players
    ADD CONSTRAINT tournament_team_players_team_cls_unique UNIQUE (team_id, cls);


--
-- Name: tournament_teams tournament_teams_pkey; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournament_teams
    ADD CONSTRAINT tournament_teams_pkey PRIMARY KEY (id);


--
-- Name: tournament_teams tournament_teams_tournament_seed_unique; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournament_teams
    ADD CONSTRAINT tournament_teams_tournament_seed_unique UNIQUE (tournament_id, seed);


--
-- Name: tournaments tournaments_pkey; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournaments
    ADD CONSTRAINT tournaments_pkey PRIMARY KEY (id);


--
-- Name: tournaments tournaments_share_code_key; Type: CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournaments
    ADD CONSTRAINT tournaments_share_code_key UNIQUE (share_code);


--
-- Name: bm_player_aliases_player_id_idx; Type: INDEX; Schema: bm; Owner: -
--

CREATE INDEX bm_player_aliases_player_id_idx ON bm.player_aliases USING btree (player_id);


--
-- Name: bm_scheduled_game_players_game_internal_id_idx; Type: INDEX; Schema: bm; Owner: -
--

CREATE INDEX bm_scheduled_game_players_game_internal_id_idx ON bm.scheduled_game_players USING btree (scheduled_game_internal_id);


--
-- Name: bm_scheduled_game_players_session_player_game_idx; Type: INDEX; Schema: bm; Owner: -
--

CREATE INDEX bm_scheduled_game_players_session_player_game_idx ON bm.scheduled_game_players USING btree (session_player_internal_id, scheduled_game_internal_id);


--
-- Name: bm_scheduled_games_session_internal_slot_court_idx; Type: INDEX; Schema: bm; Owner: -
--

CREATE INDEX bm_scheduled_games_session_internal_slot_court_idx ON bm.scheduled_games USING btree (session_id, slot_index, court_index);


--
-- Name: bm_session_courts_session_internal_court_idx; Type: INDEX; Schema: bm; Owner: -
--

CREATE INDEX bm_session_courts_session_internal_court_idx ON bm.session_courts USING btree (session_id, court_index);


--
-- Name: bm_session_players_player_id_idx; Type: INDEX; Schema: bm; Owner: -
--

CREATE INDEX bm_session_players_player_id_idx ON bm.session_players USING btree (player_id);


--
-- Name: bm_session_players_player_session_recent_idx; Type: INDEX; Schema: bm; Owner: -
--

CREATE INDEX bm_session_players_player_session_recent_idx ON bm.session_players USING btree (player_id, session_id, updated_at DESC, internal_id DESC);


--
-- Name: bm_session_players_session_internal_player_ref_idx; Type: INDEX; Schema: bm; Owner: -
--

CREATE INDEX bm_session_players_session_internal_player_ref_idx ON bm.session_players USING btree (session_id, player_ref);


--
-- Name: bm_sessions_session_date_idx; Type: INDEX; Schema: bm; Owner: -
--

CREATE INDEX bm_sessions_session_date_idx ON bm.sessions USING btree (session_date DESC);


--
-- Name: bm_sessions_updated_at_idx; Type: INDEX; Schema: bm; Owner: -
--

CREATE INDEX bm_sessions_updated_at_idx ON bm.sessions USING btree (updated_at DESC);


--
-- Name: bm_tournaments_event_date_idx; Type: INDEX; Schema: bm; Owner: -
--

CREATE INDEX bm_tournaments_event_date_idx ON bm.tournaments USING btree (event_date DESC);


--
-- Name: bm_tournaments_updated_at_idx; Type: INDEX; Schema: bm; Owner: -
--

CREATE INDEX bm_tournaments_updated_at_idx ON bm.tournaments USING btree (updated_at DESC);


--
-- Name: idx_idempotency_keys_expires_at; Type: INDEX; Schema: bm; Owner: -
--

CREATE INDEX idx_idempotency_keys_expires_at ON bm.idempotency_keys USING btree (expires_at);


--
-- Name: idx_outbox_events_session_id_id; Type: INDEX; Schema: bm; Owner: -
--

CREATE INDEX idx_outbox_events_session_id_id ON bm.outbox_events USING btree (session_id, id);


--
-- Name: idx_player_achievements_kind; Type: INDEX; Schema: bm; Owner: -
--

CREATE INDEX idx_player_achievements_kind ON bm.player_achievements USING btree (kind);


--
-- Name: idx_player_achievements_player; Type: INDEX; Schema: bm; Owner: -
--

CREATE INDEX idx_player_achievements_player ON bm.player_achievements USING btree (player_id, earned_at DESC);


--
-- Name: idx_rank_snapshots_as_of_rank; Type: INDEX; Schema: bm; Owner: -
--

CREATE INDEX idx_rank_snapshots_as_of_rank ON bm.rank_snapshots USING btree (as_of, rank);


--
-- Name: idx_rating_deltas_player_event; Type: INDEX; Schema: bm; Owner: -
--

CREATE INDEX idx_rating_deltas_player_event ON bm.rating_deltas USING btree (player_id, event_id);


--
-- Name: idx_rating_events_sort_lookup; Type: INDEX; Schema: bm; Owner: -
--

CREATE INDEX idx_rating_events_sort_lookup ON bm.rating_events USING btree (id, date DESC, created_at DESC, source_id DESC, game_order DESC);


--
-- Name: idx_rating_players_active; Type: INDEX; Schema: bm; Owner: -
--

CREATE INDEX idx_rating_players_active ON bm.rating_players USING btree (games_played, last_played_at) WHERE (games_played > 0);


--
-- Name: idx_scheduled_games_session; Type: INDEX; Schema: bm; Owner: -
--

CREATE INDEX idx_scheduled_games_session ON bm.scheduled_games USING btree (session_id);


--
-- Name: idx_session_players_session_player; Type: INDEX; Schema: bm; Owner: -
--

CREATE INDEX idx_session_players_session_player ON bm.session_players USING btree (session_id, player_id);


--
-- Name: rating_deltas_player_idx; Type: INDEX; Schema: bm; Owner: -
--

CREATE INDEX rating_deltas_player_idx ON bm.rating_deltas USING btree (player_id, event_id);


--
-- Name: rating_events_match_key_idx; Type: INDEX; Schema: bm; Owner: -
--

CREATE UNIQUE INDEX rating_events_match_key_idx ON bm.rating_events USING btree (match_key);


--
-- Name: rating_events_seq_idx; Type: INDEX; Schema: bm; Owner: -
--

CREATE UNIQUE INDEX rating_events_seq_idx ON bm.rating_events USING btree (seq);


--
-- Name: rating_events_source_idx; Type: INDEX; Schema: bm; Owner: -
--

CREATE INDEX rating_events_source_idx ON bm.rating_events USING btree (source_id);


--
-- Name: fix_matches bm_fix_matches_set_updated_at; Type: TRIGGER; Schema: bm; Owner: -
--

CREATE TRIGGER bm_fix_matches_set_updated_at BEFORE UPDATE ON bm.fix_matches FOR EACH ROW EXECUTE FUNCTION bm.set_updated_at();


--
-- Name: players bm_players_set_updated_at; Type: TRIGGER; Schema: bm; Owner: -
--

CREATE TRIGGER bm_players_set_updated_at BEFORE UPDATE ON bm.players FOR EACH ROW EXECUTE FUNCTION bm.set_updated_at();


--
-- Name: scheduled_games bm_scheduled_games_set_updated_at; Type: TRIGGER; Schema: bm; Owner: -
--

CREATE TRIGGER bm_scheduled_games_set_updated_at BEFORE UPDATE ON bm.scheduled_games FOR EACH ROW EXECUTE FUNCTION bm.set_updated_at();


--
-- Name: session_players bm_session_players_set_updated_at; Type: TRIGGER; Schema: bm; Owner: -
--

CREATE TRIGGER bm_session_players_set_updated_at BEFORE UPDATE ON bm.session_players FOR EACH ROW EXECUTE FUNCTION bm.set_updated_at();


--
-- Name: sessions bm_sessions_set_updated_at; Type: TRIGGER; Schema: bm; Owner: -
--

CREATE TRIGGER bm_sessions_set_updated_at BEFORE UPDATE ON bm.sessions FOR EACH ROW EXECUTE FUNCTION bm.set_updated_at();


--
-- Name: tournaments bm_tournaments_set_updated_at; Type: TRIGGER; Schema: bm; Owner: -
--

CREATE TRIGGER bm_tournaments_set_updated_at BEFORE UPDATE ON bm.tournaments FOR EACH ROW EXECUTE FUNCTION bm.set_updated_at();


--
-- Name: fix_matches bm_fix_matches_session_id_fk; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.fix_matches
    ADD CONSTRAINT bm_fix_matches_session_id_fk FOREIGN KEY (session_id) REFERENCES bm.sessions(id) ON DELETE CASCADE;


--
-- Name: scheduled_game_players bm_scheduled_game_players_game_internal_fk; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.scheduled_game_players
    ADD CONSTRAINT bm_scheduled_game_players_game_internal_fk FOREIGN KEY (scheduled_game_internal_id) REFERENCES bm.scheduled_games(internal_id) ON DELETE CASCADE;


--
-- Name: scheduled_game_players bm_scheduled_game_players_session_player_internal_fk; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.scheduled_game_players
    ADD CONSTRAINT bm_scheduled_game_players_session_player_internal_fk FOREIGN KEY (session_player_internal_id) REFERENCES bm.session_players(internal_id) ON DELETE CASCADE;


--
-- Name: scheduled_games bm_scheduled_games_session_id_fk; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.scheduled_games
    ADD CONSTRAINT bm_scheduled_games_session_id_fk FOREIGN KEY (session_id) REFERENCES bm.sessions(id) ON DELETE CASCADE;


--
-- Name: session_courts bm_session_courts_session_id_fk; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.session_courts
    ADD CONSTRAINT bm_session_courts_session_id_fk FOREIGN KEY (session_id) REFERENCES bm.sessions(id) ON DELETE CASCADE;


--
-- Name: session_players bm_session_players_session_id_fk; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.session_players
    ADD CONSTRAINT bm_session_players_session_id_fk FOREIGN KEY (session_id) REFERENCES bm.sessions(id) ON DELETE CASCADE;


--
-- Name: fix_matches fix_matches_slot_0_fkey; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.fix_matches
    ADD CONSTRAINT fix_matches_slot_0_fkey FOREIGN KEY (slot_0) REFERENCES bm.session_players(internal_id) ON DELETE SET NULL;


--
-- Name: fix_matches fix_matches_slot_1_fkey; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.fix_matches
    ADD CONSTRAINT fix_matches_slot_1_fkey FOREIGN KEY (slot_1) REFERENCES bm.session_players(internal_id) ON DELETE SET NULL;


--
-- Name: fix_matches fix_matches_slot_2_fkey; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.fix_matches
    ADD CONSTRAINT fix_matches_slot_2_fkey FOREIGN KEY (slot_2) REFERENCES bm.session_players(internal_id) ON DELETE SET NULL;


--
-- Name: fix_matches fix_matches_slot_3_fkey; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.fix_matches
    ADD CONSTRAINT fix_matches_slot_3_fkey FOREIGN KEY (slot_3) REFERENCES bm.session_players(internal_id) ON DELETE SET NULL;


--
-- Name: idempotency_keys idempotency_keys_session_id_fkey; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.idempotency_keys
    ADD CONSTRAINT idempotency_keys_session_id_fkey FOREIGN KEY (session_id) REFERENCES bm.sessions(id) ON DELETE CASCADE;


--
-- Name: outbox_events outbox_events_session_id_fkey; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.outbox_events
    ADD CONSTRAINT outbox_events_session_id_fkey FOREIGN KEY (session_id) REFERENCES bm.sessions(id) ON DELETE CASCADE;


--
-- Name: player_achievements player_achievements_player_id_fkey; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.player_achievements
    ADD CONSTRAINT player_achievements_player_id_fkey FOREIGN KEY (player_id) REFERENCES bm.players(id) ON DELETE CASCADE;


--
-- Name: player_aliases player_aliases_player_id_fkey; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.player_aliases
    ADD CONSTRAINT player_aliases_player_id_fkey FOREIGN KEY (player_id) REFERENCES bm.players(id) ON DELETE CASCADE;


--
-- Name: rank_snapshots rank_snapshots_player_id_fkey; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.rank_snapshots
    ADD CONSTRAINT rank_snapshots_player_id_fkey FOREIGN KEY (player_id) REFERENCES bm.players(id) ON DELETE CASCADE;


--
-- Name: rating_deltas rating_deltas_event_id_fkey; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.rating_deltas
    ADD CONSTRAINT rating_deltas_event_id_fkey FOREIGN KEY (event_id) REFERENCES bm.rating_events(id) ON DELETE CASCADE;


--
-- Name: rating_deltas rating_deltas_player_id_fkey; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.rating_deltas
    ADD CONSTRAINT rating_deltas_player_id_fkey FOREIGN KEY (player_id) REFERENCES bm.players(id);


--
-- Name: rating_players rating_players_player_id_fkey; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.rating_players
    ADD CONSTRAINT rating_players_player_id_fkey FOREIGN KEY (player_id) REFERENCES bm.players(id);


--
-- Name: session_players session_players_player_id_fkey; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.session_players
    ADD CONSTRAINT session_players_player_id_fkey FOREIGN KEY (player_id) REFERENCES bm.players(id);


--
-- Name: tournament_groups tournament_groups_pair_id_fkey; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournament_groups
    ADD CONSTRAINT tournament_groups_pair_id_fkey FOREIGN KEY (pair_id) REFERENCES bm.tournament_pairs(id) ON DELETE CASCADE;


--
-- Name: tournament_groups tournament_groups_tournament_id_fkey; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournament_groups
    ADD CONSTRAINT tournament_groups_tournament_id_fkey FOREIGN KEY (tournament_id) REFERENCES bm.tournaments(id) ON DELETE CASCADE;


--
-- Name: tournament_matches tournament_matches_pair_a_id_fkey; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournament_matches
    ADD CONSTRAINT tournament_matches_pair_a_id_fkey FOREIGN KEY (pair_a_id) REFERENCES bm.tournament_pairs(id);


--
-- Name: tournament_matches tournament_matches_pair_b_id_fkey; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournament_matches
    ADD CONSTRAINT tournament_matches_pair_b_id_fkey FOREIGN KEY (pair_b_id) REFERENCES bm.tournament_pairs(id);


--
-- Name: tournament_matches tournament_matches_pic_player_id_fkey; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournament_matches
    ADD CONSTRAINT tournament_matches_pic_player_id_fkey FOREIGN KEY (pic_player_id) REFERENCES bm.players(id);


--
-- Name: tournament_matches tournament_matches_tournament_id_fkey; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournament_matches
    ADD CONSTRAINT tournament_matches_tournament_id_fkey FOREIGN KEY (tournament_id) REFERENCES bm.tournaments(id) ON DELETE CASCADE;


--
-- Name: tournament_pair_players tournament_pair_players_pair_id_fkey; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournament_pair_players
    ADD CONSTRAINT tournament_pair_players_pair_id_fkey FOREIGN KEY (pair_id) REFERENCES bm.tournament_pairs(id) ON DELETE CASCADE;


--
-- Name: tournament_pair_players tournament_pair_players_player_id_fkey; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournament_pair_players
    ADD CONSTRAINT tournament_pair_players_player_id_fkey FOREIGN KEY (player_id) REFERENCES bm.players(id) ON DELETE RESTRICT;


--
-- Name: tournament_pairs tournament_pairs_tournament_id_fkey; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournament_pairs
    ADD CONSTRAINT tournament_pairs_tournament_id_fkey FOREIGN KEY (tournament_id) REFERENCES bm.tournaments(id) ON DELETE CASCADE;


--
-- Name: tournament_team_match_games tournament_team_match_games_match_fk; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournament_team_match_games
    ADD CONSTRAINT tournament_team_match_games_match_fk FOREIGN KEY (team_match_id) REFERENCES bm.tournament_team_matches(id) ON DELETE CASCADE;


--
-- Name: tournament_team_matches tournament_team_matches_a_fk; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournament_team_matches
    ADD CONSTRAINT tournament_team_matches_a_fk FOREIGN KEY (team_a_id) REFERENCES bm.tournament_teams(id) ON DELETE SET NULL;


--
-- Name: tournament_team_matches tournament_team_matches_b_fk; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournament_team_matches
    ADD CONSTRAINT tournament_team_matches_b_fk FOREIGN KEY (team_b_id) REFERENCES bm.tournament_teams(id) ON DELETE SET NULL;


--
-- Name: tournament_team_matches tournament_team_matches_tournament_fk; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournament_team_matches
    ADD CONSTRAINT tournament_team_matches_tournament_fk FOREIGN KEY (tournament_id) REFERENCES bm.tournaments(id) ON DELETE CASCADE;


--
-- Name: tournament_team_players tournament_team_players_player_fk; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournament_team_players
    ADD CONSTRAINT tournament_team_players_player_fk FOREIGN KEY (player_id) REFERENCES bm.players(id) ON DELETE SET NULL;


--
-- Name: tournament_team_players tournament_team_players_team_fk; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournament_team_players
    ADD CONSTRAINT tournament_team_players_team_fk FOREIGN KEY (team_id) REFERENCES bm.tournament_teams(id) ON DELETE CASCADE;


--
-- Name: tournament_teams tournament_teams_tournament_fk; Type: FK CONSTRAINT; Schema: bm; Owner: -
--

ALTER TABLE ONLY bm.tournament_teams
    ADD CONSTRAINT tournament_teams_tournament_fk FOREIGN KEY (tournament_id) REFERENCES bm.tournaments(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict mwTE15JZPGuJDPUTPSQnrORGa96Y5goe8JhnSsswcN3uzOfqvVsuVJTJayMwGUy

