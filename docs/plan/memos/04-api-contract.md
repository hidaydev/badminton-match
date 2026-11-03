# 04 — API Contract (v2, Nim)

> Peran: arsitek API/kontrak. Lingkup: kontrak saja (bukan skema DB, bukan isi engine rating).
> Sifat: proposal untuk panel. Semua klaim kode dirujuk `path:line`.
> Keputusan owner yang dipakai: kontrak **boleh pecah**, FE **akan dirombak**, auth host/admin
> lewat **Google OAuth**, **ranking points tetap**.

## 0. Ringkasan keputusan

| # | Keputusan | Alasan singkat |
|---|---|---|
| 1 | `/sessions` publik tidak pernah memuat kapabilitas tulis; identitas publik = `id` (UUIDv7), kapabilitas = cookie sesi (host) atau `share code` yang dicetak sekali | P0-1 `05-security.md:35-49` — sekarang `share_code` dikirim sebagai `id` (`store/session_admin.go:187`, rute tanpa guard `cmd/server/main.go:195`) |
| 2 | Semua tulis butuh principal; tidak ada `POST` anonim | P0-2 `05-security.md:51-64` (rantai pemalsuan poin) |
| 3 | Token admin statis hilang; `/admin/verify` dihapus | oracle brute-force + token tanpa TTL `05-security.md:80-85`, `handler/admin.go:18-20` |
| 4 | Realtime = **WebSocket** yang membawa *notifikasi*, bukan snapshot | `majadu/docs/DECISIONS.md:1303-1330` (D-050); v1 mengirim dokumen penuh per tulisan (`handler/session.go:280-305`) |
| 5 | OpenAPI **tulisan tangan** sebagai sumber kebenaran, rute Nim **di-generate** dari situ | pola majadu `task:1153-1182`; Nim tidak punya generator OpenAPI yang layak |

Jumlah rute: **48 → 48**. Tujuh rute v1 dihapus tanpa penerus, dua pasang dilebur, sembilan rute v2
benar-benar baru. Tabel di §1 adalah sumber kebenarannya (bukan aritmetika satu-satu).

## 1. Route inventory delta

Kolom aksi: **K** = tetap, **C** = berubah bentuk/nama, **D** = dihapus, **A** = baru.

### 1.1 System & auth (5 v1 → 6 v2)

| v2 | v1 | Aksi | Alasan |
|---|---|---|---|
| `GET /healthz` | sama | K | liveness; jangan dipakai deploy lagi (`02-backend.md:249-257`) |
| `GET /readyz` | sama | C | body `{status, checks[]}`, satu query nyata — sekarang hanya `Ping` |
| `GET /version` | sama | K | — |
| `GET /metrics` | sama | D | pindah ke listener internal/loopback; publik = enumerasi counter (`05-security.md:134-138`) |
| `GET /admin/verify` | sama | D | diganti `GET /auth/me` (`roles[]`) |
| `POST /auth/google` | — | A | tukar Google ID token → cookie `HttpOnly` sesi |
| `POST /auth/logout` | — | A | hapus cookie; `204` |
| `GET /auth/me` | — | A | `{accountId, name, roles[], playerId?}`; satu-satunya cek identitas |

`/metrics` tidak masuk kontrak publik; ia hidup di port internal yang sama dengan health (`ops` memo).

### 1.2 Sessions (16 v1 → 13 v2)

