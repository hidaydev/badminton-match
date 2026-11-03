# 02 — Security & Auth (rewrite Nim)

> **Catatan status (2026-11-03):** memo ini ditulis sebelum keputusan pemilik O-9.
> **`edit_code` dan host tanpa login DITOLAK** — semua penulis wajib login Google dan
> tautan hanya read-only. Bagian 2.5, §3 (link), §6 (`X-Edit-Code`), dan tabel
> otorisasi harus dibaca sebagai usulan, bukan keputusan. Kebenaran ada di `BRD.md`
> (O-9), `TECH-SPEC.md` §7.3, dan `BACKLOG.md` T-024.
>
> **Kontrol kompensasi K1–K6 juga DITOLAK** (O-8): P0 diterima apa adanya tanpa
> tindakan tambahan. Selain itu `K1` menargetkan `bm.player_ratings`, nama yang tidak
> ada — tabel v1 adalah `bm.rating_players`.

- **Status:** draft untuk panel perencanaan. Read-only terhadap repo; tidak ada kode yang diubah.
- **Pengambil keputusan:** owner. Auth = **Google OAuth / OIDC** (bukan magic link). Kontrak API boleh berubah; FE dirombak.
- **Rujukan wajib:** `docs/audits/2026-11-03/05-security.md`, `02-backend.md`, `04-deploy-pipeline.md`.
- **Pola yang dipinjam (bukan disalin):** `majadu` (magic link nonce-bound, `__Host-` cookie, share link hash-only) dan `cbs` (same-origin tanpa CORS, sesi `token_hash`, guard tunggal).

Prinsip yang mengikat seluruh memo ini:

1. **Kapabilitas ≠ identitas.** Cookie membuktikan "siapa"; kepemilikan objek atau capability link bertipe membuktikan "boleh menyentuh sesi ini". Keduanya tidak pernah berupa nilai yang sama.
2. **Satu guard, satu tempat.** Semua rute lewat satu fungsi cookie → user + role (`apps/api/src/auth_routes.nim:23-54`); tidak ada handler yang membaca cookie sendiri.
3. **Tidak ada token di JavaScript** dan **role dibaca dari DB setiap request** — menutup `05-security.md:73-78` secara struktural, dan demosi berlaku pada request berikutnya (`community_routes.nim:55-60`).
4. **Default gagal-tertutup.** Rute baru tanpa anotasi otorisasi = 401, diverifikasi saat boot dan di CI.

---

## 1. Threat model (STRIDE-lite)

### 1.1 Aset

**A1** riwayat poin ranking (`rating_sources`, `player_ratings`) — integritas produk inti, dipakai seeding turnamen.
**A2** skor/roster sesi berjalan. **A3** kapabilitas admin (delete, merge, rebuild, revert).
**A4** identitas host/admin (akun Google). **A5** ketersediaan (pool DB 10 koneksi, watcher SSE).

### 1.2 Aktor dan kepercayaan

| Aktor | Kepercayaan | Catatan |
|---|---|---|
| Anonim | nol | Saat ini punya kapabilitas tulis (P0) |
| Spectator (`view` link) | baca satu sesi | Link menyebar; harus tidak berguna untuk tulis |
| Scorekeeper (`edit` link) | tulis skor satu sesi | Tidak login, HP pinjam, jaringan buruk |
| Host (login) | tulis + finalisasi sesi miliknya, buat/cabut link | Bisa bekerja tanpa login lewat `edit` |
| Admin | tulis global + approve rating | Tidak boleh mengubah role |
| Owner | semua + manajemen role | Satu-satunya yang bisa promote |
| Google IdP | semi-tepercaya | Sumber identitas, bukan otorisasi kita |

Batas kepercayaan: Browser → Caddy (edge) → API (trusted) → Postgres; Google hanya pada dua lompatan (redirect + token exchange) dan **tidak** di jalur data.

### 1.3 STRIDE per permukaan

