-- =============================================================================
-- 000020 — Purge peninggalan Glicko & musim
--
--   Mesin Glicko dipensiunkan 2026-09-29. Setelah itu:
--     - rating tidak lagi dihitung (rating_deltas hanya menyimpan fakta
--       pertandingan: event_id/player_id/team/outcome — bahan baku papan poin),
--     - konsep musim ikut pensiun (papan poin memakai window 12 minggu,
--       bukan musim),
--     - medal "Peak Rating" dan "season_member" tidak bisa lahir lagi.
--
--   Migration ini membuang kolom/tabel/baris yang hanya bermakna di era itu.
--   TIDAK ada pembaca yang tersisa di kode: diverifikasi lewat grep sebelum
--   drop (peninggalan mesin Glicko dihapus dari rating.go, rating_revert.go,
--   rating_read.go, achievement.go, domain/rating_config.go).
--
--   Yang DIPERTAHANKAN di rating_players (masih dibaca):
--     games_played, wins, losses, last_played_at — bookkeeping pertandingan
--     yang dipakai halaman stats & medal volume.
--
--   Urutan penting: hapus baris achievement dulu (kolom season_id menunjuk
--   rating_seasons), baru drop tabelnya.
-- =============================================================================
BEGIN;

-- ── 1) Baris achievement yang kehilangan makna ──────────────────────────────
-- medal:rating — ambang 2000, mustahil dicapai tanpa mesin rating.
-- season_member:* — badge keanggotaan musim; konsep musim sudah pensiun.
DELETE FROM bm.player_achievements
 WHERE achievement_key = 'medal:rating'
    OR achievement_key LIKE 'season_member:%';

-- ── 1b) Kolom season_id di player_achievements ─────────────────────────────
-- Tidak ada lagi badge yang terikat musim. Kolom ini juga yang menahan
-- rating_seasons lewat FK, jadi harus dilepas sebelum tabelnya di-drop.
ALTER TABLE bm.player_achievements DROP COLUMN IF EXISTS season_id;

-- ── 2) Kolom angka Glicko di rating_deltas ─────────────────────────────────
-- Yang tersisa hanya fakta pertandingan (event_id/player_id/team/outcome).
ALTER TABLE bm.rating_deltas
  DROP COLUMN IF EXISTS expected,
  DROP COLUMN IF EXISTS movm,
  DROP COLUMN IF EXISTS delta,
  DROP COLUMN IF EXISTS new_rating;

-- ── 3) phase_weight di rating_events ───────────────────────────────────────
-- Dulu pengali bobot fase untuk rumus Glicko; poin turnamen kini memakai
-- champion_points x rasio hasil (RANKING_POIN_BWF_RANCANGAN.md §4.4).
ALTER TABLE bm.rating_events
  DROP COLUMN IF EXISTS phase_weight;

-- ── 4) Kolom rating & benih musim di rating_players ────────────────────────
-- rating/rd/peak_rating: hasil hitung Glicko.
-- seed_rating/seed_rd/seed_set_at: benih awal musim (CloseAndStartSeason).
ALTER TABLE bm.rating_players
  DROP COLUMN IF EXISTS rating,
  DROP COLUMN IF EXISTS rd,
  DROP COLUMN IF EXISTS peak_rating,
  DROP COLUMN IF EXISTS seed_rating,
  DROP COLUMN IF EXISTS seed_rd,
  DROP COLUMN IF EXISTS seed_set_at;

-- ── 5) Tabel musim ─────────────────────────────────────────────────────────
-- season_player_snapshots lebih dulu (FK ke rating_seasons).
DROP TABLE IF EXISTS bm.season_player_snapshots;
DROP TABLE IF EXISTS bm.rating_seasons;

-- ── 6) Config yang tidak lagi dibaca ───────────────────────────────────────
-- phase_weights: dulu pengali per fase; validasi & pembacanya sudah dihapus.
DELETE FROM bm.rating_config WHERE key = 'phase_weights';

-- ── 7) merge_players: buang langkah tabel musim ────────────────────────────
-- Fungsi ini masih memindahkan season_player_snapshots; tabelnya sudah di-drop
-- di langkah 5 sehingga merge akan error. Diganti dengan rank_snapshots (tabel
-- posisi papan yang menggantikan peran snapshot musim) supaya riwayat posisi
-- pemain source tidak ikut terhapus oleh ON DELETE CASCADE.
CREATE OR REPLACE FUNCTION bm.merge_players(p_target uuid, p_source uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'bm', 'public'
AS $function$
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
$function$;

COMMIT;
