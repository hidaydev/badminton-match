# Memo 06 — QA & Parity (Go → Nim)

> Panel: QA/test architect. Sifat: read-only terhadap repo. Tidak ada kode yang dijalankan
> selain pembacaan berkas. Rujukan silang: `05-security.md`, `02-backend.md`, `03-ci.md`,
> `07-database.md`.

## 0. Titik awal (fakta terukur)

- Coverage Go hari ini **14,6%**, **249 dari 347 fungsi 0,0%** (`docs/audits/2026-11-03/02-backend.md:349`).
- **56 dari 74** test `internal/store` di-skip bila `MAJADU_TEST_DATABASE_URL` kosong
  (`02-backend.md:347`) — dan di CI memang kosong, skip disamarkan jadi `::warning`
  (`03-ci.md:85-90`).
- **Nol test HTTP handler**: 64 method handler ↔ 9 test helper
  (`02-backend.md:350`). Artinya kontrak 48 rute (`apps/api/cmd/server/main.go:184-247`)
  tidak punya oracle sama sekali.
- Migrasi meng-hardcode schema `bm.` sehingga DB uji tidak bisa dibangun dari repo
  (`02-backend.md`, P2-12) — ini penyebab langsung angka di atas.
- Yang **sudah** ada dan harus dipertahankan: test domain padat (37 fungsi) dan satu
  golden lintas-bahasa FE↔BE (`apps/web/scripts/tests/teamTournamentGolden.test.ts:1-12`,
  `apps/web/scripts/tests/fixtures/team-tournament.golden.json`).

Konsekuensi untuk rewrite: **tidak ada baseline perilaku yang bisa diwarisi**. Parity harness
bukan pelengkap, ia satu-satunya spesifikasi yang dapat dieksekusi.
---

## 1. Piramida uji untuk stack baru

| Lapis | Isi | Jumlah target | Runtime target | Pemicu |
|---|---|---|---|---|
| Unit (domain murni) | validasi snapshot, tier, nama, skor, bracket | ~400 kasus | < 5 s | setiap simpan |
| Property-based | poin, generator jadwal, validasi skor, standings | 6 suite × 1 000 kasus | < 10 s/suite | setiap simpan |
| Integration (DB) | store: OCC, lock, ingest, rebuild | ~150 kasus | < 60 s | per modul |
| Contract (HTTP) | 48 rute + error envelope | ~120 kasus | < 20 s | per modul |
| **Parity (Go↔Nim)** | golden replay | ~80 kasus | < 90 s | per modul + rilis |
| E2E (Playwright) | journey pengguna | ~15 alur | < 5 min (TECH-SPEC §9) | pra-rilis |
| Visual + a11y | 3 viewport × rute | ~40 tangkapan | < 5 min | pra-rilis |

Rasio **jumlah kasus** ≈ 55 / 10 / 20 / 15 — unit dan property mendominasi karena murah dan
deterministik; rasio **waktu** justru terbalik (E2E/visual > 80%). Aturan keras: bug logika tidak boleh "tertangkap pertama kali" di lapis E2E.

Konvensi nama berkas mengikuti pola matang di `~/Projects/cbs/task:85-88`: `t*.nim` = unit,
`it*.nim` = integration. Satu berkas = satu binary (`nim c -r`), dijalankan `./task test`
seperti `~/Projects/majadu/task:940-950`.
---

## 2. Parity harness Go↔Nim (inti memo ini)

### 2.1 Posisi dan batas

Parity **bukan** "jalankan v1 lalu bandingkan". v1 tidak boleh hidup di CI (tidak ada image
legacy, tidak ada DB `bm` yang bisa dibangun dari repo). Yang disimpan adalah **hasil
tangkapan**: request + response + sidik jari state DB, dibekukan sebagai golden JSON.

Alur:

```
[sekali, manual]  v1 (commit tertulis di manifest) + pg_dump beku
      └─ parity:capture  →  testdata/parity/v1/<case>/{request,response,state}.json
[setiap CI]       Nim server + DB hasil restore dump  →  parity:replay  →  diff kanonik
```

