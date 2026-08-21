# DATA-MODEL-V2 — Desain arsitektur data normalized (draft)

> Status: **PARTIALLY IMPLEMENTED** — beberapa bagian sudah dieksekusi.
> - Tournament normalization (5 tables) ✅ implemented
> - Session identity (UUID PK, share_code) ✅ implemented
> - Game state merging — not yet implemented
> - Fix match slots consolidation — not yet implemented
> 
> Tujuan: fix fundamental schema `bm`/`bm_dev` (identity, 1:1 tables, tournaments).
> Scope: sessions + tournaments + players, satu desain koheren.
> Referensi: current-status.md untuk status terkini.

---

## 0. Prinsip desain

1. **Satu identitas per agregat** — UUID PK, tanpa dual identity / trigger sinkronisasi.
2. **Snapshot tetap jadi kontrak API** — app tetap kirim/terima `CloudSnapshot` &
   `TournamentSnapshot` JSON; DB di belakang RPC yang berubah. **App hampir tidak disentuh.**
3. **Tidak ada tabel 1:1** — atribut yang selalu ada bersama induknya jadi kolom.
4. **Relasi direferensikan, bukan direplikasi** — player di tournament pakai FK ke
   `bm.players`, bukan string nama.
5. **Logika domain tetap di client** — bracket propagation, PIC assignment, standings.

---

## 1. Identity — `sessions` & `tournaments`

### Sebelum
```
sessions.id            text  (9-char client-generated, dipakai di URL /s/:id)
sessions.internal_id   uuid  (PK sebenarnya)
sessions.share_id      text  (= id, redundant — verifikasi: 0 mismatch)
child tables: session_id (text) + session_internal_id (uuid) + trigger sync_session_identity
```

### Sesudah
```
sessions.id            uuid  PK        ← internal_id dimerge ke sini
sessions.share_code    text  UNIQUE    ← 9-char, untuk URL /s/:share_code
(share_id Dihapus — fungsinya diganti share_code)

child tables: cukup session_id uuid FK  (rename dari session_internal_id)
hapus kolom session_id text di semua child + trigger sync_session_identity
```

**Alur lookup:** app tetap kirim `p_id` = 9-char share_code (tidak berubah di app).
`resolve_session_lookup` mencari `id = p_id OR share_code = p_id` — backward compatible.

**Keuntungan:** hapus ~15 kolom redundant, 5 trigger, ~15 constraint duplikat.
URL share tetap pendek (`/s/6tzmzz`), UUID internal lebih aman & FK lebih bersih.

---

## 2. Sessions — ramping tabel 1:1

### 2a. Game state (gabung 2 tabel 1:1)

```
SEBELUM:
  scheduled_games (slot, court, status, ...)
  game_progress   (is_played, played_order)   1:1
  game_scores     (score_a, score_b)          1:1

SESUDAH: kolom di scheduled_games
  + is_played      boolean default false
  + played_order   integer nullable
  + score_a        integer nullable   (check 0-99, score_a <> score_b)
  + score_b        integer nullable
  DROP TABLE game_progress, game_scores
```

### 2b. Fix matches (4 slot = 4 kolom)

```
SEBELUM:
  fix_matches (id, legacy_ref, sort_order)
  fix_match_slots (fix_match_internal_id, slot_index, session_player_internal_id)  1:4

SESUDAH: kolom di fix_matches
  + slot_0 uuid nullable FK -> session_players
  + slot_1 uuid nullable FK
  + slot_2 uuid nullable FK
  + slot_3 uuid nullable FK
  DROP TABLE fix_match_slots
```

### 2c. session_players — dibersihkan

```
SEBELUM: player_ref (text) + player_id (uuid FK) + source_name + gender + tier + ...
SESUDAH:
  + player_ref TETAP (id pemain di snapshot — kontrak app)
  + player_id TETAP (FK ke bm.players — canonical)
  + source_name TETAP (nama tampilan per sesi)
  + gender/tier tetap (per-sesi snapshot)
  (tidak ada kolom yang dihapus di sini — strukturnya sudah ok)
```

---

## 3. Tournaments — normalized penuh

### Sebelum: 1 tabel JSONB
```
tournaments (id text, name, event_date, snapshot jsonb, version)
  snapshot = { name, date, pairs[], groups{}, matches[] }  ← semuanya di JSON
```

### Sesudah: 5 tabel

