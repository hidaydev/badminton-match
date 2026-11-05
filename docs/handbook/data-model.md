# Data Model — Single Source of Truth

Dokumen ini adalah sumber kebenaran untuk **database v2** (`bm2`) dan bentuk data yang
dipakai API. Semua isi di bawah berasal dari file migrasi di repo — tidak ada klaim dari
dump VPS atau skema v1.

- Migrasi: `db/migrations/0001_core.sql` … `0024_config_version_bump.sql` (24 file;
  `0023` adalah yang terakhir).
- Seed: `db/seeds/platform_config.sql`, `db/seeds/achievement_definitions.sql`.
- Ledger: `tools/dbtools/main.nim:6-16` membuat `dbtools.schema_migrations` dan
  `dbtools.seed_files` (checksum per file).
- Nama database `bm2_dev`/`bm2_e2e` berasal dari tooling, bukan dari SQL:
  `.github/workflows/ci.yml`, `task.d/e2e.sh`.

Tidak ada skema `bm`, tabel snapshot JSON, `scheduled_games`, atau `rating_events` v1 di
v2. Nama-nama itu hanya ada di [`../backend/`](../backend/README.md) (arsip migrasi v1).

## 1. Aturan umum

1. **Tenancy di setiap baris.** Tabel milik komunitas menyimpan `community_id` dan
   memakai FK komposit `(community_id, id)` ke induknya. Satu baris tidak bisa
   menyeberang komunitas (`db/migrations/0001_core.sql:32-52`, `db/migrations/0003_tournament.sql:7-20`).
2. **UUID dari database.** Sebagian besar PK memakai `gen_random_uuid()`. Pengecualian
   yang disengaja: `session.links.id` diisi aplikasi karena dipakai sebagai AAD enkripsi
   (`db/migrations/0001_core.sql:54-56`).
3. **Waktu.** `timestamptz` untuk waktu proses; tanggal kalender memakai `date`
   (`session_date`, `event_date`, `local_date`, `taken_on`).
4. **Enum sebagai CHECK**, bukan tipe enum Postgres: status sesi, role, tier, kelas tim,
   fase turnamen, dan hasil audit.
5. **Grant least-privilege.** Aplikasi memakai role `bm2_app`, bukan owner. Tabel bukti
   (`account.audit`, `player.merge_log`) hanya boleh `select`/`insert`
   (`db/migrations/0001_core.sql:203-211`, `db/migrations/0004_platform.sql:131-138`).

## 2. Tabel per skema

### `platform`

| Tabel | Kolom/constraint penting | Migrasi |
|---|---|---|
| `platform.community` | `id`, `slug` unik global + format `^[a-z0-9]…$`, `name`, `timezone`, `created_at` | `0001:9-19` |
| `platform.user` | `google_sub` unik, `email_hash` unik, `display_name`, `is_platform_owner` | `0001:21-30` |
| `platform.config` | PK `key`; `value_type` (`int`/`decimal`/`bool`/`string`/`json`), `value` JSONB, `min_value`/`max_value`, `scope` (`platform`/`community`), `description`, `since_version` | `0004:6-18` |
| `platform.config_version` | Singleton (`id boolean primary key default true`), `version bigint`; snapshot config di-cache per nilai ini dan reload saat berubah | `0004:20-25` |
| `platform.idempotency_keys` | Unik `(user_id, key)`, `body_hash`, `status_code`, `response` JSONB, `expires_at` + index | `0004:27-39` |
| `platform.import_row_map` | PK `(community_id, source_table, source_key)` → `target_id`; peta ETL v1→v2 | `0004:41-48` |
| `platform.ws_ticket` | `token_hash` unik, `channel_kind` (`session`/`share`), `channel_id`, `user_id` nullable dengan CHECK: channel share boleh anonim, session wajib user; `expires_at`, `used_at` | `0004:50-64`, `0007` |
| `platform.cutover_state` | Singleton; `snapshot_sha256`, `snapshot_taken_at`, `etl_completed_at`, `completed_at`, `app_version`, `rows_imported` (0016) | `0004:66-73`, `0016` |
| `platform.outbox` | `topic`, `payload` JSONB, `created_at`, `processed_at`; saat ini hanya dibersihkan janitor, belum ada produsen event | `0004:121-128` |
| `platform.ops_token` | `name`, `token_hash` unik, `created_by`, `expires_at`, `revoked_at`, `last_used_at` | `0008:6-22` |

### `session`

