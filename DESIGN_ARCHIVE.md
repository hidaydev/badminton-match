# DESIGN_ARCHIVE.md — Arsip Keputusan Desain (semua sudah diimplementasi)

**Dibuat:** 2026-08-19 (konsolidasi)
**Tujuan:** satu dokumen ringkas berisi keputusan desain dari 8 dokumen yang
sudah diimplementasi. Detail lengkap tersedia di git history
(`git log --all -- <file>`).
**Konvensi:** sesuai `docs/README.md` — dokumen yang obsolete dihapus dari root;
arsip ini jadi referensi keputusan.

| # | Subjek | Dokumen asli | Status |
|---|---|---|---|
| 1 | Engine rating (Glicko-1-lite) | `RATING_ENGINE_DESIGN.md` | ✅ Diimplementasi & deployed |
| 2 | Tiering 12-band + tier induk | `RATING_TIERING_REVAMP.md` | ⚠️ Superseded oleh 8-tier (#6) |
| 3 | Frontend ratings | `RATINGS_FRONTEND_PLAN.md` | ✅ Diimplementasi |
| 4 | Admin menu | `ADMIN_MENU_PLAN.md` | ✅ Diimplementasi (evolusi di #6/#7) |
| 5 | Absent / TBD / void | `ABSENT_TBD_PLAYERS_DESIGN.md` | ✅ Diimplementasi |
| 6 | **8-tier unifikasi** | `TIER_8_UNIFICATION.md` | ✅ Aktif (desain terkini) |
| 7 | UI/UX polish (i18n, admin home, history merge) | `UI_UX_POLISH_PLAN.md` | ✅ Diimplementasi |
| 8 | Kajian backlog | `BACKLOG_ANALYSIS.md` | ✅ Konsumsi — status di `BACKLOG.md` |

---

## 1. Engine Rating — Glicko-1-lite (server-authoritative)

- **Prinsip:** server authoritative, atomic (all-or-nothing), idempotent
  (match_key + fingerprint), fair (RD uncertainty, bukan K-tier), deterministik
  (basis tanggal sumber), auditable (rating_deltas).
- **Model:** Glicko-1 per-match (tanpa rating period). `r0=1250 · rd0=220 ·
  rd_min=30 · rd_max=350 · rd_growth=3/hari · max_delta=30 · clamp [1000,2500]`.
- **MoVM** = min(2.0, 0.5 + |skorA−skorB|/target) — simetris, di-cap.
- **Phase weight:** classic group 1.0 · qf 1.05 · sf 1.15 · 3rd 1.0 · final 1.25;
  team group 1.0 · final 1.25 (tersimpan di rating_events → replay konsisten).
- **Team format:** positional pairing (counterpart kelas sama), bukan team-average.
- **match_key** = hash(kind|source_id|stable_game_id|players|skor|target|phase|order);
  sesi pakai `legacy_order` (di-capture saat ingest).
- **Ordering/seq:** (date, created_at sumber, source_id, game_order); invariant
  out-of-order → 409.
- **Fingerprint:** `rating_sources.fingerprint`; edit sumber setelah ingest →
  409 `source_changed`; jalur perbaikan = revert + re-ingest (auto_reconcile opsional).
- **FULL REBUILD** setelah revert/reconcile (transitivitas) — rating_players
  TIDAK PERNAH disimpan dari incremental tanpa rebuild penuh.
- **Concurrency:** advisory lock global `{schema}:ratings_ingest` + lock player
  sorted + REPEATABLE READ.
- **Revert/Rebuild/Season/DeleteSession/DeletePlayer:** commit lalu RebuildAll
  (temuan audit: DeletePlayer sudah di-fix 2026-08-19).
- **Auto-ingest:** ticker 30 mnt (sesi locked & belum diingest, urut kronologis);
  auto-lock sesi yang tanggalnya lewat.
- **Config:** `rating_config` (19+ key, typed loader, fail-fast prod).
- File kunci: `majadu-api/internal/{domain/rating.go, store/rating*.go, handler/ratings.go}`.

## 2. Tiering 12-band + Tier Induk — SUPERSEDED oleh 8-tier

- Desain lama: tier induk sticky `players.tier` (A-D, first-set saat registrasi) +
  `rating_players.class` 12-band (D-..A+) + `class_source` + floor minus-huruf +
  season (`season_start`, arsip `season_player_snapshots`) + journey
  `registered_at`.
- **Digantikan penuh oleh #6** (unifikasi 8-tier). Jangan dihidupkan kembali.

## 3. Frontend Ratings

- `/ratings` leaderboard (podium, provisional `rd>200`, trend, pagination
  load-more, season picker live/frozen) + `/ratings/:playerId` (stat cards,
  sparkline SVG manual, recent matches).
- Cross-link dua arah dengan Player History — **DIPERLUAS di #7**: history
  diserap penuh ke `/ratings/:playerId` (Career).
- Auto-ingest tanpa tombol UI (ticker backend).

## 4. Admin Menu

- Login via password (`MAJADU_ADMIN_TOKEN`, Bearer, localStorage persist).
- Endpoint admin: ingest/revert/finalize/rebuild-all/season/tier/class/rename/
  delete player/delete session/delete tournament (semua AdminGuard).
- **Evolusi #7:** admin tidak lagi halaman terpisah yang "dibuka" dari home —
  card Admin = trigger login/logout; section ADMIN (grid card menu) muncul di
  home; `/admin?section=X` autofocus.

## 5. Absent / TBD / Void

- **Void game:** memuat ≥1 pemain absent/placeholder → tidak dihitung siapa pun
  (standings, career stats, rating `absent_policy=skip_game`).
- **Placeholder:** pola nama (free/tbd/default/xxx/unknown/kosong/belum ada/?+)
  → tidak pernah diregistrasi (`IsPlaceholderName`, read-time filter).
- **Rating placeholder:** `placeholder_policy=rate_as_unknown` (1250/rd350,
  tidak dipersist).
- **Auto-lock:** sesi draft yang tanggalnya lewat → locked (ticker 30 mnt) =
  gate final data + auto-ingest rating.
- **Fingerprint memuat SEMUA game termasuk void** — edit setelah ingest tetap
  terdeteksi.

## 6. 8-Tier Unifikasi — DESAIN AKTIF (2026-08-19)

- **Single source of truth:** `players.tier` (8: D, D+, C, C+, B, B+, A, A+).
  `rating_players.class/class_source` DROP (migration `000011`).
- **Bands** (collapse 12→8, grid 100): D ≤1199 · D+ 1200-1299 · C 1300-1499 ·
  C+ 1500-1599 · B 1600-1799 · B+ 1800-1899 · A 1900-2099 · A+ ≥2100.
- **Forming letter TIDAK berubah** (1150/1450/1750/2050 + D+/C+/B+/A+ =
  1250/1550/1850/2150) → RebuildAll IDENTIK (0 rating berubah, terverifikasi).
- **Floor = basis huruf:** B+ floor B (boleh naik A/A+); A+/A→A, dst.
  API: `tier`/`tier_derived`/`tier_display`.
- **Generator 8-level:** tierMap 1-8 (D=1..A+=8), DEFAULT_TIER=5, weight 2;
  threshold unevenGames diskala 2→4. Trade-off: pool kecil sebaran lebar
  (8P-2C) pass-rate turun — struktural.
- **Migration `000011`**: applied bm_dev (2026-08-19) + bm (schema sync, kosong).
- File kunci: `src/config/{tiers.ts,ratingTiers.ts,generator.ts}` ·
  `majadu-api/internal/domain/rating_config.go`.

## 7. UI/UX Polish (2026-08-19)

- **Bahasa:** English semua string user-facing + **skeleton i18n**
  (`src/i18n/en.ts` typed dict + `t()`/`useT()`, zero deps; tanpa language
  switcher).
- **Home admin trigger:** card Admin Area = login popup / logout (konfirmasi,
  styling amber) · section **ADMIN permanen** (grid 5 card:
  Unlock Session/Players/Ratings/Tournament/Season) di bawah App →
  `/admin?section=X`.
- **AdminPage:** urutan Session→Player→Rating→Tournament→Season · autofocus
  `?section` (tanpa collapsible) · player pagination + search · season meta
  wrap · baris aksi flex-wrap.
- **Player History diserap** ke `/ratings/:playerId` (section Career dari
  `getPlayerStats(name)`) — route `/player-history*` DIHAPUS, tanpa cross-link
  nested; design token diseragamkan.
- **Mobile audit:** flex-wrap di team standings, match detail, baris admin.

## 8. Kajian Backlog

- Analisis detail (A5/A6/A10-A13/B/O3/O6) sudah dikonsumsi: A5 (rename player),
  A10 (rebaseline), B (stale checkbox), O3 (M-DEF pensiun) SELESAI; A11/A12/A13/
  O6 drop; A6 ditunda. Status hidup ada di `BACKLOG.md`.

---

## Referensi

- Backlog aktif & status: `BACKLOG.md`
- Rencana tes end-to-end: `E2E_TESTING_PLAN.md`
- Schema DB & arsitektur: `docs/handbook/`
- Detail asli tiap dokumen: git history (`git log --all -- RATING_ENGINE_DESIGN.md`, dst.)