| v2 | v1 | Aksi | Alasan |
|---|---|---|---|
| `GET /sessions` | sama | C | `{items[],nextCursor}`; **tanpa** kapabilitas tulis, tanpa `limit:0` = semua baris (`handler/session.go:128-133`) |
| `POST /sessions` | sama | C | host/admin; tanpa `EnsurePlayersRegistered` di luar tx (`handler/session.go:156-159`, `02-backend.md:320`) |
| `GET /sessions/{id}` | sama | C | `id` = UUIDv7 publik; `ETag`; `shareCode` tidak pernah muncul |
| `PATCH /sessions/{id}` | sama | C | host/admin + `If-Match` wajib |
| `DELETE /sessions/{id}` | sama | C | host (draft) / admin (semua status); `204` |
| `POST /sessions/{id}/lock` | sama | C | host/admin — dulu admin-only, itu sebab FE butuh token admin |
| `POST /sessions/{id}/unlock` | sama | C | host/admin; `204` |
| `PUT /sessions/{id}/schedule` | `PUT /sessions/{id}` | C | **hanya** config+players+fixMatches+schedule; skor/absent tidak bisa lewat sini (menutup `01-frontend.md:62-84`) |
| `GET /sessions/{id}/games/{gameKey}` | sama | K | sumber `version` per game untuk OCC |
| `PATCH /sessions/{id}/games/{gameKey}` | sama | C | body eksplisit `{"score":{"a","b"}}` xor `{"played":bool}` — hapus union ambigu (`handler/granular.go:137-149`) |
| `PATCH /sessions/{id}/games/{gameKey}/skip` | sama | K | — |
| `PATCH /sessions/{id}/absent` | sama | K | — |
| `POST /sessions/{id}/swap` | sama | K | — |
| `GET /sessions/{id}/watch` | sama | D | diganti `…/ws` |
| `GET /sessions/{id}/events` | sama | D | tidak ada klien FE yang memakainya; catch-up = baca ulang (`majadu/docs/DECISIONS.md:50-54`) |
| `POST /sessions/{id}/delete` | sama | D | satu bentuk hapus: `DELETE` |

Catatan: `PUT /sessions/{id}` v1 adalah *create-or-update* (`handler/session.go:362-371`) sehingga
penyerang bisa membuat sesi pada id pilihannya (`05-security.md:100-105`). v2: `PUT` pada id tak dikenal
= `404`.

### 1.3 Share (3 v2, semua baru) & realtime (2 v2, semua baru)

| v2 | Aksi | Alasan |
|---|---|---|
| `POST /sessions/{id}/share` | A | host mencetak kode; respons memuat kode **sekali**, server menyimpan hash |
| `DELETE /sessions/{id}/share` | A | revoke; menutup socket spektator (`majadu/docs/DECISIONS.md:1334-1360`) |
| `GET /s/{code}` | A | satu-satunya baca anonim; payload diredaksi (`D-006b`, `majadu/docs/DECISIONS.md:81-86`) |
| `GET /sessions/{id}/ws` | A | kanal host/guest (cookie) |
| `GET /s/{code}/ws` | A | kanal spektator (kode = kapabilitas) |

`GET /sessions/{id}` tetap memuat `shareEnabled: bool` supaya FE tahu ada link tanpa bisa membacanya.

### 1.4 Players (7 v1 → 8 v2)

| v2 | v1 | Aksi | Alasan |
|---|---|---|---|
| `GET /players` | sama | C | `?q=&cursor=`; `{items,nextCursor}` |
| `POST /players` | sama | C | host/admin (dulu anonim → name squatting `05-security.md:93-98`) |
| `GET /players/{playerId}` | `GET /ratings/players/{playerId}` | C | satu profil; parameter UUID divalidasi (`handler/ratings.go:281-293` masih 500) |
| `PATCH /players/{playerId}` | `PATCH …/tier` + `PATCH …/name` | C | satu patch `{name?,tier?,gender?}`; dua rute → satu |
| `DELETE /players/{playerId}` | sama | K | `?force=true` dipertahankan |
| `GET /players/{playerId}/stats` | `GET /players/{name}/stats` | C | nama berubah dan perlu encode; id stabil (`handler/player.go:181-193`) |
| `GET /players/{playerId}/achievements` | `GET /ratings/players/{playerId}/achievements` | C | achievement itu milik pemain, bukan rating |
| `POST /players/{playerId}/merge` | `POST /players/merge` | C | target di path, source di body (`majadu/apps/api/src/routes.nim:166-167`) |

### 1.5 Tournaments (6 v1 → 6 v2)

