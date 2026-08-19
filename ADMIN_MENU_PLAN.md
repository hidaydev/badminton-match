# ADMIN_MENU_PLAN.md

**Status:** PLAN — belum diimplementasikan
**Tanggal:** 2026-08-18
**Lokasi:** root badminton-match
**Terkait:** `RATING_TIERING_REVAMP.md` (skema sub-tier 12 band) · `RATING_ENGINE_DESIGN.md` (engine rating, API admin) · `RATINGS_FRONTEND_PLAN.md`

---

## 1. Latar & Tujuan

Menu admin untuk operasional harian host/admin:
- **Login** via tombol di HomeLayout (sebelah tombol Refresh).
- Setelah login → **menu admin** berisi fungsi yang sudah direncanakan (unlock session, ingest/revert/finalize/rebuild rating) + manajemen pemain (tambah/hapus/edit) + ubah kelas (ratings) / tier (session).
- Admin token = `MAJADU_ADMIN_TOKEN` (sudah ada di backend untuk endpoint write ratings; saat ini `unlock` masih TANPA auth).

---

## 2. Login & Admin Area (Rev 2 — alur baru)

### 2.1 UI — Card "Admin Area" di HomePage (bukan tombol dekat Refresh)

- **Card "Admin Area"** di HomePage, **segmen terpisah di bawah grid utama** (bukan nyampur
  dengan menu player-facing), gaya pembeda: border aksen gold/amber + tag kecil `admin`.
- **Belum login** → tap card → **popup login** (input `MAJADU_ADMIN_TOKEN` + [Login]) →
  sukses → navigate `/admin`.
- **Sudah login** → tap card → langsung `/admin` (tanpa prompt).
- **Setelah login card berubah**: label `Admin Area` → `Admin` + badge aktif; tombol
  **Logout** tersedia (di card & header halaman admin).

### 2.2 Halaman `/admin` (route baru, segmen khusus)

```
[Admin] banner pembeda (amber/gold) + [Logout]
  ─ Session ─  Unlock session
  ─ Rating ─   Ingest / Revert / Finalize (per source) · Rebuild All
  ─ Season ─   Close & Start New Season (picker tanggal) · Lihat arsip musim
  ─ Player ─   Add (ke sesi) · Delete · Edit nama
  ─ Class ─    Ubah tier induk / class rating
```

- Tampilan pembeda konsisten (aksen amber/gold) supaya "admin mode" tidak tertukar dengan UI biasa.
- Opsional: badge `admin` kecil di HomeLayout saat login aktif.

### 2.3 Penyimpanan token

- **`sessionStorage`** (hilang saat tab ditutup — lebih aman daripada localStorage; XSS window lebih kecil).
- API client: semua request admin menyertakan `Authorization: Bearer <token>` bila ada.
- [Logout] membersihkan token + state admin.

### 2.4 Backend

- `MAJADU_ADMIN_TOKEN` sudah di `config` (wajib di prod, fail-fast). Tidak ada perubahan backend untuk login — endpoint admin sudah mengecek Bearer.
- Route baru `GET /admin` (frontend-only — tidak perlu endpoint backend).

---

## 3. Menu Admin — Fungsi

### 3.1 Session

| Fungsi | Endpoint (existing) | Auth | Catatan |
|---|---|---|---|
| Unlock session | `POST /sessions/{id}/unlock` | **SAAT INI TANPA AUTH — perlu di-gate** | Unlock = operasi admin (docs lama sudah menyebut admin-only). Frontend belum punya tombol unlock — menu admin menyediakannya |
| Lock session | `POST /sessions/{id}/lock` | open (host flow) | — |

**Perubahan:** `Unlock` handler diberi middleware `RequireAdmin`. Verifikasi frontend existing tidak memanggil unlock tanpa token (saat ini tidak ada tombol unlock di UI — aman).

### 3.2 Rating (sudah ada endpoint, token)

| Fungsi | Endpoint |
|---|---|
| Ingest session | `POST /ratings/ingest-session {sessionId}` |
| Ingest tournament | `POST /ratings/ingest-tournament {tournamentId}` |
| Revert session | `POST /ratings/revert-session {sessionId}` |
| Revert tournament | `POST /ratings/revert-tournament {tournamentId}` |
| Finalize tournament | `POST /ratings/sources/{id}/finalize {finalized}` |
| Rebuild all | `POST /ratings/rebuild-all` |
| **Close & Start New Season** | `POST /ratings/season {startDate}` (BARU — §2.5.7–2.5.8): **arsip final standings** musim berjalan → hapus events → reset semua ke mid kelas → season_start baru. Dari musim pertama, otomatis menutup & mengarsip |