| Permukaan | S | T | R | I | D | Kontrol utama |
|---|---|---|---|---|---|---|
| **Penulis sesi anonim** (P0-1/P0-2) | Sulit dipungkiri: tidak ada aktor | Skor/roster dipalsukan; poin ranking disuntik | — | Riwayat logbook terbaca | `POST /sessions` berulang mengunci pool | Setiap mutasi butuh session cookie **atau** `edit_code` bertipe; `POST` butuh role ≥ host; audit `actor` di setiap tulis |
| **Share link** | Pembuatan link tidak tercatat siapa | Link baca dipakai untuk menulis (IDOR) | Link ditebak/di-enumerasi | Link bocor = seluruh isi sesi | Enumerasi `GET /sessions` | Dua tipe link terpisah (`view`/`edit`), hanya hash di DB, code di header bukan path, lookup seragam 404 |
| **Operasi admin** | Aksi admin tanpa jejak | Delete/merge/rebuild oleh bukan admin | — | Dump data via list | Endpoint mahal dipanggil berulang | Role gate + audit wajib + `If-Match`; bucket rate limit terpisah |
| **Integritas ranking** | Poin berubah tanpa pelaku | Sumber palsu di-ingest otomatis | — | Papan publik jadi tidak bermakna | Replay massal membebani DB | Ingest hanya untuk sumber `approved_at is not null`; `origin`, `actor`, `client_ip`, `request_id` disimpan |
| **SSE publik** | — | Frame dari origin lain dibaca | Kode link ditebak | Frame membawa data di luar link | Watcher tak terbatas (P2-3) | Upgrade digerbangi `Origin`/`Sec-Fetch-Site`, cap per sesi + global + per IP, tutup saat link dicabut |
| **Google login** | Login oleh orang lain tidak terdeteksi | `state`/`nonce` dipalsukan → akun korban | `sub` ditebak (tidak praktis) | Email/`sub` bocor di log | Callback dibanjiri → biaya + lockout | `state` + `nonce` + PKCE S256, single-use, TTL 10 menit, semua kegagalan 400 generik + audit |
| **Cookie/session** | Sesi dicuri lalu dipakai tanpa jejak | Fixation: penyerang menanam sesi | Token ditebak | Cookie terbaca skrip | Sesi abadi setelah dicuri | `__Host-`, `HttpOnly`, `Secure`, `SameSite=Lax`, token 32 byte, hanya hash di DB, absolut 30 hari + idle 14 hari, revoke seketika |
| **CSRF** | Aksi lintas-situs atas nama host | Skor/diubah dari halaman jahat | — | — | — | Same-origin tunggal (tanpa CORS), gerbang `Origin`/`Sec-Fetch-Site` untuk semua metode tidak-aman (`majadu` `apps/api/src/http_util.nim:144-193`) |
| **Redirect OAuth** | — | Open redirect → token/code dicuri | `return_to` dipakai memetakan rute internal | Code/`state` masuk access log | — | `redirect_uri` persis (allowlist 1 nilai), `return_to` hanya path relatif, `code`/`state` tidak pernah di-log |

**Yang secara eksplisit bukan ancaman di v1:** multi-tenant/community isolation (community-less), SSO enterprise, MFA tambahan (Google sudah menanganinya), dan rotasi kunci enkripsi at-rest (tidak ada data rahasia di DB selain hash).

---

## 2. Auth design

### 2.1 Alur OIDC: Authorization Code + PKCE, server-side, tanpa token di browser

```
GET /auth/google/start?return_to=/sessions
  → flow_id, state, nonce (32 byte masing-masing) + code_verifier
  → row auth.oauth_flows(flow_id_hash, state_hash, nonce_hash, verifier_hash,
                         return_to, expires_at = +10 menit)
  → Set-Cookie: __Host-bm_oauth=<flow_id>; HttpOnly; Secure; SameSite=Lax; Max-Age=600
  → 302 accounts.google.com/o/oauth2/v2/auth?client_id&redirect_uri(EXACT)&response_type=code
        &scope=openid%20email%20profile&state&nonce&code_challenge(S256)&prompt=select_account

GET /auth/google/callback?code&state
  → state cocok dengan hash row yang ditunjuk cookie; row dihapus dalam transaksi
  → POST oauth2.googleapis.com/token (client_secret di body, tidak di-log)
  → validasi ID token (2.2) → upsert user (2.3) → buat sesi (2.4) → 303 ke return_to
```

Keputusan dan alasannya:

- **PKCE wajib walau ada `client_secret`.** `code_verifier` disimpan sebagai hash di DB, cookie hanya membawa `flow_id` — pencuri cookie tidak mendapat verifier, DB dump tidak mendapat apa pun yang bisa dipakai.
- **Tidak menyimpan access/refresh token Google** (`access_type=online`). Kita tidak memanggil API Google setelah identitas didapat; seluruh kelas kebocoran token pihak ketiga hilang.
- **Tidak ada implicit flow, `form_post`, atau token di fragment.** Satu jalur kode saja.

### 2.2 Validasi ID token (urutan tetap, gagal = 400 generik tanpa pembeda)

1. Cari `kid` di cache JWKS (`googleapis.com/oauth2/v3/certs`), TTL 1 jam, refresh **single-flight**. `kid` asing → satu kali refetch (backoff 60 s) lalu 401; refetch tidak boleh dipicu tanpa batas (vektor DoS).
2. Signature `RS256` dengan kunci JWKS; tolak `alg` lain — `none` tidak pernah diterima.
3. `iss` ∈ {`accounts.google.com`, `https://accounts.google.com`} persis, bukan prefix. `aud` == `GOOGLE_CLIENT_ID`; bila `azp` ada, harus sama.
4. `exp` > now − 60 s; `iat` ≤ now + 60 s; `nbf` bila ada.
5. `nonce` == `nonce_hash` flow (constant-time, pola `sameSecret` di `modules/account/domain/login.nim:49-58`). Nonce NULL/absen = mismatch, bukan lolos.
6. `email_verified == true`; `email` lolos normalisasi (`login.nim:79-105`). `sub` wajib ada dan **satu-satunya** kunci akun — `email` bisa berubah, jadi tidak pernah dipakai sebagai identitas.