```sql
-- 1. Metadata
CREATE TABLE bm.tournaments (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  share_code  text UNIQUE,
  name        text NOT NULL,
  event_date  date NOT NULL,
  status      text NOT NULL DEFAULT 'draft',   -- draft | locked | completed
  version     integer NOT NULL DEFAULT 1,
  created_at  timestamptz DEFAULT now(),
  updated_at  timestamptz DEFAULT now()
);

-- 2. Pairs (16 per tournament)
CREATE TABLE bm.tournament_pairs (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tournament_id uuid NOT NULL REFERENCES tournaments(id) ON DELETE CASCADE,
  pair_name     text NOT NULL,               -- "Dwi & Ismet" (display)
  seed          integer NOT NULL,            -- 1..16
  UNIQUE (tournament_id, seed)
);

-- 3. Pair -> player membership (2 players per pair)  ★ kunci statistik
CREATE TABLE bm.tournament_pair_players (
  pair_id   uuid NOT NULL REFERENCES tournament_pairs(id) ON DELETE CASCADE,
  player_id uuid NOT NULL REFERENCES players(id) ON DELETE RESTRICT,
  PRIMARY KEY (pair_id, player_id)
);

-- 4. Group seeding (A/B/C/D, 4 pairs per group)
CREATE TABLE bm.tournament_groups (
  tournament_id uuid NOT NULL REFERENCES tournaments(id) ON DELETE CASCADE,
  group_id      text NOT NULL,               -- 'A' | 'B' | 'C' | 'D'
  pair_id       uuid NOT NULL REFERENCES tournament_pairs(id) ON DELETE CASCADE,
  position      integer NOT NULL,            -- 1..4 dalam grup
  PRIMARY KEY (tournament_id, group_id, pair_id),
  UNIQUE (tournament_id, group_id, position)
);

-- 5. Matches (32 per tournament: 24 RR + 4 QF + 2 SF + 3rd + final)
CREATE TABLE bm.tournament_matches (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tournament_id uuid NOT NULL REFERENCES tournaments(id) ON DELETE CASCADE,
  phase         text NOT NULL,               -- group | qf | sf | 3rd | final
  group_id      text,                        -- hanya untuk phase='group'
  pair_a_id     uuid REFERENCES tournament_pairs(id),
  pair_b_id     uuid REFERENCES tournament_pairs(id),
  score_a       integer CHECK (score_a >= 0),
  score_b       integer CHECK (score_b >= 0),
  pic_player_id uuid REFERENCES players(id), -- PIC = player canonical ★
  match_order   integer NOT NULL,            -- urutan deterministik
  UNIQUE (tournament_id, phase, group_id, match_order)
);
```

### Mapping snapshot ↔ tabel (di RPC, app tidak berubah)

| Snapshot field | Sumber tabel |
|---|---|
| `pairs[]` | `tournament_pairs` + `tournament_pair_players` |
| `groups{}` | `tournament_groups` |
| `matches[]` | `tournament_matches` |
| `match.picName` | `pic_player_id` → `players.canonical_name` |
| `pair.id` ("p1") | `tournament_pairs.seed` atau client id |

---

## 4. Alias & resolve nama player (penting untuk tournament)

Sistem alias yang ADA sudah bekerja (multi-alias per player, case-insensitive),
tapi desain V2 butuh 2 hal baru yang belum ada:

### 4a. Sistem yang ada (tidak diubah)

```
players            → canonical_name (unique, case-preserved: "Dwi")
player_aliases     → alias_name (normalized PK, lowercase: "dwi") → player_id
normalize_player_name() → lowercase + trim + collapse whitespace
register_player(name, canonical) → idempotent + TOCTOU-safe (race di-handle)
resolve_player_id(name) → alias → player_id
```

Data live membuktikan pola berfungsi:
- `agh` + `agha` → player SAMA (singkatan + nama penuh)
- `andra` + `andra (temen novian)` → player SAMA (alias beranotasi)

### 4b. GAP: pair name → player (FUNGSI BARU)

Pair tournament disimpan sebagai `"Dwi & Ismet"` — SATU string, bukan 2 player.
Desain V2 butuh fungsi resolve yang memecah & memetakan:

```sql
-- resolve_tournament_player(name)  — FUNGSI BARU
-- 1. normalize(name) → cek player_aliases
-- 2. ketemu       → return player_id (existing)
-- 3. tidak ketemu → register_player(name, canonical=name) → return player_id
--    (idempotent & TOCTOU-safe — aman dipanggil berulang)
```

Backfill `tournament_pair_players`:
```
parse_pair("Dwi & Ismet") → ["Dwi", "Ismet"] → resolve_tournament_player per nama
```

### 4b-2. Placeholder member (pair 1 orang) — KASUS NYATA

Kadang admin/host tidak mengisi nama karena 1 orang tidak datang dari jadwal
generated: `"Budi - XXXX vs Ani - Rudi"`. Konsekuensi desain:

- `tournament_pair_players` boleh berisi **0–2 row per pair** (bukan wajib 2).
- Placeholder (`"xxxx"`, `"-"`, string kosong, `"?"`) **tidak di-resolve** —
  cukup tidak dibuatkan row membership.
- `pair_name` tetap menyimpan display asli (`"Budi - XXXX"`).
- Match tetap valid (walkover / bye) — `tournament_matches.pair_a_id`/`pair_b_id`
  tetap wajib ada, tapi pair boleh 1 player.

```sql
-- resolve helper: deteksi placeholder sebelum resolve
-- resolve_tournament_player(name):
--   if name matches placeholder pattern → return NULL (skip, jangan create!)
--   else → normal resolve / register
```

