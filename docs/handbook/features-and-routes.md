# Features And Routes

Dua peta terpisah: **rute web** (React Router) dan **operasi API** (kontrak OpenAPI).
Keduanya berbeda: halaman `/c/{slug}/rankings` memanggil `GET /c/{slug}/rankings`.

## 1. Rute web

Sumber tunggal: `apps/web/src/routes.manifest.ts:44-165`. `App.tsx` tidak mendaftar rute
satu per satu; ia memetakan manifest (`apps/web/src/App.tsx:21-45`).

Kolom **Akses** = `requiresAuth` + `roles`/`platformOwner` di manifest. Entri tanpa
`navGroup` tetap bisa dibuka lewat URL, tetapi tidak muncul di menu.

| Path | Halaman | Akses | Nav | Status |
|---|---|---|---|---|
| `/` | `HomePage` | login | main | daftar komunitas; klik → sesi komunitas |
| `/c/:slug` | `CommunityPage` | login, semua role | — | ringkasan + 4 setting efektif (baca-saja) |
| `/c/:slug/sessions` | `SessionsPage` | login, semua role | main | daftar sesi komunitas |
| `/c/:slug/sessions/:id` | `SessionPage` | login, semua role | — | detail sesi baca-saja: peserta, game, standings |
| `/c/:slug/players` | `PlaceholderPage` | login, semua role | main | **placeholder** |
| `/c/:slug/rankings` | `RankingsPage` | login, semua role | main | papan poin + filter tier |
| `/c/:slug/rankings/:playerId` | `RatingPlayerPage` | login, semua role | — | baris papan, statistik, badge |
| `/c/:slug/tournaments` | `TournamentsPage` | login, `admin`/`host` | main | daftar classic + team |
| `/c/:slug/tournaments/classic/new` | `TournamentClassicPage` | login, `admin`/`host` | — | wizard draw classic |
| `/c/:slug/tournaments/classic/:id` | `TournamentClassicPage` | login, `admin`/`host` | — | editor skor + klasemen |
| `/c/:slug/tournaments/team/new` | `TournamentTeamPage` | login, `admin`/`host` | — | form 6 tim × 6 kelas |
| `/c/:slug/tournaments/team/:id` | `TournamentTeamPage` | login, `admin`/`host` | — | editor partai + klasemen |
| `/c/:slug/export` | `ExportPage` | login, `admin`/`host` | main | ekspor post/story |
| `/c/:slug/settings` | `PlaceholderPage` | login, `admin` | admin | **placeholder** |
| `/s/:code` | `PlaceholderPage` | publik | — | **placeholder** (halaman share belum ada) |
| `/owner/communities` | `PlaceholderPage` | login, platform owner | owner | **placeholder** |

Catatan:

- `/c/:slug/sessions` dan `/c/:slug/sessions/:id` adalah **halaman baca-saja**. Belum
  ada UI untuk membuat sesi, mengubah skor, swap, absent, lock, atau share.
- `TournamentsPage` menautkan baris ke `/tournaments/{format}/{id}`, sehingga tombol
  classic/team memakai editor yang sama dengan rute `new` (`apps/web/src/pages/TournamentsPage.tsx`).
- Manifest membatasi turnamen & ekspor ke `host`/`admin`, sedangkan API mengizinkan
  `member` membaca turnamen. Yang dibatasi manifest adalah **navigasi/UI**, bukan API.
- Path `/ratings`, `/admin/*`, `/session/*`, `/instagram-post`, `/scoreboard`, `/view`
  dari v1 **tidak ada** di manifest v2.

## 2. Kapabilitas halaman

### Home & komunitas

- `HomePage`: jika tidak ada membership, tampilkan ajakan; jika ada, kartu per komunitas
  yang mengarah ke `/c/{slug}/sessions` (`apps/web/src/pages/HomePage.tsx`).
- `CommunityPage`: memuat `GET /c/{slug}/config`, menampilkan
  `community.default_timezone`, `community.directory_enabled`,
  `community.invite_ttl_days`, `community.join_requests_enabled` beserta sumbernya
  (`platform` atau `community`). Tidak ada form edit.