Semua kegagalan → satu respons `400 invalid_request` tanpa detail + satu baris audit `auth.login_failed` (`reason`, `client_ip`, `request_id`, `flow_id` hash). Klien tidak pernah tahu mana yang gagal.

### 2.3 Model akun (community-less v1)

```sql
create table auth.users (
  id            uuid primary key default uuidv7(),
  google_sub    text not null unique,
  email         text not null,
  email_norm    text not null,              -- lower-case, unique
  display_name  text not null,
  avatar_url    text,                        -- hanya https + host googleusercontent
  role          text not null default 'member'
                check (role in ('owner','admin','host','member')),
  status        text not null default 'active' check (status in ('active','disabled')),
  created_at    timestamptz not null default now(),
  last_login_at timestamptz
);
create unique index users_single_owner on auth.users ((role)) where role = 'owner';
```

- **Satu role per user** (bukan tabel `user_roles`): v1 tanpa community, jadi hirarki linear `owner > admin > host > member` cukup dan menghapus kelas bug "role mana yang berlaku". Tabel role terpisah dibuat saat community benar-benar masuk.
- **Bootstrap owner:** `BOOTSTRAP_OWNER_EMAIL`. Saat boot, jika belum ada owner dan email itu terdaftar, promosikan **satu** user; audit `auth.owner_bootstrapped`. Idempoten, tidak menurunkan owner lain, tidak berbuat apa-apa bila owner sudah ada — mencegah "first login wins".
- **Tanpa allowlist email** untuk login: siapa pun boleh punya akun `member` (read-only). Yang dibatasi adalah role, bukan pendaftaran. Ini menghindari kebocoran "apakah email X terdaftar" (OWASP-12 di `apps/api/src/auth_routes.nim:118-124`).
- **Host tanpa akun:** host yang tidak mau login tetap bisa bekerja lewat `edit_code` (2.5). Akun host hanya diperlukan untuk membuat sesi baru dan finalisasi.

### 2.4 Sesi: cookie opaque, bukan bearer, bukan JWT

| Aspek | Keputusan | Alasan |
|---|---|---|
| Bentuk | 32 byte acak, hex; DB menyimpan `sha256` (`auth.sessions.token_hash`) | Token 256-bit tidak bisa di-brute-force, jadi hash cepat cukup (`cbs` `0006_platform_auth.sql:17-18`) |
| Cookie | `__Host-bm_session`; `HttpOnly; Secure; SameSite=Lax; Path=/`; **tanpa** `Domain` | `__Host-` mencegah subdomain menimpanya (`apps/api/src/cookies.nim:1-6`) |
| `SameSite` | `Lax`, bukan `Strict` | Callback Google adalah navigasi lintas-situs top-level; `Strict` akan membuang cookie dan memaksa login dua kali. CSRF ditutup di lapisan Origin, bukan di sini |
| Umur | absolut 30 hari, idle 14 hari, `touch` maks 1×/60 s | Menutup "sesi abadi" (`auth_session.nim:10-20`) |
| Rotasi | token baru pada setiap login; token **tidak** dirotasi per request | Rotasi per request menambah write per request tanpa menutup kelas serangan yang belum tertutup oleh absolut+idle |
| Revokasi | `revoked_at`; dipanggil pada logout, logout-all, perubahan role, `status='disabled'`, dan pentest response | `revokeAllSessionsTx` pola `auth_session_store.nim:77-96`; revokasi harus satu transaksi dengan perubahan yang menyebabkannya |
| Bearer | hanya untuk CLI ops, dari `/auth/cli-login` (device-ish, code 8 karakter + TTL 5 menit, sekali pakai) | Browser tidak pernah memegang token; `Authorization` tidak dikirim pada GET publik (`05-security.md:77`) |
| Cookie OAuth | `__Host-bm_oauth`, `Max-Age=600`, dihapus pada callback | Satu cookie, satu tujuan, umur pendek |

**Kenapa cookie dan bukan bearer di frontend:** (a) `HttpOnly` membuat XSS tidak bisa mencuri sesi — langsung menutup P1-2; (b) dengan same-origin tunggal tidak ada CORS dan tidak ada preflight ber-`credentials` (pola `cbs` `docs/DECISIONS.md:367-380`); (c) tidak ada satu pun jalur kode di FE yang menyentuh token, sehingga tidak ada yang bisa lupa menghapusnya.

### 2.5 Host tanpa login: capability link dengan pemisahan baca/tulis

Satu sesi punya **dua** link independen (`view_code` = `kind='view'`, `edit_code` = `kind='edit'`), dibuat host/admin, ditampilkan **sekali**, disimpan hanya sebagai hash:

```sql
create table session.links (
  id uuid primary key default uuidv7(),
  session_id uuid not null references session.sessions(id) on delete cascade,
  kind text not null check (kind in ('view','edit')),
  code_hash text not null unique,            -- sha256(randomTokenHex(32))
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  expires_at timestamptz,                    -- default: sesi selesai + 7 hari
  revoked_at timestamptz
);
create unique index links_one_live_per_kind on session.links (session_id, kind)
  where revoked_at is null;
```

- **`view`** → proyeksi publik baca-saja (tanpa email, alias, `share_code`, atau id internal). Aman ditempel di grup WA, boleh di-QR.
- **`edit`** → hanya `PATCH /scores`, `PATCH /absent`, `POST /swap`. **Tidak** boleh delete, ubah judul/tanggal, buat sesi, finalisasi, atau apa pun yang menyentuh rating.
- **Kode dikirim di header `X-Edit-Code`, bukan di path.** FE membacanya dari fragment URL (`/#/s/<code>/score`), jadi kode tidak pernah masuk access log, `Referer`, atau histori server — hanya histori browser perangkat itu. Inilah yang membuat link tulis bisa dibagikan tanpa mengulang P0-1.
- **Rotasi = pencabutan:** link baru untuk `kind` yang sama mencabut yang lama dalam transaksi yang sama (`0014_share_links.sql:34-37` majadu); watcher SSE untuk link itu diputus. Batas laju dihitung per `(link_id, ip)`, sehingga link bocor bisa dicabut host dari HP tanpa menyentuh sesi.
- **Finalisasi tetap milik host/admin.** Bila host benar-benar offline, `edit` boleh `lock` **hanya jika** dibuat dengan flag `can_lock` — dan lock itu hanya mengubah status, tidak meng-ingest poin (lihat §3, P0-2). Default `can_lock = false`.

### 2.6 Otorisasi: satu gerbang, tiga tingkat

| Tingkat | Fungsi | Contoh |
|---|---|---|
| `requireUser` | cookie → user aktif | semua rute non-publik |
| `requireRole(min)` | `member < host < admin < owner` | `POST /sessions` ≥ host; `DELETE` ≥ admin; `PATCH /users/{id}/role` = owner |
| `requireSessionAccess(sessionId)` | pemilik (host pembuat) **atau** `edit_code` ber-`kind='edit'` **atau** ≥ admin | semua mutasi skor |

Aturan tambahan: **tidak ada rute yang menerima id sesi dari klien sebagai kapabilitas**. `GET /sessions` (daftar) hanya untuk user login; daftar publik tidak ada (logbook publik = fitur terpisah yang harus diminta owner, dengan proyeksi tanpa kapabilitas dan `limit` wajib ≤ 50).

---

## 3. Remediation map

Kolom **FE** = butuh kerja frontend baru. Semua item di bawah "keputusan" adalah desain, bukan tambalan Go.

