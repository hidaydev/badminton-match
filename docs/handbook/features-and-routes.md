# Features And Routes

Dua peta terpisah: **rute web** (React Router) dan **operasi API** (kontrak OpenAPI).
Keduanya berbeda: halaman `/c/{slug}/rankings` memanggil `GET /c/{slug}/rankings`.

## 1. Rute web

Sumber tunggal: `apps/web/src/App.tsx`. `apps/web/src/routes.manifest.ts` hanya
menyediakan helper path (`communitySlugFromPath`, `communityHref`); file itu tidak
lagi memetakan rute atau menu.

Semua layar lama berada di bawah `/c/:slug` lewat `LegacyShell`; URL publik
`/s/:code` dan `/invites/:token` berada di luar shell itu.

| Path | Halaman | Akses | Catatan |
|---|---|---|---|
| `/` | `RootRedirect` | login | arahkan ke komunitas aktif |
| `/owner/communities` | `OwnerSetupPage` (`pages/SetupPage.tsx`) | platform owner | buat komunitas + daftar komunitas |
| `/c/:slug` | legacy `HomePage` | login | hub: sesi baru, lanjut sesi, kartu navigasi, grid admin |
| `/c/:slug/sessions` | legacy `SessionListPage` | login | daftar sesi |
| `/c/:slug/sessions/:id` | redirect | login | dialihkan ke `/c/:slug/s/:id` |
| `/c/:slug/s/:sessionId` | legacy `SharedSessionPage` | login | halaman sesi penuh: skor, swap, absent, skip |
| `/c/:slug/scoreboard` | legacy `ScoreboardPage` | login | skor courtside |
| `/c/:slug/rankings` | legacy `RankingsPage` | login | papan poin + filter tier |
| `/c/:slug/rankings/:playerId` | legacy `RatingPlayerPage` | login | detail rating, riwayat, badge |
| `/c/:slug/ratings`, `/ratings/:playerId` | redirect | login | dialihkan ke `/rankings` |
| `/c/:slug/tournaments` | legacy `TournamentListPage` | login | daftar classic + team |
| `/c/:slug/tournaments/new` | legacy `NewTournamentPage` | admin/host | pilih format |
| `/c/:slug/tournaments/new/:format` | legacy `NewTournamentWizard` | admin/host | wizard classic/team |
| `/c/:slug/tournaments/:id` | legacy `TournamentRouter` | login | editor skor + klasemen/bracket |
| `/c/:slug/instagram-post` | legacy `InstagramPostPage` | admin/host | post 1080×1350 dan story 1080×1920 |
| `/c/:slug/export` | redirect | admin/host | dialihkan ke `/instagram-post` |
| `/c/:slug/settings` | `SettingsPage` | admin | anggota, peran, undangan, join request |
| `/c/:slug/players` | `PlayersPage` | login | roster v2, tambah pemain, klaim |
| `/c/:slug/players/:playerId` | `PlayerDetailPage` | login | detail, edit, merge, hapus, klaim |
| `/c/:slug/admin` | redirect | admin/host | dialihkan ke `/admin/sessions` |
| `/c/:slug/admin/sessions` | legacy `AdminSessionsPage` | admin/host | unlock dan hapus sesi |
| `/c/:slug/admin/ratings` | legacy `AdminRatingsPage` | admin | sumber rating, ingest, revert, rebuild |
| `/c/:slug/admin/players` | redirect | admin/host | dialihkan ke `/players` |
| `/c/:slug/admin/tournaments` | legacy `AdminTournamentsPage` | admin/host | hapus turnamen |
| `/c/:slug/session/new` | legacy `SetupPage` | admin/host | wizard sesi: setup |
| `/c/:slug/session/players` | legacy `PlayersWizardPage` | admin/host | wizard sesi: pemain |
| `/c/:slug/session/constraints` | legacy `ConstraintsPage` | admin/host | wizard sesi: constraint |
| `/c/:slug/session/generate` | legacy `GeneratePage` | admin/host | wizard sesi: generate + publish |
| `/c/:slug/view` | `SharedViewPage` | login | buka snapshot share lama (kompatibilitas) |
| `/c/:slug/dev/achievement-badges` | preview | login | hanya pengembangan |
| `/c/:slug/dev/match-result-preview` | preview | login | hanya pengembangan |
| `/c/:slug/dev/session-preview` | preview | login | hanya pengembangan |
| `/invites/:token` | `InvitePage` (`pages/InvitePage.tsx`) | publik | terima undangan; login dengan URL ini sebagai `returnTo` |
| `/s/:code` | `SharedSessionPage` | publik | sesi read-only dari share code, tab Games/Standings |

Catatan:

- Navigasi tidak memakai menu global. `HomeLayout` memuat picker komunitas,
  refresh, dan menu akun. Menu akun hanya berisi identitas + role komunitas,
  `Community settings` (admin), `All communities` (platform owner), dan
  `Sign out`; tidak ada tautan Admin di dalamnya. Perpindahan layar lewat kartu
  di home.