- `AppNav`: menu mengikuti role komunitas yang dipilih + status platform owner;
  `CommunityPicker` berpindah komunitas (`apps/web/src/components/AppNav.tsx`).

### Sesi

- `SessionsPage`: `GET /c/{slug}/sessions`, keadaan kosong/error/loading eksplisit,
  tautan ke detail.
- `SessionPage`: satu permintaan `GET /c/{slug}/sessions/{id}` (header, peserta, game)
  plus `GET /c/{slug}/sessions/{id}/standings`; menampilkan versi/status, pemain absen,
  skor per game, dan klasemen. Semua baca-saja (`apps/web/src/sessions/hooks.ts`).

### Ranking

- Papan: `GET /c/{slug}/rankings?tier=…`; daftar tier dari `apps/web/src/rankings/api.ts`
  (`D`…`A+`). Papan dibatasi server lewat `rank.board_limit` (200), bukan dipotong FE.
- Detail: `GET /c/{slug}/rankings/{playerId}` + `GET /c/{slug}/players/{playerId}/stats`
  + `GET /c/{slug}/players/{playerId}/achievements`. Badge dirender dari katalog
  `achievement.definitions`.

### Turnamen classic

- 16 pasangan, grup A–D, 32 match: 24 grup + 4 QF + 2 SF + 1 perebutan juara 3 + 1 final
  (`modules/tournament/domain/classic.nim:1-20`).
- Wizard membuat draw deterministik dari seed di browser (`ClassicNewPage.tsx`), lalu
  `POST /c/{slug}/tournaments`.
- Editor: ubah metadata, skor per match (`PATCH …/matches/{matchId}` dengan `If-Match`),
  klasemen grup, bracket. Admin mendapat alat rating: finalize source, ingest, revert,
  dan hapus turnamen (`apps/web/src/tournament/classic/AdminTools.tsx`,
  `apps/web/src/tournament/api.ts`).

### Turnamen team

- 6 tim × 6 kelas (`A+`…`C`), 9 match grup round-robin + 1 final, 3 partai per match
  (`modules/tournament/domain/team.nim`, `db/migrations/0012_tournament_formats.sql`).
- Editor menyunting skor partai dan tiga nama court per match; klasemen + juara
  dihitung di FE dari aturan yang sama dengan domain
  (`apps/web/src/tournament/team/rules.ts`).
- Admin dapat finalize/ingest/revert rating dan menghapus turnamen.

### Ekspor sosial

- `ExportPage`: pilih sumber (sesi atau turnamen), komposisi (grup, bracket, klasemen,
  final), lalu render `post` 1080×1350 atau `story` 1080×1920.
- Ukuran berasal dari config `export.*`, bukan konstanta
  (`apps/web/src/utils/canvas/dimensions.ts`, `ExportPage.tsx`).
- Sumber data: `GET …/sessions/{id}/standings` untuk sesi; snapshot turnamen untuk
  grup/bracket/team (`apps/web/src/tournament/export.ts`).

## 3. Operasi API

Sumber: `packages/contracts/openapi/core.yaml` + `community.yaml` → `api.yaml`;
daftar hasil generate di `apps/api/src/routes_gen.nim:13-680`. Jumlah: **74**
(`CONTRACT.sha256:7`, `apps/api/src/routes_gen.nim:682`).
Base URL kontrak: `https://api.qouver.com` (tanpa prefix path) atau
`http://127.0.0.1:8080` (`api.yaml`, `servers`).

Kolom **Akses** mengikuti `testdata/authz/matrix.yaml`; `sesi` berarti cookie
`majadu_session` + membership komunitas (kecuali operasi non-komunitas).

### `auth`

| Method | Path | Akses |
|---|---|---|
| `POST` | `/auth/start` | publik* |
| `GET` | `/auth/callback` | publik |
| `POST` | `/auth/logout` | sesi |
| `GET` | `/auth/me` | sesi |
| `GET` | `/auth/sessions` | sesi |
| `DELETE` | `/auth/sessions` | sesi |

**Catatan:** Implementasi memanggil `startAuth` tanpa cek sesi; matrix menandainya `session`.
Praktisnya ini titik masuk login, jadi harus bisa diakses tanpa cookie.