| Tabel | Kolom/constraint penting | Migrasi |
|---|---|---|
| `session.sessions` | `community_id`, `title`, `session_date`, `start_time`, `slot_minutes > 0`, `status` ∈ `draft/locked/published/completed/archived`, `source` ∈ `manual/generator/legacy_snapshot`, `version > 0`, `approved_at`, `approved_by` | `0001:32-52`, `0006` |
| `session.links` | `id` diisi aplikasi, `code_hash` unik, `code_enc`, `key_id`, `created_by`, `revoked_at`, `expires_at`; index parsial menjamin satu link hidup per sesi | `0001:54-75` |
| `session.courts` | `court_index >= 0`, unik `(session_id, court_index)`, `start_time < end_time` | `0001:77-93` |
| `session.games` | Unik `(session_id, round_no, court_no)`; skor 0–99 dan tidak boleh seri saat `played`; status `scheduled/played/cancelled`; `version` dinaikkan trigger `session.bump_version()`; `side_a1/a2/b1/b2` (0010) dengan FK komposit ke `session.participants`; CHECK `games_distinct_sides` (0014) | `0001:95-134`, `0010:32-61`, `0014` |
| `session.participants` | Unik `(session_id, player_id)`; `is_absent`; FK player `on delete restrict` | `0010:7-27` |

Catatan: `session.games` adalah jadwal relasional, bukan blob. Empat kolom sisi berarti
singles memakai satu slot per sisi; slot `NULL` adalah posisi kosong, bukan pemain.

### `player`

| Tabel | Kolom/constraint penting | Migrasi |
|---|---|---|
| `player.players` | `canonical_name`, `canonical_key` generated (trim + lower + collapse whitespace) unik per komunitas, `tier` nullable ∈ `D/D+/C/C+/B/B+/A/A+`, `gender` ∈ `M/F`, `user_id`; satu pemain ber-owner per user per komunitas | `0001:136-160` |
| `player.claims` | `status` ∈ `pending/approved/rejected/released`; field keputusan konsisten dengan status; satu `pending` dan satu `approved` per pemain | `0001:162-188` |
| `player.merge_log` | `source_id`, `target_id`, `rows_moved >= 0`, `actor_id`; append-only untuk aplikasi | `0001:190-201` |
| `player.aliases` | `alias`, `alias_key` generated, unik `(community_id, alias_key)`, FK pemain cascade | `0009:7-25` |

### `rating` & `achievement`

| Tabel | Kolom/constraint penting | Migrasi |
|---|---|---|
| `rating.events` | `community_id`, `local_date`, `event_type` ∈ `session/tournament/manual`, `source_id` (id sesi/turnamen), index `(community_id, local_date desc)` | `0002:8-20` |
| `rating.deltas` | `event_id`, `side` ∈ `a/b`, `player_id`, `game_key` (round-court), `delta` integer; unik `(event_id, side, player_id, game_key)` | `0002:22-40`, `0018` |
| `rating.player_state` | PK `(community_id, player_id)`, `rating`, `games_played`, `wins`, `losses`; CHECK `games_played = wins + losses` | `0002:42-54` |
| `rating.snapshots` | PK `(community_id, player_id, taken_on)`, `rating`; poin per tanggal, diisi ETL (riwayat v1) dan `./task ranksnapshot`; sumber panah pergerakan | `0002:56-67` |
| `rating.sources` | PK `(community_id, source_id)`, `kind` ∈ `session/tournament`, `finalized`, `finalized_at`; sign-off bertahan melewati rebuild dan membuat revert ditolak | `0013:9-24` |
| `rating.levels` | PK `(community_id, kind)`, `champion_points`, `round_ratios` JSONB (`qf/sf/final/group/runner_up/participant`), `enabled`; kind `session/tournament_classic/tournament_team` | `0020` |
| `achievement.definitions` | PK `key`, `category`, `threshold >= 0`; sertakan rung `rank_streak` untuk tampilan medali v1 | `0002:69-74`, `0022` |
| `achievement.earned` | PK `(community_id, player_id, achievement_key)`, `meta` JSONB, `earned_at`; tanpa FK ke definisi agar medali event v1 tetap tersimpan | `0002:76-86`, `0019` |

Poin tidak disimpan sebagai kolom. Papan dihitung saat baca dari game sesi dan match
turnamen dalam window bergulir (proyeksi v1: satu entri per sumber, `best_n` terbaik);
`rating.deltas` adalah ledger integer per game dan `rating.player_state` hanya
bookkeeping menang/kalah/main (`modules/rating/projection.nim`, `modules/rating/read.nim`).

### `tournament`