### 4c. Kebijakan konflik & ambiguitas

| Kasus | Perilaku |
|---|---|
| Nama tournament = player yang sudah ada | Reuse player_id (hub terpusat ✅) |
| Nama tournament belum pernah ada | Auto-create via register_player |
| 2 nama berbeda → player yang sama (bukan pair) | Anomali → laporkan, JANGAN auto-merge |
| `resolve_player_id` ambigu (satu alias → 2 player) | Di mencegah oleh PK alias_name — tidak mungkin secara struktur |

### 4d. Konsekuensi yang harus disadari

- Player tournament yang **belum pernah main sesi** akan **muncul di player list**
  (`list_players` join dari semua context). Ini fitur (hub terpusat), bukan bug —
  tapi perlu dipertimbangkan di UI kalau mau filter "pernah main sesi".
- Alias yang di-auto-create saat backfill pakai nama tournament sebagai
  canonical — konsisten dengan `register_player` yang sudah ada.

---

## 5. Players = hub pusat statistik

```
bm.players (canonical, sudah ada)
   ├── player_aliases                       (resolve nama)
   ├── session_players                      (sesi → games)
   └── tournament_pair_players              (tournament → matches) ★ BARU
```

`get_player_stats` di-extend jadi **career stats gabung**:
- **Sesi**: games, W/L, points, top partners, top opponents (sudah ada)
- **Tournament (baru)**: games, W/L, top partners (= pair partner), top opponents (= pair lawan)

Query contoh (partner di tournament):
```sql
-- partner terbanyak di tournament
SELECT p.canonical_name, count(*)
FROM tournament_pair_players tpp1
JOIN tournament_pair_players tpp2 ON tpp2.pair_id = tpp1.pair_id
JOIN players p ON p.id = tpp2.player_id
WHERE tpp1.player_id = $1 AND tpp2.player_id <> $1
GROUP BY p.canonical_name ORDER BY count(*) DESC LIMIT 5;
```

---

## 6. Dampak ke app (minimal)

| Area | Perubahan |
|---|---|
| `endpoints.ts` | **Tidak berubah** — RPC signature sama (publish/get snapshot) |
| `utils/tournament.ts` | **Tidak berubah** — logika domain tetap client |
| `queries/tournament.ts` | Tidak berubah |
| `store/` | Tidak berubah |
| RPC `publish_session` | Ditulis ulang: insert ke tabel baru (tanpa game_progress/game_scores/fix_match_slots) |
| RPC `get_session` | Ditulis ulang: select + assemble (tanpa join ke tabel yang dihapus) |
| RPC `publish_tournament` | Ditulis ulang: dekomposisi snapshot → 5 tabel |
| RPC `get_tournament` | Ditulis ulang: assemble 5 tabel → snapshot |
| RPC `get_player_stats` | Extend: + tournament stats |

---

## 7. Urutan eksekusi (untuk bm_dev dulu, prod menyusul)

```
FASE 0: Backup bm_dev + bm (prod)
FASE 1: Identity — sessions.id jadi uuid + share_code, hapus dual columns
        (migrasi data: pindahkan internal_id -> id, share_id -> share_code)
FASE 2: Ramping sessions — merge game state & fix slots
        (migrasi data: copy game_progress/game_scores ke kolom scheduled_games)
FASE 3: Tournaments — bikin 5 tabel baru + backfill dari snapshot JSONB
FASE 4: RPC baru — publish/get session & tournament + player stats extend
FASE 5: Verifikasi — parity test (snapshot lama vs baru harus identik)
FASE 6: Deploy ke prod setelah bm_dev terverifikasi
```

**Parity test wajib:** untuk setiap sesi/tournament yang ada, `get_*` versi baru
harus menghasilkan JSON identik dengan versi lama. Ini safety net-nya.

---

## 8. Risiko & mitigasi

| Risiko | Mitigasi |
|---|---|
| Migrasi data prod | Backup dulu; parity test; eksekusi di bm_dev dulu |
| App error (RPC contract berubah) | Snapshot contract SAMA — app tidak berubah; RPC di-test dengan check script |
| Bracket/PIC berubah | Logika tetap di client; PIC jadi FK player — perlu resolve nama→player |
| Player di tournament belum terdaftar | `register_player` idempotent — resolve otomatis saat backfill |

**Catatan PIC:** sekarang `picName` string nama → nanti FK ke `bm.players`.
Backfill: resolve nama via `player_aliases`; kalau belum ada → `register_player`.
Ada resiko player tournament bukan player sesi — itu justru value (hub terpusat).

---

## 9. Yang TIDAK berubah

- `bm.players` + `player_aliases` — sudah benar, jadi fondasi
- Snapshot contract (`CloudSnapshot` / `TournamentSnapshot`) — kontrak API stabil
- Logika domain (generator, bracket, standings, PIC assignment) — tetap di client
- Struktur `scheduled_games`/`scheduled_game_players`/`session_courts` — sudah ok
- RLS — tetap tidak ada (di luar scope; hardening terpisah)