Karena capture hanya sekali per rilis v1, **kualitas korpus = kualitas spesifikasi**. Korpus
harus diturunkan dari daftar rute (`cmd/server/main.go:184-247`) + tabel temuan
`05-security.md` + `07-database.md`, bukan dari selera.

### 2.2 Format fixture

`testdata/parity/cases.json` — indeks, satu entri per kasus:

```json
{
  "id": "session.put.granular-score-occ-conflict",
  "route": "PATCH /sessions/{id}/games/{gameKey}",
  "source": "apps/api/internal/handler/granular.go:120",
  "state": "sessions/granular-2court",
  "request": { "method": "PATCH", "path": "/sessions/$sid:1/games/0-1",
               "headers": { "If-Match": "\"3\"", "Content-Type": "application/json" },
               "body": { "scoreA": 21, "scoreB": 19 } },
  "expect": { "status": 409, "bodyFile": "response.json", "headers": ["ETag"] },
  "unordered": ["body.games", "body.players"],
  "mask": ["body.sessions[].updated_at", "body.sessions[].share_code"]
}
```

Berkas `state.json` menyimpan **hash** dump sesudah request (`sha256` per tabel, bukan isi),
sehingga kasus tulis diverifikasi dua arah: response **dan** efek DB. Tanpa ini, bug
"commit lalu balas 500" (`02-backend.md`, P1-3) lolos dari diff response.

### 2.3 Normalisasi (wajib, satu implementasi, dua pemakai)

Normalizer ditulis **sekali** di Nim dan dipakai runner; capture memakai implementasi yang
sama (Go menulis JSON mentah → normalizer Nim merapikan). Kalau dua implementasi, diff akan
memperdebatkan normalizer, bukan perilaku.

| Volatil | Aturan |
|---|---|
| UUID | alias deterministik per kasus: `$uuid:player#3` (urut kemunculan, bukan acak) |
| `share_code` / token | `$token:1`, `$token:2` — pemetaan disimpan di `case.mapping.json` (di-commit, agar diff bermakna) |
| Timestamp absolut | `$ts:2026-03-01T00:00:00Z` + offset relatif `+0s`, `+90s` terhadap `session.created_at` |
| `server_time`, `duration_ms`, `request_id`, `trace_id` | dibuang (daftar di `mask`) |
| Urutan array | hanya untuk field di `unordered`: sortir dengan kunci stabil yang dideklarasikan (`game_key`, `player_id`, `rank`) |
| Kunci objek JSON | selalu sortir leksikografis sebelum diff (canonical form) |
| Unicode / spasi nama | NFKC + trim ganda dibandingkan apa adanya; **jangan** menormalkan isi nama — itu perilaku yang diuji |

Larangan: normalizer tidak boleh membuang perbedaan angka, status, atau pesan error; field yang terlalu berisik harus dibuang di sumber atau kasusnya tidak dipakai.

### 2.4 Toleransi angka: nol

Poin dihitung dari aritmetika eksak (`internal/store/rank_points.go:68-96`: `gameValue`,
`opponentMultiplier`) dan disimpan `float64` (`rank_points.go:34-36`). Tidak ada alasan
toleransi: **byte-equality setelah serialisasi desimal tetap** (6 desimal, `strconv`/`formatFloat`
yang sama di kedua sisi). Kalau Nim memilih integer/decimal, itu **perubahan kontrak** dan harus
dinyatakan eksplisit di `cases.json` (`"numeric": "decimal6"`), bukan disamarkan epsilon.

Aturan: `abs(a-b) > 0` → gagal. Tidak ada `1e-9`. Alasan: poin masuk papan publik
(`rank_points.go:493-520`), selisih 1e-9 menggeser peringkat dan tidak pernah bisa direproduksi
oleh pengguna.

### 2.5 Regenerasi yang aman

1. `./task parity:capture` menolak jalan bila `testdata/parity/v1/` punya perubahan belum
   di-commit (mencegah capture menimpa golden yang sedang di-review).