| Tabel | Kolom/constraint penting | Migrasi |
|---|---|---|
| `tournament.tournaments` | `name`, `status` ∈ `draft/active/completed/archived`, `event_date`, `version > 0`, `format` ∈ `classic/team` | `0003:7-20`, `0012:10-15` |
| `tournament.pairs` | `display_name`, `player_a_id`/`player_b_id` (harus berbeda), unik `(community_id, id)` | `0003:22-41` |
| `tournament.matches` | `round_no`, `pair_a_id`/`pair_b_id` nullable, `phase` ∈ `group/qf/sf/3rd/final`, `group_id` ∈ `A–D`, `pic_name`, `match_key` unik per turnamen, `match_order`, skor 0–99 tanpa seri saat `played` | `0003:43-76`, `0012:17-31` |
| `tournament.groups` | PK `(tournament_id, group_id, position)`; `group_id` A–D, `position` 0–3 | `0012:34-50` |
| `tournament.teams` | `seed` 1–6, `team_name`; unik seed dan nama per turnamen | `0012:54-70` |
| `tournament.team_players` | `player_name` (snapshot), `player_id` nullable, `cls` ∈ `A+/A/B+/B/C+/C`; unik `(team_id, cls)` | `0012:72-89` |
| `tournament.team_matches` | `phase` ∈ `group/final`, `match_order`, `match_key` unik, `team_a_id`/`team_b_id` nullable, `courts text[3]` (default `Court 12/13/14`) | `0012:91-113` |
| `tournament.team_partai` | `partai_index` 0–2, skor 0–99, `(score_a is null) = (score_b is null)`; unik `(team_match_id, partai_index)` | `0012:115-132` |

### `community`

| Tabel | Kolom/constraint penting | Migrasi |
|---|---|---|
| `community.membership` | PK `(community_id, user_id)`, `role` ∈ `member/host/admin`, index per user | `0005:5-14` |
| `community.invite` | `token_hash` unik, `email_hash`, `role`, `created_by`, `expires_at`, `accepted_at` | `0005:16-30` |
| `community.join_request` | `status` ∈ `pending/approved/rejected`; `decided_at` konsisten; satu `pending` per `(community, user)` | `0005:32-48` |
| `community.settings` | PK `community_id`, `values` JSONB, `updated_at`; override per komunitas | `0005:50-55` |

### `auth` & `account`

| Tabel | Kolom/constraint penting | Migrasi |
|---|---|---|
| `auth.oauth_flows` | `state_hash` unik, `nonce_hash`, `code_verifier_enc`, `return_to`, `expires_at` + index | `0004:75-86` |
| `account.sessions` | `user_id`, `token_hash` unik, `created_at`, `last_seen_at`, `absolute_expires_at`, `revoked_at` | `0004:88-99` |
| `account.audit` | `occurred_at`, `actor_id`/`actor_role`, `community_id`, `action`, `target_kind`/`target_id`, `result` ∈ `allow/deny/error`, `request_id`, `before`/`after` JSONB; append-only | `0004:101-119` |

## 3. Constraint & aturan yang mudah salah

- `session.games` tidak boleh seri saat `status = 'played'`; skor `NULL` berarti belum
  dimainkan (`0001:111-117`).
- `session.games` versi per baris dinaikkan trigger, tetapi **OCC API memakai versi
  sesi** (`session.sessions.version`) — lihat [`architecture.md`](architecture.md) §9.
- Pemain yang sama tidak boleh muncul dua kali dalam satu game, dan tidak boleh ada di
  kedua sisi; CHECK `games_distinct_sides` versi `0014` memperbaiki `0010` yang menolak
  game singles/kosong.
- `player.players.canonical_key` dan `player.aliases.alias_key` memakai normalisasi yang
  sama; alias unik per komunitas agar dua pemain tidak menjawab nama yang sama.
- Nama di `tournament.team_players.player_name` adalah snapshot; `player_id` boleh
  `NULL` untuk pemain yang belum terdaftar.
- `rating.sources` adalah satu-satunya tempat sign-off; `rating.events` tidak lagi punya
  kolom `finalized` (dipindah oleh `0013`).
- `platform.ws_ticket` menyimpan hash, bukan token; channel `share` boleh tanpa user,
  channel `session` tidak (`0004:50-64`).

## 4. Registry konfigurasi

Semua angka bisnis dibaca dari `platform.config` + override `community.settings`.
Defaults di `db/seeds/platform_config.sql`; kunci dan tipenya dikunci di
`modules/platform/config/registry.nim:13-50`. Nilai hilang atau tipe salah membuat
proses menolak start (`modules/platform/config/store.nim:50-72`).