| # | Temuan (audit) | Keputusan yang mematikannya | FE |
|---|---|---|:--:|
| P0-1 | `share_code` = kunci tulis bocor via `GET /sessions` (`05-security.md:35-49`) | Kapabilitas dipisah dari identitas: `id` (uuidv7 internal), `view_code`, `edit_code`. `GET /sessions` butuh login dan **tidak pernah** memuat kode apa pun. Mutasi butuh `requireSessionAccess`. Test regresi `share_code_never_in_listing` permanen. | ✔ |
| P0-2 | Poin ranking dipalsukan anonim (`05-security.md:51-64`) | (a) `POST /sessions`/`POST /tournaments` ≥ host. (b) Ingest hanya untuk sumber `approved_at is not null`; lock tidak lagi meng-ingest. (c) `rating_sources` menyimpan `origin`, `actor_user_id`, `client_ip`, `request_id`. Ticker hanya menyentuh sumber yang sudah di-approve. | ✔ (antrean approve) |
| P1-1 | Turnamen bisa ditulis anonim (`05-security.md:66-71`) | Semua `POST/PUT/PATCH` turnamen ≥ host + `requireSessionAccess` (host hanya miliknya). `GET` tetap publik tapi lewat proyeksi `view`. | ✔ |
| P1-2 | Token admin di `localStorage`, header global (`05-security.md:73-78`) | Dihapus total: cookie `HttpOnly`, tidak ada `Authorization` dari browser, `setAdminToken`/`STORAGE_KEY` (`apps/web/src/context/AdminContext.tsx:5,20-27`) hilang. `AdminContext` diganti `SessionContext` yang membaca `GET /auth/me`. | ✔ |
| P1-3 | 401 admin tidak tercatat, token statis (`05-security.md:80-85`) | Tanpa token statis: tidak ada lagi brute force terhadap satu string. Setiap penolakan otorisasi menulis `auth.denied` (`path`, `role`, `user_id` atau null, `client_ip`, `request_id`). Bucket auth terpisah. | — |
| P1-4 | Rate limit satu bucket di belakang Caddy (`05-security.md:87-91`) | Bucket per kelas rute: `auth` 10/menit/IP, `write` 120/menit/IP, `capability_write` 60/menit/(link,IP), `sse_connect` 5/menit/IP, `read` 300/menit/IP. `TRUSTED_PROXY_CIDRS` wajib di prod env; boot gagal bila kosong di `prod` (fail-closed, pola `config.go:111-113`). | — |
| P2-1 | Registrasi pemain anonim, nama bisa dibajak (`05-security.md:93-98`) | `POST /players` ≥ host. Batas: nama ≤ 60 char, alias ≤ 20, body ≤ 64 KB, ≤ 50 pemain baru/jam/IP. | — |
| P2-2 | `PUT /sessions/{id}` membuat sesi dengan id pilihan penyerang (`05-security.md:100-105`) | Tidak ada create-on-PUT. ID selalu uuidv7 server-side. `PUT` pada id yang tidak ada → 404. | — |
| P2-3 | SSE tanpa batas + `ACAO: *` (`05-security.md:107-112`) | Cap per sesi 50, global 500, per IP 10; ditolak 429 dengan body sebelum stream dimulai. Header CORS dihapus seluruhnya (tidak ada CORS). Upgrade digerbangi `Origin`/`Sec-Fetch-Site` (`majadu` `share_routes.nim:230-240`). | — |
| P2-4 | Field teks tanpa batas (`05-security.md:114-119`) | Batas di domain, bukan di handler: `title ≤ 120`, `name ≤ 60`, `courts ≤ 12`, `courts×60 ≥ schedule`, `fix_matches ≤ 60`, body snapshot ≤ 1 MB. Invariant ini juga menutup `02-backend.md` P1-2 (write amplification). | — |
| P2-5 | Repo publik + deploy self-update (`05-security.md:121-126`) | Bukan kode: pisahkan detail infra ke repo privat; deploy memakai SHA yang di-approve, bukan `git reset --hard origin/main`; `REPO` divalidasi (`ops/scripts/deploy-vps.sh:7,12`). | — |
| P3-1 | Log `0644` berisi IP (`05-security.md:128-132`) | Log 0600, ditulis sebagai user service; rotasi harian, retensi 14 hari. | — |
| P3-2 | `/metrics`, `/version` publik | `/metrics` hanya loopback (bind terpisah atau `handle` 404 di Caddy); `/version` mengembalikan commit saja, bukan build host. | — |
| P3-3 | Nama schema dikonkatenasi ke SQL | Schema tetap (`bm`), tidak dari env. Tidak ada konkatenasi identifier; `SET LOCAL search_path` per koneksi. | — |
| P3-4 | Pencocokan origin CORS longgar | Tidak ada middleware CORS. Satu origin (halaman + `/api` di host yang sama). Uji: tidak ada respons dengan `Access-Control-Allow-Origin`. | — |
| P3-5 | Gitleaks tidak memindai riwayat penuh | Job mingguan `gitleaks git --full-history` + `gitleaks protect --staged`; `.gitleaks.toml` dengan allowlist fixture test. | — |
| P3-6 | Tidak ada pemindaian dependency | `osv-scanner` pada `nimble.lock`/manifest di CI; Dependabot untuk actions. | — |
| P3-7 | Template webhook bukan `.example` | Rename `ops/webhook/webhook.json` → `.example`; trigger rule memeriksa `repository.name`. | — |
| 02 P1-3 | Gagal `Load` setelah `Commit` → 5xx padahal tersimpan | Setelah commit, respons 2xx dengan `{version, saved:true}`; `Broadcast` dari snapshot yang disusun sendiri; tidak pernah error setelah commit. | — |
| 02 P1-5 | Idempotency tanpa hash body | `(actor, key)` + `sha256(body)`; body berbeda → 409 `idempotency_key_reused` (pola jalur turnamen). Tabel `idempotency_keys`, bukan LRU per proses. | — |
| 04 P1-1..P1-5 | Health gate liveness, restart tanpa rollback, deploy kedua dibuang, tanpa versi, tanpa notifikasi | Di luar scope auth, tapi wajib satu paket rilis: `/readyz`, `flock -w 900`, `--build-arg COMMIT`, `trap ... ERR` + notifikasi. | — |

**Kriteria rilis aman** (dari `05-security.md:233`, dipertajam): seluruh P0/P1 di atas tertutup **dan** tiga test regresi hijau — `share_code_never_in_listing`, `anon_write_rejected`, `ranking_ingest_requires_approval`.

---

## 4. Secrets & config

### 4.1 Kunci environment

