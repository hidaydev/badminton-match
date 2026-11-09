-- Sanitized, production-shaped v1 fixture for the bulk import case (QA-10).
--
-- The local fixture is 12 players and 8 games. Production had 104 players and
-- more than a thousand games, with unicode names, a null tier and legacy rows
-- the synthetic set does not model. This file is deterministic: every
-- identifier is md5 of a fixed label, every name is invented, and no value came
-- from the production dump.
--
--   104 players, 130 draft sessions, 1,040 scheduled games.
--
-- Load it into a dedicated scratch database after ops/dev/v1/schema.sql:
--
--   psql -v ON_ERROR_STOP=1 -q -d "$DSN" -f ops/dev/v1/schema.sql
--   psql -v ON_ERROR_STOP=1 -q -d "$DSN" -f testdata/import/production-shaped.sql

begin;

do $$
declare
  names text[] := array[
    'Ánandá', 'Bùdí', 'Chándrá', 'Dèwi', 'Éka', 'Fajar', 'Gita', 'Hadi',
    'Indra', 'Jaka', 'Kartika', 'Lina', 'Made', 'Nadia', 'Oki', 'Putri',
    'Raka', 'Sari', 'Tono', 'Umi', 'Vino', 'Wulan', 'Yoga', 'Zaki',
    '李明', 'さくら', 'Иван', 'Zoë', 'Þór', 'Məryəm'
  ];
  tiers text[] := array['D', 'D+', 'C', 'C+', 'B', 'B+', 'A', 'A+'];
  i int;
  k int;
  g int;
  sid uuid;
  gid uuid;
  stamp timestamptz;
begin
  for i in 1 .. 104 loop
    stamp := timestamptz '2025-01-01 00:00:00+00' + (i || ' days')::interval;
    insert into bm.players (id, canonical_name, created_at, updated_at, tier,
                            registered_at, gender)
    values (
      md5('bulk-player-' || i)::uuid,
      names[1 + (i % array_length(names, 1))] || ' ' || i,
      stamp,
      stamp + interval '5 minutes',
      case when i % 7 = 0 then null else tiers[1 + (i % array_length(tiers, 1))] end,
      date '2025-01-01' + i,
      case when i % 2 = 0 then 'F' else 'M' end
    );
  end loop;

  for i in 1 .. 130 loop
    sid := md5('bulk-session-' || i)::uuid;
    stamp := timestamptz '2026-01-01 00:00:00+00' + (i || ' days')::interval;
    insert into bm.sessions (id, share_code, title, session_date,
                             session_start, slot_minutes, status, source,
                             created_at, updated_at, session_tier_count,
                             include_absent_players, include_tier_count, version)
    values (
      sid,
      'bulk-' || lpad(i::text, 4, '0'),
      'Bulk Session ' || i,
      date '2026-01-01' + (i % 300),
      '19:00',
      30,
      'draft',
      'manual',
      stamp,
      stamp + interval '1 hour',
      8,
      false,
      false,
      1
    );

    for k in 0 .. 7 loop
      insert into bm.session_players (player_id, player_ref, source_name,
                                      sort_order, gender, tier, session_id,
                                      internal_id, created_at, updated_at)
      select p.id, 'p' || (k + 1), p.canonical_name, k, p.gender,
             1 + ((i + k) % 8), sid, md5('bulk-sp-' || i || '-' || k)::uuid,
             stamp, stamp
      from bm.players p
      where p.id = md5('bulk-player-' ||
        (1 + (((i - 1) * 8 + k) % 104)))::uuid;
    end loop;

    for g in 0 .. 7 loop
      gid := md5('bulk-game-' || i || '-' || g)::uuid;
      insert into bm.scheduled_games (slot_index, court_index, status, source,
                                      created_at, updated_at, legacy_order,
                                      session_id, internal_id, is_played,
                                      played_order, score_a, score_b)
      values (
        g / 2,
        g % 2,
        case when g < 6 then 'played' else 'scheduled' end,
        'generator',
        stamp,
        stamp,
        g + 1,
        sid,
        gid,
        g < 6,
        case when g < 6 then g + 1 else null end,
        case when g < 6 then 21 else null end,
        case when g < 6 then 18 else null end
      );
      for k in 0 .. 3 loop
        insert into bm.scheduled_game_players (team, "position",
                                               scheduled_game_internal_id,
                                               session_player_internal_id,
                                               internal_id)
        values (
          case when k < 2 then 'A' else 'B' end,
          k % 2,
          gid,
          md5('bulk-sp-' || i || '-' || ((g * 4 + k) % 8))::uuid,
          md5('bulk-gp-' || i || '-' || g || '-' || k)::uuid
        );
      end loop;
    end loop;
  end loop;
end $$;

commit;