- `HomePage` hanya menampilkan CTA New Session dan grid admin untuk staf
  (`isAdmin` = host atau admin). Grid memuat Unlock Session dan Tournament untuk
  staf, plus Ratings dan Settings khusus admin komunitas (`isAdminRole`).
- Matriks akses: `member` hanya halaman baca; `host` menambah sesi/turnamen
  (wizard, admin sessions/tournaments, post editor); `admin` menambah Settings,
  Ratings, dan pengelolaan anggota. Platform owner mengelola komunitas lewat
  `/owner/communities`.
- Rute v2 yang tidak pernah dipasang di router (home, sessions, rankings,
  tournaments, export) sudah dihapus beserta renderer canvas dan editor
  turnamen v2. Editor turnamen aktif adalah milik legacy.
- `/c/:slug/s/:sessionId` adalah halaman sesi yang bisa diedit dan hanya untuk
  anggota login. `/s/:code` adalah tampilan publik read-only.
- Tautan publik hanya `/s/:code` yang dibuat tombol Share; URL anggota
  `/c/:slug/s/:sessionId` selalu meminta login dan bukan tautan untuk dibagikan.
- `/s/:code` memakai susunan layar sesi di aplikasi: tab **Games** dan
  **Standings**. `GET /s/{code}` mengirim `games` dan `standings` (tally yang sama
  dengan `GET /c/{slug}/sessions/{id}/standings`, tanpa id pemain).
- `/invites/:token` sengaja di luar shell komunitas: akun baru saja bergabung, jadi
  layar itu tidak boleh menuntut membership lebih dulu.

## 2. Kapabilitas halaman

### Home & komunitas

- Home legacy: tombol sesi baru, kartu lanjut sesi terakhir, kartu Sessions,
  Players, Rankings, Scoreboard, Tournament, Instagram Post, dan entry
  `All communities` untuk platform owner.
- `SettingsPage` (v2): anggota, perubahan peran, undangan, dan join request.
  Ledger rating tidak lagi di sini; gunakan `/admin/ratings`.
- `OwnerSetupPage`: membuat komunitas dan menampilkan komunitas yang diikuti.

### Sesi

- `SessionListPage`: daftar sesi dengan jumlah pemain dan game.
- `SharedSessionPage` legacy: skor per game, tandai played, swap pemain/slot/tim,
  absent, dan skip per pemain; data lewat adapter `legacy/queries`.
- `SharedSessionPage` publik: read-only berdasarkan share code.
- Scoreboard legacy tetap tersedia di `/c/:slug/scoreboard`.

### Pemain

- `/players`: roster v2, pencarian, tambah pemain, dan klaim.
- `/players/:playerId`: detail, edit nama/gender/tier/alias, merge, hapus, dan
  keputusan klaim. Ini satu-satunya permukaan manajemen pemain; admin lama
  `/admin/players` dialihkan ke sini.

### Ranking

- `RankingsPage` legacy: papan poin + filter tier.
- `RatingPlayerPage` legacy: baris papan, statistik, riwayat, dan badge.

### Turnamen

- `TournamentListPage` + `TournamentRouter`: daftar, editor classic dan team,
  klasemen/bracket.
- `AdminTournamentsPage`: hapus turnamen.
- Rating turnamen tetap lewat `/admin/ratings`.

### Post

- `InstagramPostPage`: memilih sesi atau turnamen, lalu merender post atau story
  dengan template legacy (`legacy/utils/canvasPost.ts` dan
  `legacy/config/instagramTemplates.ts`).
- Ukuran dan konfigurasi tetap berasal dari config komunitas, bukan konstanta.
## 3. Operasi API

Sumber: `packages/contracts/openapi/core.yaml` + `community.yaml` → `api.yaml`;
daftar hasil generate di `apps/api/src/routes_gen.nim`. Jumlah: **75**
(`CONTRACT.sha256`, baris `operations 75`).
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

**Catatan undangan:** login meng-claim setiap undangan yang tertuju ke alamat akun
itu, jadi `POST /invites/{token}/accept` idempoten untuk alamat pemiliknya: token
yang sudah di-claim tetap menjawab `201` dengan membership yang diberikan, sedangkan
alamat lain tetap `403 INVITE_EMAIL_MISMATCH`.

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

**Catatan:** `DELETE player`, `PATCH claim`, dan `POST merge` adalah admin saja. `matrix.yaml`
menyatakan hal yang sama, dan satu tabel (`apps/api/src/route_access.nim`) dipakai baik oleh
dispatch maupun oleh test yang membandingkannya dengan matrix. `createPlayer`/`PATCH player`
tetap host/admin.

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

`GET /s/{code}` mengirim `session`, `community`, `games`, dan `standings`.
`standings.items[]` berisi `name`, `wins`, `losses`, `pointsFor`, `pointsAgainst`,
dan `diff` — nama, bukan id pemain, karena penonton tidak punya sesi untuk
meresolve uuid. `standings` memakai tally yang sama dengan
`GET /c/{slug}/sessions/{id}/standings`.

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

**Catatan:** `ratings` dan `rating-sources` adalah admin saja, dan `matrix.yaml` menyatakan hal
yang sama; kelas aksesnya ditentukan `apps/api/src/route_access.nim`.

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