2. Hasil ditulis ke `v1.next/`, **bukan** menimpa `v1/`. `manifest.json` mencatat:
   `v1_git_sha`, `dump_sha256`, `captured_at`, `routes_covered`, `cases_total`.
3. `./task parity:accept` menghitung diff per kasus dan menolak bila jumlah kasus **turun**
   atau ada rute yang kehilangan kasusnya.
4. Golden `v1/` bersifat **append-only** dalam satu siklus rilis; menghapus kasus butuh baris
   di `docs/plan/parity/divergences.md` (id kasus + alasan + pemilik).
5. Dump DB dibekukan (`testdata/parity/db/template.sql.gz`, checksum di manifest) dan
   **tidak** berisi data nyata — seed sintetis, mengikuti pola `~/Projects/majadu/tools/v1fixture`
   (`~/Projects/majadu/task:469-495`).

### 2.6 Runner di CI tanpa layanan legacy

`./task parity` (Nim tool, `tools/parityctl`):

1. restore `template.sql.gz` ke DB sementara `bm_parity_<pid>`;
2. start binary Nim di port ephemeral dengan `MAJADU_NOW=2026-03-01T00:00:00Z`
   (**fake clock wajib** — tanpanya jendela 12 minggu bergeser mengikuti kalender dan korpus
   busuk dalam setahun; lihat `07-database.md` P2-6 soal timezone);
3. replay kasus secara serial (urutan penting untuk kasus OCC/lock), lalu diff kanonik;
4. `exit 1` pada diff pertama + tulis `.build/parity/<case>.diff` (unified diff, bukan dump).

Target: 80 kasus < 90 s, satu DB, satu proses. Tidak ada dependency ke Go setelah capture.

### 2.7 Divergensi yang disengaja

Rewrite akan **sengaja** berbeda (perbaikan P0-1 `share_code`, P1-3 commit-then-load,
batas input P1-2). Mekanisme:

- `cases.json` punya `"expectedDivergence": { "reason", "audit": "05-security.md:35" }`.
- Kasus seperti itu **tetap direplay** dan tetap harus berbeda dengan diff yang **persis**
  dideklarasikan (`expectNim`: status berbeda, field hilang). Kalau Nim kebetulan cocok dengan
  v1, test gagal — perbaikan keamanan tidak boleh diam-diam kambuh.
- Daftar divergensi di-review di PR yang sama dengan perubahan perilakunya.
---

## 3. Property tests (invariant, bukan contoh)

Pakai pendekatan generator + shrinker di level modul (`tproperty_*.nim`), bukan di level HTTP.

**Poin & papan (`rank_points`)**

- `prop_points_nonnegative`: untuk setiap rentang skor valid, `gameValue ≥ 0`
  (`rank_points.go:68-96`).
- `prop_points_monotone_margin`: margin naik ⇒ poin tidak turun (fungsi monoton pada `[-target, target]`).
- `prop_best_n_selection`: total papan = jumlah `n` entri terbesar; `n = min(best_n, tersedia)`
  (`rank_points.go:493-520`); `counted_entries ≤ best_n`.
- `prop_window_boundary`: entri tepat di `as_of - window_weeks` masuk, satu hari lebih tua keluar
  (batas inklusif dideklarasikan sekali, diuji di dua sisi).
- `prop_rank_total_order`: urutan papan deterministik — tie-break `(points desc, name asc, id asc)`;
  dua pemain tidak pernah berbagi `(points, name, id)`.
- `prop_board_no_duplicate_player`: satu pemain satu baris walau punya banyak source.
- `prop_min_sessions_filter`: `min_sessions` hanya menyembunyikan baris, tidak mengubah poin
  (`internal/store/rank_points_unit_test.go:11-40`).

**Generator jadwal** (`apps/web/src/generator/index.ts`, 23 KB — logika ini pindah ke backend)