| v2 | v1 | Aksi | Alasan |
|---|---|---|---|
| `GET /tournaments` | sama | C | paginasi + `?format=` |
| `POST /tournaments` | sama | C | admin (`05-security.md:66-71`) |
| `GET /tournaments/{id}` | sama | K | tetap publik |
| `PUT /tournaments/{id}` | sama | C | tanpa create; `If-Match` wajib |
| `DELETE /tournaments/{id}` | `POST …/delete` | C | verb yang benar; `204` |
| `PATCH /tournaments/{id}/matches/{matchId}` | — | A | skor satu match; menghapus jebakan "PATCH hanya classic" (`handler/tournament.go:313-345`, `02-backend.md:164-172`) |
| `PATCH /tournaments/{id}` | sama | D | full-replace bracket hanya lewat `PUT` |

### 1.6 Rankings & ratings (14 v1 → 10 v2)

| v2 | v1 | Aksi | Alasan |
|---|---|---|---|
| `GET /rankings` | sama | C | `?asOf=&minSessions=&limit=&cursor=`; `limit` dibatasi (sekarang tak terbatas) |
| `GET /rankings/{playerId}` | `GET /rankings/players/{playerId}` | C | ratakan; tetap `{found,row,minSessions}` |
| `GET /rating-sources` | `GET /ratings/sources` | C | admin-only (ledger operasional) |
| `POST /sessions/{id}/rating` | `POST /ratings/ingest-session` | C | sumbernya sesi, bukan "ratings" |
| `DELETE /sessions/{id}/rating` | `POST /ratings/revert-session` | C | idem |
| `POST /tournaments/{id}/rating` | `POST /ratings/ingest-tournament` | C | idem |
| `DELETE /tournaments/{id}/rating` | `POST /ratings/revert-tournament` | C | idem |
| `POST /rating-sources/{id}/replay` | `POST /ratings/replay-source` | C | `kind` diturunkan dari baris, bukan dari klien |
| `PATCH /rating-sources/{id}` | `POST /ratings/sources/{id}/finalize` | C | `{finalized:bool}` pada resource |
| `POST /ratings/rebuild` | `rebuild-all` + `replay-all` | C | body `{mode:"events"\|"sources"}` |
| `POST /ratings/achievements/backfill` | sama | D | one-off; jalankan lewat job/CLI admin |

### 1.7 Bentuk yang WAJIB berubah karena keamanan

1. **`share_code` hilang dari semua representasi.** Dulu: `SessionMeta.ID = share_code` dari
   `GET /sessions` (`store/session_admin.go:186-198`) = daftar kunci tulis. v2: `id` publik opaque,
   kode hanya keluar dari `POST /sessions/{id}/share` dan hanya sekali.
2. **Tidak ada `POST` anonim.** `POST /sessions`, `POST /players`, `POST/PUT/PATCH /tournaments` v1
   tanpa guard (`cmd/server/main.go:196,226,231-234`) → rantai `auto-lock` → ticker ingest
   (`main.go:82-161`). v2: 401 tanpa principal.
3. **Token admin statis diganti principal + role.** Header `Authorization: Bearer` hanya untuk
   service token ops (rate-limit khusus, diaudit) bila memang perlu; semua rute admin memakai cookie.
4. **`Allow-Origin: *` pada stream dihapus** (`handler/session.go:263`); WS same-origin.
5. **`PUT` tidak lagi membuat resource** — menutup identifier squatting.

## 2. Konvensi

- **Path**: kata benda plural, kebab-case (`rating-sources`), id di path = `{id}`/`{code}`/`{playerId}`,
  nesting maksimum 3. Pengecualian "command resource" (POST pada sub-path, bukan CRUD):
  `/lock`, `/unlock`, `/share`, `/replay`, `/rebuild`, `/rating`.
- **JSON**: `camelCase` di semua resource. v1 mencampur (`domain/snapshot.go:12-22` camelCase vs
  board ranking snake_case di `apps/web/src/queries/endpoints.ts:600-616`); satu gaya.