### `system`

| Method | Path | Akses |
|---|---|---|
| `GET` | `/healthz` | publik |
| `GET` | `/readyz` | publik (cek DB) |
| `GET` | `/version` | publik |

### `community`

| Method | Path | Akses |
|---|---|---|
| `GET` | `/communities` | sesi (daftar membership sendiri) |
| `POST` | `/communities` | sesi + platform owner |
| `GET` | `/directory` | publik* (entri yang opt-in; anggota melihat miliknya) |
| `POST` | `/c/{slug}/join-requests` | publik* (selalu `202`, anti-enumerasi) |
| `GET` | `/c/{slug}/join-requests` | sesi + admin |
| `PATCH` | `/c/{slug}/join-requests/{id}` | sesi + admin |
| `POST` | `/c/{slug}/invites` | sesi + admin |
| `POST` | `/invites/{token}/accept` | sesi |
| `GET` | `/c/{slug}/members` | sesi (anggota) |
| `PATCH` | `/c/{slug}/members/{userId}` | sesi + admin |
| `DELETE` | `/c/{slug}/members/{userId}` | sesi + admin |
| `GET` | `/c/{slug}/settings` | sesi (anggota) |
| `PATCH` | `/c/{slug}/settings` | sesi + admin |
| `GET` | `/c/{slug}/config` | sesi (anggota) |

**Catatan:** `GET /directory` dan `POST …/join-requests` memakai `currentUser` opsional; tanpa
sesi keduanya tetap menjawab (daftar publik / `202`). Matrix menandainya `session`
sebagai niat kontrak, bukan perilaku handler.

### `players`

| Method | Path | Akses |
|---|---|---|
| `GET` | `/c/{slug}/players` | sesi (anggota) |
| `POST` | `/c/{slug}/players` | sesi + host/admin |
| `GET` | `/c/{slug}/players/{playerId}` | sesi (anggota) |
| `PATCH` | `/c/{slug}/players/{playerId}` | sesi + host/admin |
| `DELETE` | `/c/{slug}/players/{playerId}` | sesi + admin* |
| `GET` | `/c/{slug}/players/{playerId}/stats` | sesi (anggota) |
| `GET` | `/c/{slug}/players/{playerId}/achievements` | sesi (anggota) |
| `POST` | `/c/{slug}/players/{playerId}/claims` | sesi (anggota) |
| `GET` | `/c/{slug}/players/{playerId}/claims` | sesi (anggota) |
| `PATCH` | `/c/{slug}/players/{playerId}/claims/{claimId}` | sesi + admin* |
| `DELETE` | `/c/{slug}/players/{playerId}/claim` | sesi (anggota) |
| `POST` | `/c/{slug}/players/{playerId}/merge` | sesi + admin* |

**Catatan:** `DELETE player`, `PATCH claim`, dan `POST merge` memakai `adminGate` (admin saja),
walau matrix menulis `host,admin`. `createPlayer`/`PATCH player` tetap host/admin.

### `sessions`

| Method | Path | Akses |
|---|---|---|
| `GET` | `/c/{slug}/sessions` | sesi (anggota) |
| `POST` | `/c/{slug}/sessions` | sesi + host/admin |
| `GET` | `/c/{slug}/sessions/{id}` | sesi (anggota) |
| `PATCH` | `/c/{slug}/sessions/{id}` | sesi + host/admin |
| `DELETE` | `/c/{slug}/sessions/{id}` | sesi + host/admin |
| `PUT` | `/c/{slug}/sessions/{id}/schedule` | sesi + host/admin |
| `PATCH` | `/c/{slug}/sessions/{id}/absent` | sesi + host/admin |
| `GET` | `/c/{slug}/sessions/{id}/games/{gameKey}` | sesi (anggota) |
| `PATCH` | `/c/{slug}/sessions/{id}/games/{gameKey}` | sesi + host/admin |
| `PATCH` | `/c/{slug}/sessions/{id}/games/{gameKey}/skip` | sesi + host/admin |
| `POST` | `/c/{slug}/sessions/{id}/swap` | sesi + host/admin |
| `POST` | `/c/{slug}/sessions/{id}/lock` | sesi + host/admin |
| `POST` | `/c/{slug}/sessions/{id}/unlock` | sesi + host/admin |
| `GET` | `/c/{slug}/sessions/{id}/standings` | sesi (anggota) |