- `prop_generator_deterministic`: input sama + seed sama ⇒ jadwal identik (byte-equal).
- `prop_generator_no_duplicate_pair`: tidak ada pasangan bertemu dua kali sebelum semua pasangan habis.
- `prop_generator_rest_balance`: selisih jumlah main antar pemain ≤ 1 setelah `n` ronde penuh.
- `prop_generator_court_capacity`: `len(games) ≤ courts × slots`, tidak ada court ganda di slot sama.
- `prop_generator_gender_constraint`: komposisi gender tiap game memenuhi `KindSpec.Valid()`
  (`internal/domain/rating_match.go:42-50`).

**Validasi skor & snapshot** (`internal/domain/validate.go:24`, `transform_test.go:10`)

- `prop_score_within_target`: `0 ≤ score ≤ target` untuk tiap `kind`.
- `prop_reject_implies_reason`: setiap penolakan membawa kode error yang stabil (bukan string bebas).
- `prop_snapshot_roundtrip`: `parse(serialize(s)) == s` untuk snapshot valid.
- `prop_bounds_enforced`: `courts > 12`, `len(schedule) > courts×60`, `len(fixMatches) > 60` selalu
  ditolak — properti ini **baru** (celah P1-2, `02-backend.md`).

**Standings / turnamen** (`apps/web/scripts/tests/standings.test.ts` sebagai oracle semantik)

- `prop_standings_points_consistent`: total poin klasemen = Σ poin game yang dihitung.
- `prop_standings_tiebreak_stable`: tie-break tidak bergantung urutan input (shuffle ⇒ hasil sama).
- `prop_void_match_zero_effect`: game `Void()` tidak mengubah klasemen maupun poin
  (`rating_match.go:87-97`).
---

## 4. Isolasi DB untuk subagent paralel

**Pilihan: template database + clone per worker.**

```
bm_template   ← migrate + seed sekali (cache by checksum migrasi)
bm_t_w1..wN   ← CREATE DATABASE ... TEMPLATE bm_template   (~300 ms)
```

Alasan menolak alternatif:

- **schema-per-worker** lebih murah, tetapi `pg_advisory_xact_lock` dipakai sebagai kunci tulis
  (`store/session_write.go`, lihat `02-backend.md` metrik "Lock"); advisory lock tidak ter-scope
  per schema sehingga dua worker bisa saling blokir. Selain itu v1 meng-hardcode `bm.`
  (`02-backend.md`, P2-12) dan test menolak schema `bm`
  (`internal/store/absent_policy_verify_test.go:28-34`).
- **transaction rollback per test** tidak bisa: store membuka transaksi sendiri dan
  meng-`Commit` (jalur OCC/lock). Rollback hanya bekerja bila unit under test menerima `tx`,
  bukan `pool`.

**Seeding**: seed deterministik dengan UUID tetap dan tanggal relatif terhadap
`as_of = 2026-03-01`, ditulis sebagai `testdata/seed/*.sql` (bukan kode Go/Nim), sehingga
fixture parity dan fixture integration memakai data yang sama.

**Isolasi per test**: `TRUNCATE` daftar tabel tetap (urutan FK eksplisit) + re-seed baris
minimum; bukan `DROP SCHEMA` (mahal, memutus prepared statement cache).

**Cleanup**: `trap` di task runner menjatuhkan `bm_t_*`; nama DB **wajib** berakhir `_test`
atau `_ci`, mengikuti guard matang `~/Projects/majadu/task:167-190`.

**Fail-closed**: tidak ada `skip` karena env kosong. Pola yang dipakai:
`~/Projects/majadu/apps/api/tests/itdb.nim:1-10` — tanpa URL test **gagal**, kecuali
`*_SKIP_DB_TESTS=1` disebut eksplisit. Ini menutup kelas bug `03-ci.md:85-90`.

**Target waktu**: template build ≤ 20 s (sekali per run, cached), clone ≤ 300 ms/worker,
reset per test ≤ 15 ms, suite integration penuh < 60 s dengan 4 worker.
---

## 5. Gates