- **Versi**: tanpa digit di path. Pemisah versi = mount (`…/api`), kontrak dipatok di
  `info.version` (semver) OpenAPI; di dalam satu mount hanya perubahan aditif. Alasan: satu-satunya
  klien adalah FE kita sendiri di origin yang sama; `/majadu` v1 tetap hidup di prefix sendiri
  (`ops/caddy/Caddyfile.api.qouver.com:7-8`), jadi tidak perlu `v2` di path.
- **Error**: `application/problem+json` (RFC 9457) — `{type,title,status,code,i18nKey,traceId,detail?,params?,errors[]}`.
  `code` stabil & machine-readable; `detail` teknis, bukan copy user; FE menerjemahkan `i18nKey`.
  v1 `{error:{code,message}}` (`httperr/httperr.go:125-131`) dipensiunkan. `errors[]` untuk validasi:
  `[{path:"schedule[3].teamA",code:"unknown_player"}]`.
- **Paginasi**: cursor `?cursor=&limit=` → `{items[],nextCursor}`. Default 50, maks 200; daftar sesi
  publik default 20, maks 50.
- **Filter**: whitelist per koleksi (`date`,`q`,`format`,`status`,`asOf`,`minSessions`). Parameter tak
  dikenal / tanggal tidak valid → `400`, bukan `500` (`02-backend.md:174-182`).
- **Idempotency**: `Idempotency-Key` wajib pada `POST` (kecuali `/auth/*`), opsional pada
  `PATCH`/`PUT`/`DELETE`. Kunci = `(key, method, route, principalId)`, disimpan di tabel dengan
  `bodySha256`; body berbeda → `409 idempotency_key_reused`. Bukan cache in-memory
  (`handler/idempotency.go:11-17`, `02-backend.md:114-126`).
- **Concurrency**: `ETag: "v<n>"` pada setiap representasi resource ber-versi; `If-Match` wajib pada
  semua mutasi; absen → `428 precondition_required`, basi → `412 version_mismatch` (v1 memakai `409`
  untuk keduanya: `handler/session.go:41-42`, `httperr/httperr.go:87-98`). Game tetap punya versi
  sendiri (`ETag "g<n>"`) karena live scoring menulis per game; sesi punya versi agregat.
  Body `version` sebagai fallback **dihapus** (`handler/session.go:338-349`) — satu tempat membaca versi.
- **Ukuran request**: kelas per rute ala majadu (`majadu/apps/api/src/routes.nim:33-37`):
  auth/player 64 KiB, schedule/tournament 256 KiB, cap keras 1 MiB di mana pun → `413`.
  Plus invariant domain: `courts` 1..12, `schedule` ≤ 400, `fixMatches` ≤ 60 (`02-backend.md:73-87`).
- **Waktu**: `date` = `YYYY-MM-DD` tanpa offset, hari kalender **Asia/Jakarta** (WIB) — sesi bukan
  instant. `createdAt`/`updatedAt`/`earnedAt` = RFC 3339 UTC ber-`Z`. Satu helper tanggal WIB
  (bug `todayDate()` di `02-backend.md:306`).
- **Cache**: `no-store` untuk semua yang membawa kapabilitas/identitas; `public, max-age=15` untuk
  `/rankings` dan daftar turnamen.
- **Status**: `201` + `Location` untuk create; `204` untuk delete/lock/unlock/logout; jangan `200 {ok:true}`.

## 3. Realtime

### 3.1 Perbandingan

| | v1 SSE `/sessions/{id}/watch` | v1 `/events` | majadu v2 `/ws` |
|---|---|---|---|
| Payload | snapshot **penuh** tiap broadcast (`handler/session.go:280-305`) | `OutboxEvent[]` + `nextSince` (`handler/granular.go:22-57`, `domain/outbox.go:7-16`) | `{"type":"ready"}` / `{"type":"session.changed"}` — tanpa state (`majadu/apps/api/src/live.nim:1-33`) |
| Catch-up | muat ulang penuh tiap pesan | replay by id | baca ulang endpoint baca biasa (`DECISIONS.md:1303-1330`) |
| Batas koneksi | tidak ada (`05-security.md:107-112`) | — | per-kode 50 / per-IP 150 / proses 500 + TTL (`DECISIONS.md:1334-1360`) |
| Origin | `Access-Control-Allow-Origin: *` hardcoded (`handler/session.go:263`) | — | same-origin |

