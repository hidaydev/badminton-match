# ABSENT_TBD_PLAYERS_DESIGN.md

**Status:** PROPOSAL — belum diimplementasikan
**Tanggal:** 2026-08-18
**Rev:** 1
**Lokasi:** root badminton-match
**Dokumen terpisah dari:** `RATING_ENGINE_DESIGN.md` (berhubungan, tapi independen — lihat §6 untuk referensi silang)

---

## 1. Latar & Tujuan

Dua perilaku lapangan di aplikasi yang perlu didesain ulang:

1. **Absent player** — nama tetap ada di fixture tapi di-mark absent. Faktanya di lapangan, pemain absent **biasanya diganti orang lain saat main** (via change player), tapi kadang dibiarkan apa adanya di app.
2. **Placeholder player** ("free", "free 1", "free 2", dst.) — host mengetik nama fiktif untuk mengisi slot kosong yang sub-nya belum dikenal, walau sudah ada fitur swap/change player.

Keduanya berakar dari satu hal: **data tidak selalu mencatat siapa yang beneran bermain**. Dokumen ini menetapkan semantik yang konsisten di semua permukaan (UI standings, career stats, rating engine) dan merancang fitur slot TBD yang jujur.

---

## 2. Perilaku Saat Ini (fakta + sumber)

| # | Fakta | Sumber |
|---|---|---|
| 1 | Mark absent **tidak menyentuh schedule** — pemain absent tetap di fixture, game-nya tetap bisa diberi skor | `sessionSnapshot.ts`, `GeneratePage.tsx` |
| 2 | Standings sesi: absent dikeluarkan dari ranking (section "Absent" terpisah) | `StandingsTab.tsx:20-25` |
| 3 | Standings sesi: **game yang memuat pemain absent tetap dihitung untuk pemain lain** (teammate & lawan dapat W/L/poin) | `standings.ts:20-36` |
| 4 | Career stats (backend): **dihitung untuk semua, termasuk si absent** — query tanpa filter `is_absent` | `store/stats.go:99-118, 164-203` |
| 5 | Change player **mengganti pemain di game** (schedule) + rebuild daftar pemain — sub tercatat sebagai pemain sesi | `queries/sessions.ts:197-215` (`applyChange`, `rebuildPlayersFromSchedule`) |
| 6 | "free" di-typing di PlayersPage → **auto-register** ke `bm.players`/aliases saat publish → muncul di career stats, player history, dan (nanti) leaderboard rating | `store/session.go` (resolve via aliases), `utils/resolvePlayers.ts` |
| 7 | `include_absent_players` ada sebagai kolom DB tapi **tidak dipakai frontend** (legacy) | `store/session.go:85` |
| 8 | Swap player **tidak memindahkan skor** (skor tetap di posisi slot-court); change player mengganti pemain per-game | `utils/swap.ts` |

**Inkonsistensi kunci:** sesi bilang "si absent tidak main" (dikeluarkan dari ranking), tapi career stats bilang "dia main N game". Dan game "hantu"-nya memberi poin ke pemain lain di standings.

---

## 3. Wawasan Kunci: Data BISA membedakan game yang di-replace