| Gate | Isi | Batas waktu | Wajib untuk |
|---|---|---|---|
| Tier 0 `./task check` | format, lint, typecheck, unit + property | ≤ 60 s | setiap commit |
| Tier 1 `./task verify <module>` | Tier 0 + integration modul + contract snapshot + parity subset rute yang tersentuh | ≤ 5 min | modul "done" |
| Tier 2 `./task ci` | Tier 1 semua modul + parity penuh + E2E + a11y + visual | ≤ 20 min | merge ke `main` |

**Definisi "modul selesai"** (semua harus benar):

1. unit + property hijau, tanpa `skip`;
2. integration hijau terhadap DB nyata (bukan mock), termasuk satu test konkurensi untuk
   jalur yang memakai lock;
3. setiap rute milik modul punya kasus contract **dan** kasus parity (kecuali didaftarkan
   sebagai divergensi);
4. contract snapshot (`api/openapi.yaml`) di-regenerate dan `git diff --exit-code` bersih;
5. coverage floor terpenuhi;
6. tidak ada test baru di karantina.

**Coverage floor** (line coverage; Nim `--coverage`, angka per paket bukan total):

| Paket | Floor |
|---|---|
| `domain/*` | 90% |
| `application/*` | 80% |
| `infrastructure/store` | 70% (jalur write-path wajib 100% cabang: OCC, lock, ingest) |
| `http/handler` | 85% (request → response, termasuk semua cabang error) |
| total | 75% |

Angka ini sengaja jauh di atas 14,6% dan **dijaga sebagai ratchet**: floor tidak boleh turun
di PR mana pun.

**Mutation testing**: layak, tapi terbatas. Nim belum punya mutator matang (status per
2026-11: belum ada ekuivalen `cargo-mutants`/`pitest` yang stabil). Karena itu:

- nightly: skrip mutasi kustom (token-level: `>=`→`>`, `+`→`-`, `0`→`1`) **hanya** pada
  `domain/rating*`, `domain/validate*`, `domain/generator*` — tiga berkas dengan risiko drift
  tertinggi;
- target kill rate ≥ 80% di sana; di bawah itu, tambah kasus, bukan tambah mutan;
- tidak di PR (biaya > nilai). Ini keputusan sadar, bukan kelalaian.

**Flake policy**:

- CI: `retries: 0` (pola `~/Projects/majadu/playwright.visual.config.ts:15-20`).
- flake = bug sampai terbukti sebaliknya; tidak ada `sleep`, tidak ada retry loop di test.
- karantina: entri di `docs/plan/quarantine.md` wajib punya pemilik, alasan, dan tanggal
  kedaluwarsa ≤ 14 hari; test karantina diberi tag eksplisit dan **tetap dihitung merah**
  di gate Tier 1 setelah kedaluwarsa. Satu test tidak boleh dikarantina dua kali.
---

## 6. Security test suite (nama test = nama temuan)

Semua di `tests/it_security_*.nim`, dijalankan di Tier 1 untuk modul terkait.

| Test | Menutup |
|---|---|
| `security_session_list_hides_share_code` | P0-1 (`05-security.md:35`) |
| `security_write_requires_capability` | P1-1 IDOR turnamen (`:66`) |
| `security_rating_ingest_rejects_anonymous_source` | P0-2 pemalsuan poin (`:51`) |
| `security_admin_token_never_in_localstorage` | P1-2 (`:73`) — diuji di FE, lihat §7 |
| `security_admin_failed_auth_is_audited` | P1-3 (`:80`) |
| `security_rate_limit_respects_trusted_proxy` | P1-4 (`:87`) |
| `security_player_registration_quota` | P2-1 (`:93`) |
| `security_snapshot_write_bounds` | P2-2 + P1-2 backend (`:100`) |
| `security_sse_origin_allowlist` + `security_sse_connection_cap` | P2-3 (`:107`) |
| `security_text_field_length_caps` | P2-4 (`:114`) |
| `security_cors_preflight_denied_origin` | P2-13 (`02-backend.md`) |
| `security_schema_name_validated` | P3-3 (`05-security.md:140`) |
| `security_metrics_not_public` | P3-2 (`:134`) |
| `security_error_body_has_no_stack_trace` | P3-1 (`:128`) |