### 3.2 Pilihan: WebSocket, frame notifikasi

Alasan: (a) snapshot penuh per keystroke = proyeksi kedua dari baris yang sama — v1 harus menjaga
`Load` dan payload SSE tetap sinkron; (b) WS memberi frame tutup eksplisit (`expired`/`full`/`revoked`)
sehingga klien membedakan "server menutup" dari "jaringan putus"; (c) `mummy` 0.4.x tidak punya jalur
streaming, sedangkan hub WS sudah berjalan di majadu (`DECISIONS.md:1303-1306`).

Envelope (semua field selain `type` opsional, klien mengabaikan `type` tak dikenal):

```
{"type":"ready"}                                   // tepat sekali setelah upgrade
{"type":"session.changed"}                         // setelah setiap tulis yang commit
{"type":"pong"}                                    // jawaban atas {"type":"ping"} klien
{"type":"expired"}                                 // TTL spektator habis; klien reconnect
{"type":"full"}                                    // kuota koneksi penuh; tutup
{"type":"revoked"}                                 // share code dicabut; tutup
```

- Upgrade diotorisasi **sebelum** `101`: cookie sesi (member) atau kode (spektator), dan resource
  harus ada — penolakan = problem JSON biasa, bukan handshake gagal.
- **Tidak ada nomor versi di frame.** Versi hidup di resource; OCC per game sudah menjawab "salinanmu
  basi" dengan `412`. Menambah versi di kanal = jam ketiga (`DECISIONS.md:1317-1320`).
- Klien **wajib** punya aturan "update tidak menghapus ketikan": draft yang berbeda dari nilai server
  dipertahankan (`DECISIONS.md:1326-1329`). Tanpa itu, echo akan menimpa input.
- Klien `ping` tiap 25 s (memperbaiki limit majadu "no server heartbeat"); 2 `pong` hilang → reconnect.
- Reconnect: backoff 500 ms → 15 s berjitter, reset saat `open`, retry langsung pada `online`.
  Setelah `open` → `ready` → **selalu** `GET` sekali (catch-up), lalu berhenti (bukan polling).
- Batas: 50 socket/sesi, 20 anonim/IP, 500/proses; TTL spektator 60 menit.
- Shutdown: tutup semua socket dengan `expired` sebelum `srv.Shutdown` selesai
  (v1 menggantung 5 s karena SSE tak pernah idle, `02-backend.md:284-294`).

## 4. Contract-first workflow

**Sumber kebenaran: `packages/contracts/openapi/api.yaml` (tulisan tangan, direview).**
Jangan mencoba men-generate OpenAPI dari tipe Nim: tidak ada generator yang menangani `variant`/
generic, dan hasilnya akan butuh anotasi manual lebih banyak daripada menulis YAML.

Mekanisme (4 langkah, semuanya bisa dijalankan lokal & CI):

1. `./task contract-gen` — dua keluaran dari YAML yang sama:
   - `apps/api/src/routes_gen.nim`: `RouteSpec` skeleton (`httpMethod`, `path`, `operationId`,
     `budget`) dari `paths:` — bukan ditulis tangan.
   - `packages/api-client/src/generated/schema.d.ts`: `openapi-typescript` (FE memakai tipe ini).
2. `apps/api/src/routes.nim` hanya **mengikat handler ke `operationId`** lewat `case` ekshaustif atas
   enum yang di-generate. Handler hilang = gagal compile (bukan gagal di produksi). Ini kebalikan dari
   majadu, yang hanya *menyatakan* "every entry must exist in the OpenAPI contract"
   (`majadu/apps/api/src/routes.nim:280-284`) tanpa uji pembanding.