Semua sudah ada di backend (token; season = baru) — **belum ada UI**. Menu admin: daftar sumber (dari `GET /ratings/sources`) + tombol aksi per sumber + rebuild-all + **reset season (picker tanggal)**.

### 3.3 Ubah kelas (ratings) — BARU

- **Endpoint baru**: `PATCH /ratings/players/{playerId}/class {class, source:"admin"}` → update `rating_players.class` + `class_source='admin'`.
- Efek: floor berubah (§3.3 RATING_TIERING_REVAMP). Tidak perlu rebuild.
- UI: ~~di halaman detail rating `/ratings/:playerId`, admin melihat dropdown 12 sub-tier → simpan~~.
- **DEVASI (2026-08-19):** UI edit class **dihapus** — admin hanya boleh ubah **tier induk**
  (`PATCH /players/{id}/tier`, §3.4). Class sub-tier **auto-adjust**: `SetPlayerTier`
  sudah meng-update `rating_players.class` = tier baru + memanggil RebuildAll otomatis,
  atau admin menjalankan tombol **Rebuild All** manual di /admin. Endpoint class tetap
  ada di API (curl), hanya tidak lagi dipakai UI.

### 3.4 Manajemen pemain

| Fungsi | Mekanisme |
|---|---|
| **Add player (ke session, dengan tier session)** | Alur normal: menu admin navigasi ke `/session/players` (atau inline form add ke sesi aktif). Class RATINGS TIDAK di-set di sini — hanya tier session (sesuai permintaan: "dengan kelas sesuai session, bukan ratings") |
| **Delete player** | **Endpoint baru Go**: `DELETE /players/{playerId}` → memanggil fungsi SQL `bm.delete_player(p_player_id, p_force)` (sudah ada di DB, belum di-expose). Perlu analisis FK (session_players.player_id kini nullable; tournament_team_players ON DELETE SET NULL; rating_players FK → perlu cascade/set null) — detail §4.1 |
| **Edit player** | Rename/canonical: reuse `POST /players` (register dengan canonicalName) + alias. UI: form edit nama di daftar pemain |
| **Ubah tier induk (session)** | Endpoint `PATCH /players/{id}/tier` → update `players.tier` (terpusat — §2.5 RATING_TIERING_REVAMP). Mempengaruhi forming rating pemain BARU; pemain existing → ubah class rating langsung |

### 3.5 Struktur UI

```
HomeLayout ──(token)──▶ [Admin icon] ──▶ AdminSheet (bottom sheet / drawer):
  ─ Session ──────────────  Unlock session (pilih dari list)
  ─ Rating ───────────────  Ingest / Revert / Finalize (per source, dari GET /ratings/sources)
                            Rebuild all · Close & Start New Season (picker tanggal)
  ─ Season ──────────────  Lihat arsip musim (standings beku)
  ─ Player ───────────────  Add player (ke session) · Delete player · Edit name
  ─ Class ────────────────  Ubah kelas (dropdown 12) — dari detail rating
  ─ [Logout]
```

- Komponen: `components/admin/AdminSheet.tsx` + `context/AdminContext.tsx` (state token + isAdmin).
- Akses: hanya tampil/aktif kalau token valid (validasi via satu request admin, mis. `GET /ratings/sources`).

---

## 4. Backend — Endpoint Baru

### 4.1 Delete player (analisis FK)

`bm.delete_player(p_player_id uuid, p_force boolean)` sudah ada (fungsi SQL). Referensi `players(id)`:
- `session_players.player_id` → **nullable** (sudah relax 000007) → SET NULL aman.
- `player_aliases.player_id` → `ON DELETE CASCADE` (schema awal) ✓.
- `tournament_team_players.player_id` → `ON DELETE SET NULL` ✓.
- `tournament_pair_players.player_id` → perlu cek FK action (kemungkinan tidak ada FK atau harus diset).
- `rating_players.player_id` → FK `REFERENCES players(id)` **tanpa action** → perlu `ON DELETE CASCADE` atau hapus dulu di Go (transaksi: delete rating data → panggil delete_player).

Keputusan: **panggil `delete_player` dalam transaksi Go**, setelah menghapus baris `rating_players`/`rating_deltas` milik pemain (cascade via events). `p_force=false` dulu; error FK → pesan jelas.

### 4.2 Ubah kelas

```go
// handler/ratings.go — PATCH /ratings/players/{playerId}/class (admin)
// body: { "class": "C" }  → UPDATE rating_players SET class=$2, class_source='admin'
// validasi 12 sub-tier; 404 kalau pemain belum ter-rating
```

