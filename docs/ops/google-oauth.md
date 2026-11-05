# Google OAuth (OIDC)

Halaman ini menjawab satu hal yang tidak boleh dicari saat login rusak: client
Google mana yang dipakai, URL balik apa yang terdaftar, di mana secret-nya, dan
apa yang harus dikerjakan saat rotasi atau pencabutan.

Status: kode login ada (`modules/account/infrastructure/oidc.nim` dan
`apps/api/src/app.nim` → `/auth/start`, `/auth/callback`), tetapi **belum pernah
dicoba dengan client Google sungguhan**. Anggap belum teruji sampai ada uji login
di origin produksi (§6).

## 1. Yang dibaca proses

| Variabel | Wajib | Default | Dipakai untuk |
|---|---|---|---|
| `OIDC_CLIENT_ID` | ya | — | `client_id` di authorize dan token request |
| `OIDC_CLIENT_SECRET` | ya untuk client web | — | `client_secret` di token request; client Google tipe *Web application* menolak penukaran tanpa ini |
| `OIDC_REDIRECT_URI` | ya | — | `redirect_uri` di kedua request; harus sama persis dengan yang terdaftar di Google |
| `OIDC_AUTHORIZE_URL` | tidak | `https://accounts.google.com/o/oauth2/v2/auth` | halaman consent |
| `OIDC_TOKEN_URL` | tidak | `https://oauth2.googleapis.com/token` | penukaran `code` → `id_token` |
| `OIDC_JWKS_URL` | tidak | `https://www.googleapis.com/oauth2/v3/certs` | verifikasi tanda tangan `id_token` (cache 1 jam) |
| `OIDC_ISSUER` | tidak | `https://accounts.google.com` | cek `iss` |

Proses menolak start bila `OIDC_CLIENT_ID` atau `OIDC_REDIRECT_URI` kosong
(`oidc.nim:31-32`), jadi salah konfigurasi terlihat sebagai unit gagal start,
bukan 500 saat login.

Nilai produksi ada di `/srv/qouver/apps/majadu/env/majadu-prod.env` (symlink ke
`.v1` atau `.v2`, mode 600). Template repo hanya memuat `CHANGE_ME`. TTL flow
disimpan di registry (`auth.flow_ttl_minutes`, seed default 10, rentang 1–60),
bukan di env.

Catatan build: jalur https butuh biner dengan `-d:ssl`; tanpa itu penukaran code
melempar `https OIDC requires a build with -d:ssl` (`oidc.nim:40-51`). Image
sekarang mengirim flag itu beserta `libssl-dev` di stage build
(`apps/api/Dockerfile`), dan `./task build` lokal tetap tanpa ssl karena dev
memakai stub http. Yang **belum terbukti**: penukaran sungguhan dengan Google
(§6).

## 2. Redirect URI harus di origin SPA

`OIDC_REDIRECT_URI` yang benar adalah `<origin-spa>/api/auth/callback`, untuk
produksi:

```
https://majadu.vercel.app/api/auth/callback
```

Bukan `https://api.qouver.com/auth/callback`. Alasannya berlapis:

1. **Rute.** Caddy hanya meneruskan `/majadu/*`
   (`ops/caddy/site-v2.caddy`); `https://api.qouver.com/auth/callback` tidak
   cocok dengan handler mana pun di site `api.qouver.com`.
2. **Cookie.** Respons `/auth/start` menyetel `majadu_auth_flow` (hash state,
   `Path=/`, `HttpOnly`, `SameSite=Lax`, umur = TTL flow), dan `/auth/callback`
   menolaknya bila cookie itu tidak ikut. Cookie tanpa `Domain` hanya dikirim ke
   host yang menyetelnya. Browser memulai flow dari `<origin>/api/auth/start`,
   jadi callback **harus** kembali ke origin yang sama; host lain membuat cookie
   itu tidak pernah terkirim dan setiap login berakhir `400 INVALID_STATE`.
3. **Sesi first-party.** `vercel.json` menulis ulang `/api/:path*` ke
   `https://api.qouver.com/majadu/:path*`, sehingga secara HTTP browser tetap
   mengobrol dengan origin sendiri (ADR-021). Session cookie dan flow cookie
   jadi first-party; itu yang membuat `SameSite=Lax` cukup.

Konsekuensinya: mengganti origin web (domain baru, alias staging) berarti
memperbarui **dua** tempat bersamaan — daftar redirect URI di Google dan
`OIDC_REDIRECT_URI` di env. Preview deployment Vercel tidak boleh didaftarkan:
host-nya berubah tiap deploy dan cookie-nya tidak akan cocok.