3. `./task contract` (gate CI): regenerate keduanya lalu `git diff --exit-code`; jalankan typecheck
   klien; tolak bila `info.version` berubah tanpa entri `CHANGELOG` kontrak. Ini pola drift-check
   majadu (`majadu/task:1153-1182`) — hash kontrak adalah sinyal drift yang otoritatif karena diff
   tipe tidak melihat deskripsi.
4. Conformance test `apps/api/tests/tcontrakt.nim`:
   - setiap `RouteSpec` di `routes_gen` ada di router dan sebaliknya (tidak ada rute "liar");
   - setiap schema di `components.schemas` punya `examples:`; test mem-parse contoh itu dengan parser
     Nim yang dipakai handler → tipe dan contoh tidak bisa menyimpang;
   - setiap respons error memakai `code` yang terdaftar di `components.schemas.Problem`;
   - golden HTTP: fixture request → status + `code` + bentuk body (pola `majadu/apps/api/tests/tapi.nim`).

Yang **tidak** dilakukan: generate parser request dari YAML (mahal, untung kecil). Parser ditulis
tangan, tapi contoh di kontrak diuji terhadapnya (langkah 4b).

## 5. Frontend impact map

Modul FE yang pecah, per grup rute (semua path relatif `apps/web/src/`):

| Grup | Modul FE | Yang pecah |
|---|---|---|
| auth | `context/AdminContext.tsx:21,62`, `components/AdminLoginModal.tsx`, `queries/endpoints.ts:91-96` | token `localStorage` hilang; `Authorization` global dihapus → `credentials:'include'`; `AdminContext` → `SessionContext` (`me.roles`) |
| sessions baca | `queries/sessions.ts:157-211`, `queries/endpoints.ts:258-292`, `pages/SessionListPage.tsx` | `id` bukan share code; daftar ber-paginasi (`items/nextCursor`); `getSession` pakai `ETag` |
| sessions tulis | `queries/sessions.ts:264-460`, `hooks/useDebouncedPublish.ts:54-71`, `pages/GeneratePage.tsx:83-133` | `PUT` snapshot → `PUT /schedule` (tanpa skor); `If-Match` wajib termasuk publish pertama (`01-frontend.md:34-57`); host pindah ke hook granular |
| share | `components/ShareButton.tsx:57-59`, `pages/SharedSessionPage.tsx`, route `/s/:sessionId` (`App.tsx`) | harus memanggil `POST …/share` dulu; URL jadi `/s/:code`; `shareEnabled` untuk state tombol |
| realtime | `queries/sessions.ts:157-211` (`useSessionRealtime`) | `EventSource` → `WebSocket`; hapus `setQueryData(snap)`; tambah backoff + aturan "jangan hapus ketikan" |
| players | `pages/PlayersPage.tsx`, `pages/admin/AdminPlayersPage.tsx:58-169`, `queries/endpoints.ts:430-460` | `stats` by id; `PATCH /players/{id}` (bukan `/tier`,`/name`); merge pindah ke path pemain |
| tournaments | `pages/TournamentPage.tsx`, `pages/TeamTournamentPage.tsx`, `queries/tournament.ts`, `queries/endpoints.ts:470-530` | tidak ada `PATCH` bracket; skor per match; `DELETE` bukan `POST /delete`; error state wajib (`01-frontend.md:118-133`) |
| rankings | `pages/RankingsPage.tsx`, `pages/RatingPlayerPage.tsx`, `queries/endpoints.ts:593-656` | `snake_case` → `camelCase`; `/rankings/{id}`; profil & achievement pindah ke `/players/{id}` |
| admin | `pages/admin/AdminSessionsPage.tsx:46-58`, `AdminRatingsPage.tsx:32-88`, `AdminTournamentsPage.tsx:48` | `204` tanpa body; `ingest/revert` ke path resource; `rebuild` dengan `mode` |
| scoreboard | `apps/scoreboard/src/**` | token admin hilang; skor menulis lewat endpoint game yang sama |