### 4.3 Gate unlock

`handler/session.go Unlock` → bungkus `RequireAdmin` (dari handler ratings — pindahkan middleware ke package bersama atau duplikat kecil).

---

## 5. Security

| Risiko | Mitigasi |
|---|---|
| Token di sessionStorage → XSS | App tanpa konten user-generated (input player name — sanitized display). Acceptable untuk klub; Logout membersihkan |
| Token bocor via log | Jangan log Authorization header (middleware logging existing hanya method/path/status — cek) |
| Unlock sekarang open | Di-gate admin (perubahan perilaku — dokumentasikan) |
| Endpoint admin lain | Sudah token-protected (ingest/revert/finalize/rebuild) |
| Rate limit | Sudah global (per IP) |

**Catatan:** ini bukan sistem auth penuh (tidak ada user/password, tidak ada per-role). Satu token bersama = "admin tunggal" — sesuai skala klub. Upgrade ke multi-user (mis. Supabase Auth / JWT) di luar scope, tercatat sebagai backlog.

---

## 6. Edge Cases

| Kasus | Keputusan |
|---|---|
| Token salah / kedaluwarsa | 401 → admin sheet tutup + prompt login ulang |
| Token tidak pernah diset (dev) | `MAJADU_ADMIN_TOKEN` kosong → semua endpoint admin 401 (sudah perilaku handler) — admin sheet tampil "not configured" |
| Delete player yang punya riwayat sesi | `p_force=false` → ditolak FK → pesan "player has history" (atau `p_force=true` jika admin yakin — tombol konfirmasi) |
| Revert session yang belum diingest | Idempotent (no-op) — sudah |
| Unlock sesi yang sudah unlock | Idempotent (no-op) — sudah |
| Add player tanpa sesi aktif | Arahkan ke alur session (bukan form mandiri) |

---

## 7. Task List

### P0 — Backend endpoints & gate
- [x] 1. `PATCH /ratings/players/{id}/class` (validasi 12-tier, source='admin') → **`SetPlayerClass` (floor, tanpa rebuild)**
- [x] 2. `DELETE /players/{playerId}` (Go + delete_player SQL, transaksi: bersihkan rating → panggil fn) → **`DeletePlayer` (rating events/players dulu, lalu delete_player; ?force=)**
- [x] 3. Gate `Unlock` dengan RequireAdmin → **`AdminGuard` (shared middleware) — unlock 401 tanpa token**
- [x] 4. Unit test admin guard (401 tanpa/salah token, 200 benar) → **`TestAdminGuardAuth` PASS**
- [x] 4b. `PATCH /players/{id}/tier` (ubah tier induk → class ikut + recalculate RebuildAll) + `POST /players` param opsional `tier` → **`SetPlayerTier` + `SetPlayerTierOnRegister`**

**Verifikasi P0:** `make check` + integration live PASS.

### P1 — Frontend auth & admin area
- [x] 5. `AdminContext` (token di **localStorage** — persist sampai logout, Bearer otomatis, isAdmin, logout) — login UI "Admin password"
- [x] 6. Card "Admin Area" di HomePage (segmen terpisah, gaya amber) + popup login + berubah jadi Admin+Logout setelah login
- [x] 7. Halaman `/admin` lengkap: Session (unlock) · Rating (ingest/revert/**finalize** per source, rebuild-all) · Season (close & start, arsip link) · **Player (tier induk, class rating, hapus)** · banner amber + logout
- [x] 8. Admin badge di detail rating (ubah class dropdown via prompt)

**Verifikasi P1:** `npm run check` + browser flow (login → menu → aksi).

### P2 — Manajemen pemain di UI
- [x] 9. Add player (ke sesi) dari admin — navigasi alur session
- [x] 10. Delete player (konfirmasi, tanpa force — aman; player dengan riwayat sesi ditolak dengan pesan)
- [ ] 11. Edit player name (reuse register+alias) → **DITUNDA: rename canonical butuh endpoint khusus (register+alias = merge, bukan rename) — backlog**

**Verifikasi P2:** flow lengkap di browser; tanpa regresi alur normal.

### P3 — Polish
- [x] 12. Audit keamanan: middleware log tidak menyertakan header (aman); semua endpoint admin di-gate AdminGuard; delete tanpa force (default aman); token localStorage = XSS minimal (app tanpa user-generated content) — terdokumentasi
- [ ] 13. Visual pass (user) + update current-status → **current-status sudah di-update; visual pass menyusul**

---

## 8. Di Luar Scope

- Multi-user auth / per-role.
- Admin UI untuk mengedit skor langsung di sesi terkunci (cukup unlock → edit normal).