Aturan: setiap test menegaskan **status + body**, bukan hanya status — "403 tanpa pesan" tetap
bocor lewat timing/body di implementasi berikutnya.
---

## 7. Frontend saat kontrak berubah

1. **Type dari kontrak, bukan tangan.** `api/openapi.yaml` saat ini tertinggal 12+ grup rute
   (`02-backend.md`, P3-24). Urutan kerja: lengkapi spec → generate TS (`openapi-typescript`)
   ke `packages/api-client` → gate `git diff --exit-code`. Type tulisan tangan di
   `apps/web/src/types/index.ts` dihapus bertahap; selama transisi, satu test
   `contract_types_match_spec` membandingkan field yang dipakai.
2. **Component test tanpa render suite penuh.** Pertahankan gaya yang sudah ada: `node --test`
   pada modul murni (`apps/web/package.json:13`, `scripts/tests/*.test.ts`). Yang diuji:
   normalisasi, sorting, format label, state machine UI. Render penuh hanya lewat Playwright —
   jangan menambah RTL + jsdom untuk hal yang sudah dicakup E2E.
3. **Golden lintas-bahasa diperluas.** Pola `teamTournamentGolden.test.ts:1-12` adalah prototipe
   yang benar: satu JSON, dipakai FE, BE, dan parity. Jadikan `testdata/parity/v1/` sumber
   tunggal; FE membaca subset yang relevan (`view models`), bukan menyalin.
4. **a11y & kontras.** Playwright + `@axe-core/playwright` per rute dengan tag WCAG 2.2 AA,
   mengikuti `~/Projects/majadu/e2e/a11y.spec.ts:1-25`; kontras diukur (bukan diklaim) dengan
   alat `antislop-contrast` untuk pasangan warna yang tidak tercakup axe (mis. teks di atas
   gradient/overlay). Floor: 0 violation `serious`/`critical`.
5. **Visual.** Screenshot per viewport, `workers: 1`, `retries: 0`, baseline di-commit
   (`~/Projects/majadu/playwright.visual.config.ts`). Diff visual **tidak** boleh di-update
   otomatis di CI — hanya manual dengan review.
6. **Yang berubah saat kontrak berubah** (checklist PR): tipe generated → fixture parity →
   test component → E2E journey → baseline visual. Kalau salah satu tidak berubah padahal
   kontrak berubah, PR ditolak.
---

## 8. Risiko uji terbesar

1. **Parity membekukan bug v1 sebagai spesifikasi.** Korpus diambil dari v1 yang punya IDOR
   tulis (`05-security.md:35`) dan batas input tak ada (`02-backend.md`, P1-2). Mitigasi:
   `expectedDivergence` wajib per kasus (§2.7); tanpa itu, "lulus parity" bisa berarti
   "berhasil mereproduksi kerentanan".
2. **v1 tidak bisa dijalankan lagi**, jadi korpus tidak dapat diregenerasi setelah image/DB
   hilang. Mitigasi: `manifest.json` + dump ber-checksum + larangan menghapus kasus.
3. **Waktu tidak deterministik.** Jendela 12 minggu, auto-lock harian, `earned_at` WIB
   (`07-database.md` P2-6) membuat replay berubah sendiri. Tanpa fake clock, korpus busuk
   dalam hitungan minggu — ini kegagalan yang paling mungkin terjadi dan paling sulit didiagnosis.
4. **Normalizer menyembunyikan drift nyata.** Urutan array dan mask timestamp adalah tempat
   bug bersembunyi; mitigasi: daftar `unordered`/`mask` di-review sebagai bagian dari kontrak,
   dan dilarang mencakup field numerik/status.
5. **Cakupan korpus sempit (happy path).** v1 tidak punya test HTTP (`02-backend.md:350`),
   jadi jalur error hanya masuk korpus bila capture sengaja menyusunnya. Target: ≥ 40% kasus
   adalah penolakan (4xx) dan konflik (409/412).