| Kunci | Rahasia? | Catatan |
|---|:--:|---|
| `APP_ENV`, `PORT`, `PUBLIC_BASE_URL` | tidak | `APP_ENV` default `prod` (fail-closed); `PUBLIC_BASE_URL` dipakai menyusun `return_to`, bukan `Host` header |
| `DATABASE_URL` | **ya** | role aplikasi, tanpa `CREATE`/`DROP`; `DATABASE_SCHEMA` **konstanta** `bm`, bukan env (P3-3) |
| `GOOGLE_CLIENT_ID` | tidak | boleh tampil saat redirect |
| `GOOGLE_CLIENT_SECRET` | **ya** | server saja; tidak pernah di bundle atau log |
| `GOOGLE_REDIRECT_URI` | tidak | persis sama dengan yang terdaftar di console |
| `BOOTSTRAP_OWNER_EMAIL` | tidak | PII; tidak masuk repo |
| `TRUSTED_PROXY_CIDRS` | tidak | wajib di `prod`, gagal boot bila kosong |
| `SSE_MAX_PER_SESSION`, `SSE_MAX_GLOBAL`, `RATE_LIMIT_*` | tidak | satu kunci per bucket |
| `LOG_DIR`, `LOG_LEVEL` | tidak | log 0600 |

**Tidak boleh masuk repo, dalam bentuk apa pun:** client secret, `DATABASE_URL` berisi password, HMAC webhook, email nyata (allowlist/owner), token sesi contoh yang valid, dan dump konfigurasi Caddy prod. Repo saat ini publik (`05-security.md:29`) — perlakukan setiap commit sebagai publikasi.

### 4.2 Rotasi

- **`GOOGLE_CLIENT_SECRET`:** Google hanya punya satu secret aktif per client. Prosedur: buat client baru, jalankan dua nilai (`GOOGLE_CLIENT_ID` + `GOOGLE_CLIENT_ID_PREV`), pindahkan trafik, hapus client lama setelah 24 jam. Tanpa jendela ini, rotasi = semua login gagal.
- **Sesi:** tidak ada kunci; token opaque + hash. "Rotasi" = revoke-all (satu perintah owner, satu transaksi). **JWKS** otomatis oleh Google, cache TTL 1 jam + refetch saat `kid` meleset.
- **Webhook HMAC:** rotasi dua fase (secret baru diterima bersamaan) — perlu dukungan daemon, item ops. Tidak ada kunci enkripsi aplikasi di v1: tidak ada field terenkripsi selain hash.

### 4.3 Header & origin

CSP untuk halaman (bukan API), dikirim sebagai header, bukan `<meta>`:

```
Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self';
  img-src 'self' data: https://*.googleusercontent.com; connect-src 'self';
  font-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self';
  object-src 'none'; upgrade-insecure-requests
Strict-Transport-Security: max-age=31536000; includeSubDomains
X-Content-Type-Options: nosniff
Referrer-Policy: no-referrer
Permissions-Policy: geolocation=(), camera=(), microphone=(), payment=()
Cross-Origin-Opener-Policy: same-origin
```

API: `Cache-Control: no-store` pada semua respons ber-sesi, `Referrer-Policy: no-referrer`, `X-Content-Type-Options: nosniff`. **Tidak ada** `Access-Control-Allow-Origin` sama sekali.

Allowed origins: tepat satu — origin aplikasi (`PUBLIC_BASE_URL`). Origin preview Vercel tidak didukung lewat CORS; preview memakai origin yang sama via tunnel, atau tidak punya sesi. `Host` header divalidasi terhadap allowlist yang sama (mencegah host-header poisoning pada `return_to`).

---

## 5. Kontrol kompensasi selama P0 masih terbuka

### 5.1 Jendela eksposur (fakta dari git, bukan dugaan)

| Fakta | Sejak | Lama per 2026-11-03 |
|---|---|---|
| Route `POST /sessions` lahir (`9b836df`); hari ini tanpa guard (`main.go:196`) | 2026-08-12 | ±83 hari |
| `AutoIngestLockedSessions` (bentuk sekarang) masuk — rantai poin lengkap | 2026-09-28 | ±36 hari |
| `GET /sessions` tanpa filter → enumerasi massal (`b3bf8a4`) | 2026-10-25 | ±9 hari |

Artinya: **rantai pemalsuan poin lengkap bisa dijalankan siapa pun selama ±36 hari**, dan kapabilitas tulis anonim sudah ada ±83 hari. Audit bersifat statis: **tidak ada bukti eksploitasi, tetapi juga tidak ada bukti tidak ada eksploitasi** — log aplikasi hanya mencatat `internal`/`database` (`05-security.md:84`) dan tidak menyimpan status 2xx per penulis. Perlakukan `rating_sources` sejak 2026-09-28 sebagai **tersangka**, bukan bersih.

### 5.2 Kontrol yang bisa dipasang tanpa menyentuh Go

Urut dari dampak tertinggi. Semua ini **sementara** dan harus dicabut saat rilis Nim.

**K1 — Bekukan penulisan poin di DB (paling penting).** Aplikasi tetap jalan; hanya penulisan poin yang mati. Tanpa perubahan Go.