`gameKey` = `{round}-{court}` (0-based), sama dengan kunci unik di `session.games`
(`modules/session/schedule.nim:23-31`). Mutasi memakai `If-Match` versi sesi; yang
mendukung juga menerima `Idempotency-Key`.

### `share`

| Method | Path | Akses |
|---|---|---|
| `POST` | `/c/{slug}/sessions/{id}/share` | sesi + host/admin |
| `GET` | `/c/{slug}/sessions/{id}/share` | sesi + host/admin |
| `DELETE` | `/c/{slug}/sessions/{id}/share` | sesi + host/admin |
| `GET` | `/s/{code}` | publik |

### `rankings`

| Method | Path | Akses |
|---|---|---|
| `GET` | `/c/{slug}/rankings` | sesi (anggota) |
| `GET` | `/c/{slug}/rankings/{playerId}` | sesi (anggota) |
| `GET` | `/c/{slug}/rating-sources` | sesi + admin* |
| `PATCH` | `/c/{slug}/rating-sources/{id}` | sesi + admin |
| `POST` | `/c/{slug}/ratings/rebuild` | sesi + admin |
| `POST` | `/c/{slug}/sessions/{id}/rating` | sesi + admin |
| `DELETE` | `/c/{slug}/sessions/{id}/rating` | sesi + admin |
| `POST` | `/c/{slug}/tournaments/{id}/rating` | sesi + admin |
| `DELETE` | `/c/{slug}/tournaments/{id}/rating` | sesi + admin |
| `GET` | `/s/{code}/rankings` | publik |
| `GET` | `/s/{code}/rankings/{playerId}` | publik |

**Catatan:** Handler `rating-sources` hanya menerima admin (`adminGate`), walau matrix menulis
`session`; lihat `apps/api/src/app.nim` cabang `ratings/rating-sources`.

### `tournaments`

| Method | Path | Akses |
|---|---|---|
| `GET` | `/c/{slug}/tournaments` | sesi (anggota) |
| `POST` | `/c/{slug}/tournaments` | sesi + host/admin |
| `GET` | `/c/{slug}/tournaments/{id}` | sesi (anggota) |
| `PUT` | `/c/{slug}/tournaments/{id}` | sesi + host/admin |
| `DELETE` | `/c/{slug}/tournaments/{id}` | sesi + host/admin |
| `PATCH` | `/c/{slug}/tournaments/{id}/matches/{matchId}` | sesi + host/admin |

`PUT` mengganti snapshot penuh dengan `If-Match`; `PATCH` hanya menyentuh satu match
(`apps/api/src/app.nim:1780-1890`).

### `realtime`

| Method | Path | Akses |
|---|---|---|
| `POST` | `/c/{slug}/sessions/{id}/ws-ticket` | sesi (anggota) |
| `POST` | `/s/{code}/ws-ticket` | publik |
| `GET` | `/ws/c/{slug}/sessions/{id}` | sesi + ticket sekali pakai |
| `GET` | `/ws/share/{code}` | publik + ticket sekali pakai |

WebSocket **bukan** SSE. Ticket diterbitkan endpoint `ws-ticket`, lalu dipakai sebagai
query `?ticket=…` saat upgrade; ticket hangus setelah dipakai
(`apps/api/src/ws_ticket.nim`, `apps/api/src/app.nim:1676-1710`).

## 4. Rute di luar kontrak

Handler berikut ada di server tetapi tidak dipublikasikan di OpenAPI:

| Method | Path | Akses | Sumber |
|---|---|---|---|
| `GET` | `/ops/ping` | bearer ops token | `apps/api/src/app.nim:1943-1946` |
| `DELETE` | `/c/{slug}/rating-sources/{id}` | sesi + admin | `apps/api/src/app.nim` cabang `rating-sources` |

Jangan menambahkannya ke klien publik tanpa memperbarui `core.yaml`/`community.yaml`
lebih dulu; `./task contract-check` tidak akan melihatnya sampai spec berubah.