| Kelompok | Key (default seed) |
|---|---|
| Komunitas | `community.join_requests_enabled` (`false`), `community.invite_ttl_days` (`7`), `community.directory_enabled` (`false`), `community.default_timezone` (`Asia/Jakarta`) |
| Ingest & halaman | `ingest.ticker_minutes` (`30`), `api.page_size_default` (`100`), `rank.board_limit` (`200`) |
| Poin | `rating.session_base` (`250`), `rating.score_target` (`21`), `rating.opponent_clamp` (`[0.5,1.5]`), `rating.window_weeks` (`12`), `rating.best_n` (`10`), `rating.thin_evidence_n` (`3`), `rating.tier_bands` (8 band kelas D 1000–1199 … A+ 2100–terbuka) |
| Turnamen | konstanta domain `PairCount = 16` (bukan config; 16 pair adalah aturan format) |
| Ekspor | `export.post_width`/`post_height` (`1080×1350`), `export.story_width`/`story_height` (`1080×1920`) |
| Keamanan | `security.allowed_origins`, `security.rate_limit_per_minute` (`300`), `security.max_body_bytes` (`1048576`), `security.max_json_depth` (`16`), `security.read_timeout_ms` (`15000`), `security.join_request_rate` (`5`), `security.share_scrape_limit` (`120`) |
| Realtime | `ws.max_watchers_per_session` (`50`), `ws.max_watchers_per_ip` (`20`), `ws.max_watchers_process` (`500`), `ws.ticket_ttl_seconds` (`60`) |
| Sesi login | `session.absolute_days` (`30`), `session.idle_days` (`7`), `auth.flow_ttl_minutes` (`10`) |
| Retensi | `janitor.retention_days` (`30`), `audit.retention_days` (`365`) |

`rating.tier_bands` adalah **atribut tampilan/klasifikasi**, bukan hasil hitung poin:
tier pemain disimpan di `player.players.tier` dan hanya berubah lewat `PATCH player`.
Band memakai rentang kelas v1 dengan `max` (mis. D 1000–1199, A+ 2100–terbuka); titik
tengah band dipakai sebagai kekuatan tier pada pengali lawan. Ladder turnamen
(`champion_points` dan `round_ratios`) disimpan di `rating.levels`, bukan di config:
itu data yang diisi operator lewat `./task levels` (list/set/clear), dan komunitas
yang tidak punya baris untuk sebuah format memakai rumus per-game.

## 5. Bentuk data di API vs tipe frontend

Kontrak API adalah sumber bentuk payload (`packages/contracts/openapi/*.yaml`). Tipe
TypeScript per fitur adalah proyeksi lokal, bukan SSOT:

- `apps/web/src/legacy/queries/types.ts` — `SessionMeta`, `PlayerStats`, dan
  re-export `CloudSnapshot`.
- `apps/web/src/legacy/queries/endpoints.ts` — adapter payload v1: `GameRow`,
  `TournamentMeta`, `RatingPlayer`, `RankPointsBoard`, `AchievementRow`.
- `apps/web/src/community/api.ts` — `CommunityConfig` (`value` + `source`
  `platform`/`community`).

Contoh bentuk baca sesi (`GET /c/{slug}/sessions/{id}`):

```json
{
  "id": "uuid", "title": "…", "date": "YYYY-MM-DD",
  "startTime": "HH:MM", "slotMinutes": 30,
  "status": "draft", "version": 1,
  "participants": [{ "playerId": "uuid", "name": "…", "absent": false }],
  "games": [{ "round": 0, "court": 0, "sideA": ["uuid"], "sideB": [],
              "scoreA": null, "scoreB": null, "status": "scheduled" }]
}
```

Sumber: `apps/api/src/app.nim` (`getSessionDetail`),
`apps/web/src/legacy/queries/endpoints.ts`.

## 6. Yang tidak ada di v2

Jangan membawa nama dari dokumen v1 ke sini:

| v1 | v2 |
|---|---|
| schema `bm`, migrasi `000001`–`000023` | database `bm2`, migrasi `0001`–`0023` |
| `scheduled_games`, `scheduled_game_players` | `session.games` + `session.participants` |
| `rating_events`, `rating_deltas`, `rating_players` | `rating.events`, `rating.deltas`, `rating.player_state` |
| `player_achievements` | `achievement.earned` + `achievement.definitions` |
| snapshot JSON sesi/turnamen | kolom relasional per tabel |
| Glicko/rating absolut | poin relatif yang dihitung saat baca |

Arsip SQL v1 (bukan skema aktif): [`../backend/`](../backend/README.md).