```sql
create or replace function bm.deny_rating_write() returns trigger language plpgsql as $$
begin
  raise exception 'rating writes frozen (incident freeze 2026-11-03)' using errcode = '42501';
end $$;
create trigger rating_frozen before insert or update on bm.player_ratings
  for each row execute function bm.deny_rating_write();
```

- Diterima sebagai biaya: ticker 30 menit gagal dan menulis error (kebisingan, bukan kerusakan); `POST /ratings/revert-*` juga gagal selama freeze.
- **Jalur keluar ditulis di muka, jangan improvisasi:** dump rating **sebelum** trigger; saat rilis Nim → `drop trigger` → pulihkan snapshot → `replay-all` **hanya** untuk sumber yang lolos review. Jangan hanya `DROP TRIGGER`: `rating_sources` sudah menandai sesi palsu "ter-ingest" dan poinnya akan hilang diam-diam.

**K2 — Batasi laju di edge.** Caddy OSS tidak punya `rate_limit` tanpa plugin `caddy-ratelimit`; kalau plugin tidak terpasang di host, pakai Cloudflare (owner action). Aturan minimum:

| Path | Metode | Batas | Aksi |
|---|---|---|---|
| `/majadu/sessions*`, `/majadu/tournaments*` | selain GET | 30/menit/IP | block 60 s |
| `/majadu/sessions/*/watch` | GET | 5/menit/IP | block 60 s |
| `/majadu/admin/*` | semua | 5/menit/IP | block 300 s |
| `/majadu/metrics`, `/majadu/version` | semua | — | 404 |

**K3 — Tutup permukaan nol-nilai.** `handle /majadu/metrics { respond 404 }`, `handle /majadu/version { respond 404 }`, dan `handle /majadu/admin/verify { respond 404 }` di Caddy. Tidak ada fitur produk yang memakai ketiganya; ini menghapus oracle brute-force (P1-3) dan counter internal (P3-2) hari ini.

**K4 — Log akses + deteksi.** Aktifkan `log` Caddy ke file 0600, retensi 14 hari. Cron 5 menit:

```sh
# tulis non-GET per IP dalam 10 menit terakhir; alert di atas 100
grep '"method":"\(POST\|PUT\|PATCH\|DELETE\)"' access.log \
  | jq -r '.request.remote_ip' | sort | uniq -c | sort -rn | awk '$1>100'
```

Alert: (a) lonjakan tulis per IP, (b) setiap baris error dari trigger `rating_frozen` (berarti ada yang mencoba meng-ingest selama freeze), (c) `GET /sessions` dari IP yang sama > 20×/menit. Kanal: helper alert host yang sudah ada (`system-health.timer`).

**K5 — Snapshot forensik.** `pg_dump -t bm.rating_sources -t bm.player_ratings` harian ke file 0600 di host, retensi 30 hari. Tanpa ini, "apakah ada yang dipalsukan" tidak bisa dijawab **sama sekali** setelah data berubah. Ini juga satu-satunya cara merekonstruksi poin yang benar.

**K6 — Turunkan `MaxConns`.** `MaxConns` 10 (`02-backend.md` P1-2) berarti 10 request snapshot raksasa mematikan API. Sementara: turunkan ke 6 dan pasang `statement_timeout` di level role (`ALTER ROLE majadu_app SET statement_timeout = '10s'`) — murni konfigurasi DB.

### 5.3 Yang **tidak** bisa ditutup di edge (jujur)

- **Enumerasi `GET /sessions`.** FE memakainya untuk logbook; memblokir = mematikan produk. Caddy tidak bisa memfilter field JSON, dan edge tidak bisa membedakan klien sah dari penyerang ketika **keduanya tidak berautentikasi**.
- **Mutasi skor anonim.** FE menulis tanpa auth hari ini; memblokir `PATCH`/`PUT` mematikan scoring courtside.
- **Kesimpulan:** K1 satu-satunya kontrol yang mengubah dampak; sisanya menaikkan biaya dan mempercepat deteksi. **P0-1 baru tertutup saat API Nim dengan `requireSessionAccess` rilis** — sampai itu, ranking dibekukan.

### 5.4 Aksi owner di host (tidak bisa didelegasikan)

1. Pasang trigger K1 (setelah dump K5). Catat tanggal & commit di `docs/tasks/`.
2. Aktifkan log akses Caddy + cron alert K4; chmod 0600 file log.
3. Pasang blok K3 di Caddy, reload.
4. Pasang rate limit K2 (plugin Caddy atau Cloudflare dashboard).
5. `ALTER ROLE majadu_app SET statement_timeout = '10s'`; turunkan `MaxConns`.
6. Umumkan freeze ranking ke pengguna (satu kalimat di UI/medsos) supaya "poin tidak bertambah" bukan bug yang dilaporkan berulang.
7. Review mingguan: cabut freeze hanya bersama rilis Nim + replay yang direview.

---

## 6. Test case yang wajib dibuktikan suite keamanan