Karena change player **menghapus pemain lama dari game** (fakta #5):

- **Game yang di-replace** → memuat nama sub, nama si absent sudah hilang → game **valid**, sub tercatat.
- **Game yang masih memuat pemain absent** → tidak di-replace → **ambiguous**:
  (a) game tidak terjadi, atau (b) terjadi dengan sub tak tercatat (nama dibiarkan "free"/absent).

Data tidak bisa membedakan (a) vs (b) — tapi bisa membedakan "di-replace" vs "tidak". Itu cukup untuk kebijakan yang konsisten:

```
Game VALID   : semua pemain di game ada (hadir, non-placeholder)
Game VOID    : memuat ≥1 pemain absent ATAU placeholder (tidak di-replace)
```

---

## 4. Desain A — Semantik Absent Player

### 4.1 Definisi

- **Absent = pemain tidak bermain sesi itu** (per-session, per-player).
- Game yang masih memuat pemain absent = **void** → tidak dihitung di permukaan mana pun (standings sesi, career stats, rating).
- Game yang pemain absent-nya sudah di-replace (via change player) = **valid** → dihitung normal untuk semua yang ada di game (termasuk sub).

### 4.2 Konsistensi lintas permukaan

| Permukaan | Perubahan |
|---|---|
| Standings sesi (`StandingsTab.tsx` / `computeStandings`) | Game void tidak ditallikan untuk siapa pun — teammate & lawan tidak dapat W/L dari game hantu. Absent tetap tampil di section "Absent" (bukan di ranking) |
| Career stats (`store/stats.go`) | Semua query (GamesPlayed, W/L, PointsFor/Against, TopPartners, TopOpponents) difilter: buang game yang memuat ≥1 pemain absent di sesi itu. Absent tetap muncul di daftar `sessions` (dengan flag `absent: true`) — menandakan keikutsertaan sesi, bukan game |
| Rating engine (§6) | `absent_policy = skip_game` — game void tidak diingest untuk siapa pun |

### 4.3 Implementasi filter "game void" (SQL)

Predikat void per game:

```sql
-- game void jika ada pemain di game yang is_absent di sesi itu
NOT EXISTS (
  SELECT 1
  FROM scheduled_game_players sgpv
  JOIN session_players spv
    ON spv.internal_id = sgpv.session_player_internal_id
   AND spv.session_id = sg.session_id
  WHERE sgpv.scheduled_game_internal_id = sg.internal_id
    AND spv.is_absent = true
)
```

Diterapkan sebagai tambahan `WHERE` di query stats (bukan filter di Go — lebih murah & satu sumber kebenaran). Standings frontend: filter di `computeStandings` — skip slot yang memuat id absent (perlu `absentPlayerIds` masuk sebagai argumen).

### 4.4 UX: dorong alur replace saat mark absent

Saat host mark absent (GeneratePage / SharedSessionPage), tampilkan:

```
"X absent — N game memuat X."
[ Ganti di semua game (pilih pengganti dari pemain lain / TBD slot) ]   ← dorong ini
[ Biarkan — game yang memuat X akan dianggap tidak dimainkan ]          ← konsekuensi jelas
```

Ini mengubah mark-absent dari "jebakan data kotor" menjadi alur dua-langkah yang disadari: **replace dulu, atau void**.

### 4.5 Catatan

- Jika game void tapi host ingin menghitungnya (sub tak tercatat tapi beneran main) → solusi yang benar adalah mencatat sub-nya (change player / TBD → nama asli), bukan mengecualikan game dari aturan void. Jangan buat pengecualian berbasis perasaan — konsistensi > fleksibilitas.
- Absent tidak memengaruhi rating pemain itu sendiri (dia tidak main → tidak ada event). Yang berubah: lawan/partner tidak dapat poin dari game hantu.
- **Sub hasil change player** — entah sudah terdaftar di roster atau nama baru yang diketik saat replace — **otomatis masuk leaderboard**: `rebuildPlayersFromSchedule` menambahkan sub ke daftar pemain sesi, lalu resolve/auto-register saat publish. Ini perilaku yang diinginkan (keputusan §9.5) dan sudah didukung tanpa perubahan kode.

### 4.6 Lock otomatis saat ganti hari (auto-lock) — basis "data final" yang andal

**Masalah:** lock manual bergantung disiplin host — sering telat atau tidak pernah, padahal rating engine memakai `status = 'locked'` sebagai gate ingest (`ingest_locked_only`). Sesi yang tidak pernah di-lock = tidak pernah final = tidak pernah ter-rating.

**Desain:** scheduler auto-lock — sesi yang **tanggalnya sudah lewat** otomatis di-lock:

```
AutoLockExpiredSessions:
  UPDATE bm.sessions
  SET status = 'locked', updated_at = now()
  WHERE status = 'draft' AND session_date < current_date
```

- Dijalankan oleh **ticker berkala** di majadu-api (misal tiap 30–60 menit) — murah, idempotent (hanya draft yang lewat tanggal).
- Sesi hari ini / belum lewat **tetap editable** — auto-lock tidak pernah mendahului data final; lock hanya terjadi saat hari berganti.
- **Unlock tetap tersedia** (admin, existing) untuk koreksi sesi yang salah lock. Unlock setelah ingest → fingerprint beda → wajib revert + re-ingest (alur rating §4.4).
- Menjawab keputusan §9.4: sesi tidak boleh terkunci sebelum data final — mekanismenya bukan "dilarang lock", tapi lock manual **tidak lagi wajib** karena auto-lock menangani finalisasi.

**Catatan operasional:** sesi yang di-lock otomatis tetap bisa di-unlock admin (misal host lupa skor satu game) — proses koreksinya sama seperti sekarang. Auto-lock bukan penghapus edit, hanya penanda final default.

---

## 5. Desain B — TBD / Placeholder Player

### 5.1 Konsep

"free" adalah emulasi manual dari fitur yang tidak ada: **slot TBD** ("to be determined"). Bukan masalah disiplin host — itu workaround alami untuk slot yang sub-nya belum dikenal saat setup. Fitur yang jujur:

- **Slot TBD** = entri pemain tanpa identitas nyata, boleh masuk setup & generation (jumlah pemain tetap terhitung → jadwal terisi), WAJIB di-replace sebelum/saat main (alur sama dengan change player), dan **tidak pernah menjadi pemain terdaftar**.

### 5.2 Representasi & deteksi

**Jangka pendek (tanpa perubahan UI besar)** — deteksi pola nama di publish:

```
pola placeholder (config, case-insensitive):
  "free", "free 1", "free 2", ...      (pola ^free(\s+\d+)?$)
  "tbd", "tbd 1", ...
  "default", "default 1", ...          (pola ^default(\s+\d+)?$)
  "?", "??", "xxx", "unknown", "kosong", "belum ada"
```

Pemain yang cocok pola → `isPlaceholder = true` secara implisit (server-side, di resolve/register path). Tidak dibuatkan `bm.players`/alias.

**Jangka panjang (fitur eksplisit)** — PlayersPage mendapat aksi "Tambah slot TBD":
- Entri bernama "TBD" (atau kosong yang dirender "TBD") dengan badge.
- Snapshot `Player` bertambah field opsional `placeholder?: boolean`.
- Server: validasi nama tetap berlaku (nama wajib non-blank) → frontend kirim nama "TBD"/"tbd" + flag, ATAU server izinkan nama placeholder khusus — keputusan detail di P1.

### 5.3 Siklus hidup

```
Setup (PlayersPage)      → tambah slot TBD (count pemain terisi → jadwal seimbang)
Generate                 → TBD ikut di-schedule seperti pemain biasa
Sebelum/saat main        → replace TBD via change player (pilih sub dari pemain lain,
                           atau ketik nama baru yang jadi pemain sesi)
Publish                  → TBD yang tersisa: tidak diregister, game-nya void
                           (kalau dipublish setelah main dengan skor → lihat 5.4)
```

### 5.4 Kebijakan per lapisan

| Lapisan | Kebijakan placeholder |
|---|---|
| Registrasi (`bm.players`/aliases) | **Tidak pernah** dibuatkan entri |
| Career stats | Tidak dihitung sebagai pemain (tidak muncul di daftar); game yang memuat placeholder → **void** (predikat §4.3 diperluas: absent ATAU placeholder) |
| Standings sesi | TBD yang tersisa ditampilkan seperti section absent ("TBD — belum diganti"), tidak di ranking |
| Rating engine | `placeholder_policy = rate_as_unknown` (default): game tetap diingest untuk pemain NYATA (mereka beneran main), placeholder diperlakukan sebagai lawan tak dikenal — rating 1250, rd=350 (RD tinggi otomatis membatasi magnitude update via g(rd)); placeholder TIDAK dipersist di rating_players. Opsi `skip` tersedia di config |
| Player history / leaderboard | Tidak muncul |

Alasan `rate_as_unknown` (bukan skip): jika skip, pemain nyata yang main melawan sub tak dikenal kehilangan game yang sah (ter-*under-rate*). Dengan memperlakukan sub sebagai "pemain baru 1250/rd350", game tetap berarti dan ketidakpastian sub tertangkap secara alami oleh sistem Glicko.

### 5.5 Backward compatibility ("free*" yang sudah terdaftar)

- Data historis: `bm.players` berisi canonical "free", "free 1", dst. (dan alias).
- Deteksi pola placeholder berlaku **read-time** juga: pemain yang nama-nya cocok pola → diperlakukan sebagai placeholder di stats/rating (tidak perlu dihapus; lebih aman daripada DELETE — bisa merusak FK dari match history/alias).
- Opsional (admin): script one-off untuk mengganti canonical name "free*" → tidak dihapus, hanya di-mark agar tidak muncul di leaderboard (atau biarkan, karena filter read-time sudah menangani).

---

## 6. Dampak ke Rating Engine (referensi silang `RATING_ENGINE_DESIGN.md`)

Perubahan yang harus disinkronkan ke rating doc (Rev 2):

1. `absent_policy` default: `skip_player` → **`skip_game`** (game void = tidak diingest sama sekali) — karena semantik §4.1.
2. Tambah `placeholder_policy` di §5.5 config: `rate_as_unknown` (default) / `skip`.
3. §8 edge cases: baris absent & placeholder di-update mengikuti definisi baru.
4. **Konsekuensi penting untuk rating**: karena game void tidak diingest, fingerprint sumber **harus memuat semua game** (termasuk yang void) — supaya "replace sub setelah ingest" = perubahan fingerprint → 409/auto_reconcile. Void bukan alasan untuk menghapus game dari representasi sumber.
5. Pemain TBD yang di-replace menjadi pemain nyata → ingest memuat pemain baru (auto-register) — alur normal.

---

## 7. Edge Cases

| Kasus | Keputusan |
|---|---|
| Absent di-replace di 3 dari 5 game | 3 game valid (sub tercatat), 2 void |
| Game skor penuh tapi memuat pemain absent | Void — skor tidak menyelamatkan game hantu (sub tak tercatat) |
| Host mark absent SEBELUM generate | Generate ulang tanpa si absent (perilaku existing) — tidak ada game hantu |
| "free" dipakai nama asli orang (kebetulan) | Pattern match → salah identifikasi. Mitigasi: pola spesifik (`^free\s*\d*$` dll.) + override config manual |
| TBD tersisa di publish tanpa skor | Game tanpa skor tetap tersimpan; tidak dihitung apa pun (belum dimainkan) |
| TBD tersisa dengan skor (sub main tapi tak dicatat) | Void di stats; `rate_as_unknown` di rating (game pemain nyata tetap berarti) |
| Placeholder vs TBD lama dengan alias sudah terdaftar | Read-time filter + tidak dihapus (FK safety) |
| Absent yang tidak di-replace lalu di-unlock & diedit | Alur normal — edit mengubah fingerprint → re-ingest |

---

## 8. Task List

### P0 — Semantik & konsistensi (backend + UI)
- [x] 1. Migration `000007_absent_placeholder.sql`: (a) index pendukung query void, (b) seed `app_config` untuk pola placeholder (kalau mengikuti pola rating_config) — atau simpan di Go constant + config → **diputuskan: index tidak diperlukan (query void pakai EXISTS over join existing, live test ok); pola placeholder di Go constant + config P1**
- [x] 2. `store/stats.go`: filter game void (predikat §4.3) di semua query stats (GamesPlayed, W/L, poin, partner, opponent) — unit + live test parity → **integration test `TestIntegrationStatsVoidGames` PASS live (bm_dev, 2.4s)**
- [x] 3. `computeStandings` (frontend): terima `absentPlayerIds` → skip game void; test → **param `voidPlayerIds` (opsional, backward compat) + 2 test baru (51 total PASS)**
- [x] 4. StandingsTab: section placeholder (TBD) terpisah, konsisten dengan absent → **void juga diterapkan di `PlayerMatchDetailSheet` (audit catch — match history tanpa game hantu) + `InstagramPostPage` (export leaderboard). `PlayerStatsPanel` tidak diubah: playCount = fakta schedule, bukan rating**

**Verifikasi P0:** career stats absent == 0 game; teammate tidak dapat W/L dari game hantu; test parity SQL↔Go. → **lengkap: unit 51 PASS + integration live PASS + full store suite PASS**

### P1 — Placeholder detection & registrasi
- [x] 5. `store/session.go` + `store/tournament.go` (resolve path): deteksi pola placeholder → jangan register ke players/aliases; pemain placeholder tetap tersimpan di session_players (player_id NULL) → **`domain.IsPlaceholderName` (regex: free/tbd/default/xxx/unknown/kosong/belum ada/?+); skip di `EnsurePlayersRegistered`; `resolved[ref]=""` → `nilableString` → NULL; `resolveTournamentPlayer` diperluas pakai IsPlaceholderName; migration VPS `000007_placeholder_support.sql` (session_players.player_id DROP NOT NULL — diaplikasikan ke bm_dev + bm)**
- [x] 6. Frontend publish flow: pastikan "free*" tidak memicu modal resolve-player; tampil sebagai placeholder → **`findUnresolvedPlayers` (ShareButton/publish) mengecualikan placeholder; StandingsTab section "Not playing" (badge `tbd`)**
- [x] 7. Read-time filter: stats & player list menyembunyikan placeholder (kecuali sesi terkait) → **void predicate diperluas: `is_absent OR player_id IS NULL OR canonical_name ~* pola` (menangkap legacy "free*" bm_dev yang ternyata ADA di data riil Juni–Juli — dikonfirmasi oleh test); `PlayerStore.List` filter `IsPlaceholderName`**
- [x] 8. Test: publish sesi dengan "free" → tidak ada row baru di players; stats bebas placeholder → **unit `placeholder_test.go` (Go + TS, 2 sisi) + integration `TestIntegrationStatsVoidGames` diperluas (pre/post-count row, round-trip snapshot) — PASS live (bm_dev)**

**Verifikasi P1:** integrasi live — sesi dengan free/TBD → players table tidak bertambah. → **lengkap: unit 53 PASS (TS) + full suite Go PASS live (domain/handler/store integration)**

### P2 — UX mark-absent, slot TBD, auto-lock
- [x] 9. Mark absent → prompt "Ganti di semua game / Biarkan (void)" (§4.4) → **SummaryModal: konfirmasi void — sheet dengan jumlah game + nama pemain + [Replace in games] (masuk change-player flow) / [Continue — void]**
- [x] 10. PlayersPage: "Tambah slot TBD" + badge + replace flow (§5.2 jangka panjang) → **tombol `+ TBD` (tambah pemain bernama "tbd"), badge `tbd` di PlayerRow (via `isPlaceholderName`); replace via click-to-rename / change-player existing**
- [ ] 11. Snapshot contract: field `placeholder?: boolean` (opsional, backward compatible) → **DITUNDA (keputusan deviasi): pattern-based sudah menangani semua surface (void, no-register, badge); flag eksplisit menambah permukaan kontrak tanpa manfaat fungsional sekarang. Revisit saat perlu.**
- [x] 12. Test: TBD slot → generate → replace → publish; dan TBD tersisa → void → **unit isPlaceholderName (2 sisi) + integration void (free 1) + validasi nama duplikat aman (hanya id yang dicek unik) — check 53 PASS**
- [x] 13. `AutoLockExpiredSessions` + ticker di majadu-api (§4.6) — sesi lewat tanggal → locked → **store `AutoLockExpiredSessions` (UPDATE status='locked' WHERE draft AND session_date < current_date) + ticker 30 mnt di main.go (run saat start)**
- [x] 14. Test auto-lock: sesi kemarin → terkunci otomatis; sesi hari ini → tetap editable; unlock admin masih jalan → **integration `TestIntegrationAutoLockExpiredSessions` PASS live (kemarin → locked → write ErrLocked → unlock → delete)**

**Verifikasi P2:** alur TBD end-to-end di browser; tanpa regresi publish normal.

### P3 — Rating engine sync
- [ ] 15. Update `RATING_ENGINE_DESIGN.md`: absent_policy `skip_game`, placeholder_policy, fingerprint memuat game void, gate ingest pakai auto-lock (§6)
- [ ] 16. Rating ingest: implementasi policy + test game void/placeholder

**Verifikasi P3:** dokumentasi sinkron; rating test dengan data mengandung absent/placeholder.

---

## 9. Keputusan (2026-08-18)

| # | Pertanyaan | Keputusan |
|---|---|---|
| 1 | Pola placeholder default | Setuju pola default (`free*`, `tbd`, `xxx`, `unknown`, `?+`) **+ tambah `default`** (`^default\s*\d*$`) |
| 2 | Publish dengan TBD tersisa | **Boleh** — "publish" = simpan progres, bukan final |
| 3 | Field `placeholder` vs pattern-only | **Keduanya**: flag eksplisit untuk TBD baru (anti salah-identifikasi), pattern untuk backward compat "free*" |
| 4 | Lock sesi sebelum data final | **Sesi tidak boleh terkunci sebelum final** — solusi: auto-lock saat ganti hari (§4.6); lock manual tidak lagi wajib; unlock admin tetap ada |
| 5 | Stats list sesi dengan absent | **Ya** — flag `absent` + section terpisah di leaderboard sesi (sudah ada di StandingsTab). Sub hasil change player — dari roster atau nama baru — **tetap masuk leaderboard** (§4.5) |