## 3. Membuat client

Di Google Cloud Console, pada project yang dipakai:

1. **OAuth consent screen**: tipe External, scope `openid`, `email`, `profile`.
   Tambahkan akun `platform_owner` sebagai test user selama aplikasi belum
   dipublikasikan.
2. **Credentials → Create credentials → OAuth client ID**.
3. **Authorized redirect URIs**: persis nilai `OIDC_REDIRECT_URI`
   (`https://majadu.vercel.app/api/auth/callback`). Tidak perlu Authorized
   JavaScript origins: flow ini server-side, browser tidak memanggil endpoint
   Google dengan JavaScript.
4. Salin client ID ke env, `chmod 600`, restart unit.

**Client secret belum dipakai.** `exchangeCode` mengirim `client_id`,
`code_verifier` (PKCE S256) dan tidak mengirim `client_secret`
(`oidc.nim:66-72`). Client tipe *Web application* Google meminta secret pada
token endpoint, jadi kemungkinan besar penukaran code akan ditolak
(`invalid_request` / `client_secret is missing`) sampai kode mengirimkannya.
Itu perubahan di `apps/api` (di luar dokumen ini); jangan menambahkan secret ke
env sebelum kode membacanya. Uji di origin produksi sebelum menganggap login
hidup.

## 4. Verifikasi setelah konfigurasi

```sh
systemctl --user restart majadu-api
curl -fsS http://127.0.0.1:8080/readyz
curl -s -X POST http://127.0.0.1:8080/auth/start \
  -H 'content-type: application/json' -d '{"returnTo":"/"}'
```

Lalu di browser, dari origin web: tekan login, selesaikan consent, dan pastikan
kembali ke halaman awal dengan sesi aktif. Yang perlu terlihat:

| Gejala | Arti |
|---|---|
| `400 INVALID_STATE`, "flow not found, expired or already used" | cookie flow tidak ada/asing, flow kedaluwarsa, atau callback diulang |
| `400 TOKEN_EXCHANGE_FAILED` | `redirect_uri` tidak sama persis dengan yang terdaftar, atau client secret (lihat §3) |
| `401 INVALID_ID_TOKEN` | `aud`/`iss`/`exp` tidak cocok, atau `-d:ssl` tidak ada di biner |
| `401 NONCE_MISMATCH` | `nonce` di `id_token` bukan milik flow ini |
| `403 ACCOUNT_ANONYMIZED` | akun ini sudah dianonimkan; login sengaja ditolak |
| `500 KEY_ERROR` | `SHARE_CODE_KEYS` tidak memuat key yang dipakai saat flow dimulai (key dirotasi di tengah flow) |

Cek flow yang tersisa (harus kembali ke 0 setelah login):

```sql
select count(*), min(expires_at) from auth.oauth_flows;
```

Baris kedaluwarsa tidak dibersihkan timer; baris itu hanya gagal cocok saat
callback dan bisa dihapus manual dengan `delete from auth.oauth_flows where
expires_at < now()`.

## 5. Rotasi dan pencabutan

- **Ganti client** (dicurigai bocor, atau pindah project): buat client baru →
  daftarkan redirect URI yang sama → ganti `OIDC_CLIENT_ID` di env (600) →
  restart → uji login → baru hapus client lama di console.
- **Cabut akses seketika**: hapus client di Google Cloud Console. Semua login
  baru gagal; sesi yang sudah terbit tetap hidup sampai kedaluwarsa. Untuk
  memutus sesi juga, cabut sesi di database (`auth.sessions`) lewat tool
  `account`, bukan SQL manual.
- **Hapus akun Google pengguna** tidak menghapus baris `platform.user` (subjek
  disimpan sebagai hash). Login berikutnya hanya ditolak setelah akun
  dianonimkan lewat `tools/accountlifecycle`.
- Rotasi `SHARE_CODE_KEYS` di tengah flow membuat callback gagal `500
  KEY_ERROR`; jadwalkan di luar jam login.

## 6. Yang belum terbukti

- Belum ada client Google nyata; seluruh tabel gejala di atas berasal dari kode,
  bukan dari percobaan.
- Perilaku `Set-Cookie` lewat rewrite Vercel harus diuji di alias staging yang
  terdaftar sebagai redirect URI, bukan preview acak.
- `-d:ssl` belum ada di Dockerfile, dan `client_secret` belum dikirim pada
  penukaran code — dua hal itu membuat login produksi belum mungkin hari ini.