Harness: Nim `unittest` + IdP palsu lokal (RSA test key, JWKS lokal, token yang bisa dirusak `exp`/`aud`/`nonce`). **Tidak pernah** memanggil Google sungguhan di CI.

**OIDC** — `oidc_state_single_use`, `oidc_state_expired_rejected`, `oidc_state_cookie_missing_rejected`,
`oidc_nonce_mismatch_rejected`, `oidc_nonce_absent_fails_closed`,
`oidc_id_token_wrong_aud_rejected`, `oidc_id_token_wrong_iss_rejected`, `oidc_id_token_expired_rejected`,
`oidc_id_token_alg_none_rejected`, `oidc_pkce_verifier_mismatch_rejected`,
`oidc_callback_redirect_uri_exact`, `oidc_return_to_open_redirect_rejected`
(`//evil`, `https://evil`, `/%2F%2Fevil` → jatuh ke `/`), `oidc_jwks_kid_miss_single_refetch`
(20 request `kid` asing → maksimal 1 refetch), `oidc_failure_is_uniform` (semua kegagalan: status+body identik).

**Sesi** — `session_cookie_attributes` (`__Host-`, `HttpOnly`, `Secure`, `SameSite=Lax`, `Path=/`, tanpa `Domain`),
`session_token_hash_only` (scan kolom: tidak ada token mentah), `session_idle_expiry`, `session_absolute_expiry`,
`session_revoked_rejected`, `session_role_change_revokes`, `role_demotion_immediate`,
`logout_revokes_before_response`, `logout_all_revokes_every_session`.

**CSRF / origin** — `mutation_cross_origin_rejected` (`Origin` lain, `Sec-Fetch-Site: cross-site`, `same-site`),
`mutation_missing_origin_on_cookie_request_rejected`, `safe_methods_allowed`,
`capability_write_cross_origin_rejected` (`X-Edit-Code` sah + origin lain), `no_cors_headers_anywhere`.

**Kapabilitas & IDOR** — `share_code_never_in_listing` (regresi P0-1), `view_code_cannot_write`,
`edit_code_cannot_delete_or_finalize`, `edit_code_scope_is_one_session` (kode A pada sesi B → 404, bukan 403),
`link_revoked_is_404`, `link_rotation_invalidates_previous`, `link_code_not_in_logs`,
`link_lookup_uniform_404`, `anon_write_rejected` (matriks rute tulis, satu assertion per rute).

**Otorisasi & admin** — `post_sessions_requires_host`, `tournament_mutation_requires_host`,
`tournament_host_only_own`, `admin_route_matrix` (rute × role, satu sel satu assertion),
`denied_request_is_audited` (`path`, `role`, `client_ip`, `request_id`), `owner_bootstrap_once`,
`user_self_promotion_rejected`.

**Integritas ranking** — `ranking_ingest_requires_approval`, `ranking_approval_records_actor`,
`ranking_revert_requires_admin`, `ranking_revert_is_audited`,
`locked_session_does_not_auto_ingest` (ticker 2 putaran → `rating_sources` kosong).

**Rate limit & kapasitas** — `rate_limit_auth_bucket_separate`, `rate_limit_capability_per_link_and_ip`,
`sse_watcher_cap_per_session`, `sse_watcher_cap_global`, `sse_conn_cap_per_ip`,
`sse_cross_origin_upgrade_rejected`, `sse_close_on_link_revoke`,
`trusted_proxy_required_in_prod`, `xff_ignored_from_untrusted_peer`.

**Batas input & higiene** — `snapshot_body_limit_1mb`, `domain_bounds_reject` (title/name/courts/schedule),
`idempotency_body_hash_mismatch_conflict`, `log_file_mode_0600`, `metrics_not_public`,
`no_secret_in_repo` (gitleaks full-history hijau).

---

## 7. Sisa risiko & pertanyaan terbuka

1. **Freeze ranking punya biaya produk.** Poin berhenti bertambah sampai rilis. Keputusan owner, bukan teknis.
2. **`edit_code` adalah bearer capability.** Siapa pun yang melihat QR/HP host bisa menulis skor. Mitigasi: scope sempit, `can_lock=false`, TTL, rotasi, counter per link. Tidak ada cara menghapusnya sepenuhnya tanpa login di courtside.
3. **Google satu-satunya IdP** = single point of failure untuk login. Saat Google down, host tetap bisa scoring lewat `edit_code`; admin tidak bisa delete/merge sampai pulih. Catat di runbook.
4. **Satu role per user** menyulitkan kasus "host yang juga admin" — dipilih sengaja; kalau muncul, naikkan role, jangan tambah tabel.
5. **Belum diputuskan (produk):** apakah logbook publik tetap ada. Kalau ya, ia butuh proyeksi sendiri tanpa kapabilitas + `limit` wajib + `robots: noindex`.
6. **Tidak diverifikasi:** branch protection dan visibilitas repo (`05-security.md:126` menandainya asumsi). Selama repo publik, threat model harus mengasumsikan penyerang membaca seluruh dokumen ini.