### Urutan kerja (agar subagent tidak saling menunggu)

1. **Hari 1 — kontrak + stub.** Merge `api.yaml` + `routes_gen.nim` + `schema.d.ts` + `./task mock-api`
   (server fixture dari `examples:`). FE bisa menulis semua query/mutation terhadap mock sebelum satu
   handler Nim pun ada. Ini satu-satunya hal yang harus selesai lebih dulu.
2. Auth (BE) ‖ FE `SessionContext` terhadap mock auth.
3. Sessions baca + `GET /schedule` (BE) ‖ FE daftar/detail terhadap mock.
4. Sessions tulis granular + share (BE) ‖ FE `GeneratePage`/`SharedSessionPage`; `PUT /schedule` stabil
   sebelum `useDebouncedPublish` disentuh.
5. Players, lalu tournaments (independen satu sama lain — dua subagent paralel).
6. Rankings/ratings (paling akhir: hanya baca + admin console, tidak memblokir alur live).
7. Realtime WS setelah endpoint baca/tulis sesi beku; klien bisa memakai polling sementara.

## 6. Compatibility bridge

**Rekomendasi: tanpa adapter kode.** Jembatan = deploy berpasangan + skema DB yang tetap kompatibel.

- v1 Go tetap ter-deploy dan tetap menunjuk skema `bm`; v2 Nim di mount baru. Rollback = kembalikan
  image v1 + build FE sebelumnya (keduanya artefak terpisah).
- Konsekuensi yang harus dipatuhi v2: **jangan** ada migrasi destruktif (`DROP COLUMN share_code`,
  rename tabel) sampai v2 stabil satu rilis; kolom baru `NULL`-able / ber-default; ingest ticker hanya
  boleh hidup di satu proses (`MAJADU_AUTO_INGEST=0` di salah satu) supaya poin tidak dobel.
- Biaya: ~0 LOC; risiko utama = dua penulis pada tabel yang sama bila FE lama masih dipakai saat v2
  hidup. Mitigasi: cutover FE dalam satu deploy (FE statis + API di origin yang sama).

**Alternatif bila panel menuntut overlap per-halaman:** adapter Go tipis (~120 baris) yang
memetakan 3 rute v1 saja — `GET /sessions/{id}`, `GET /sessions/{id}/watch` (tetap SSE), dan
`PATCH /sessions/{id}/games/{key}` — ke API v2, dengan header `Warning: 299 - deprecated`. Biaya:
~2 hari + satu jalur uji tambahan; hanya masuk akal kalau halaman shared-session harus tetap hidup
lebih lama dari host app.

**Yang ditolak:** menerjemahkan 48 rute v1 → v2 di Go. Biayanya lebih besar dari menulis ulang FE, dan
hasilnya mati saat halaman terakhir dimigrasi.

## 7. Risiko & pertanyaan terbuka

1. **Auth Google tanpa akun lokal**: apakah host boleh membuat sesi tanpa pernah membuat `players` row?
   (mempengaruhi `POST /sessions` body & `hostPlayerId`). Perlu jawaban owner.
2. **Spektator anonim menulis?** v2 mengasumsikan **tidak** (hanya baca + WS). Kalau venue butuh guest
   mencatat skor, kapabilitas tulis harus dibawa `share code` (mutasi terbatas) — itu menambah
   `If-Match` + audit per kode. Perlu diputuskan sebelum handler granular ditulis.
3. **UUIDv7 sebagai `id` publik** mengubah seluruh fixture FE dan bookmark `/s/:id` lama. Kode share
   tetap 10 char; `/s/{code}` adalah satu-satunya bentuk yang dipertahankan.
4. **`412` vs `409`** mengubah `src/queries/errors.ts` (pencocokan substring pesan). Perlu dicek bahwa
   tidak ada tempat lain yang mem-parse pesan.
5. **Ranking tetap, tapi `replay-all` dilebur** — admin harus tahu `mode` mana yang benar; dokumentasikan
   di UI, bukan hanya di kontrak.
