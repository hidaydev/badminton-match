# Audit Kualitas Kode — FE & BE

Tanggal: 2026-09-18 · Scope: `apps/api` (Go) + `apps/web` (React/TS)
Kriteria: best practices, DRY, SOLID (padanan Go/React), KISS — tidak saklek.
Metode: pembacaan langsung source. Setiap temuan **high** sudah diverifikasi ulang manual
(file:line dicek).

Prinsip yang dipakai untuk Go (bukan OOP murni):
- SRP → satu fungsi/paket satu tanggung jawab.
- DIP → `domain/` murni, store/handler inject dependency (pool, schema, logger).
- Interface segregation → interface kecil di sisi konsumen.
- DRY/KISS → hilangkan salin-tempel, jangan tambah abstraksi kalau tak perlu.

---

## Ringkasan Prioritas

| Sev | BE | FE |
|-----|----|----|
| High | 4 | 7 |
| Medium | 9 | 15 |
| Low | 7 | 8 |

Tema dominan: **DRY di layer store (BE)** dan **DRY di queries + ekosistem canvas/tournament (FE)**.
Keduanya duplikasi murni salin-tempel, bukan abstraksi yang salah — jadi perbaikannya mekanis
dan berisiko rendah. Selain itu ada 1 bug nyata di BE (schema) dan 1 bug copy di FE (angka 36).

---

## BAGIAN A — BACKEND (`apps/api`)

### HIGH

**A1. `NewPlayerStore` dibangun tanpa schema → literal `"bm"` bocor ke dev (bug)**
`cmd/server/main.go:175` → `store.NewPlayerStore(pool)`, padahal handler lain pakai
`cfg.DatabaseSchema` (`main.go:68,188`). `store/player.go:22-27` lalu default `sch := "bm"`.
Karena INSERT di-qualify schema eksplisit (`tournament.go:534,549`), `search_path` `bm_dev`
tidak menyelamatkan → di env dev, `POST /players` menulis ke schema `bm` (prod).
*Prinsip:* DIP (config tidak di-inject) + bug korektnes.
*Fix minimal:* `store.NewPlayerStore(pool, cfg.DatabaseSchema)`; hapus fallback `"bm"` agar
gagal keras saat schema kosong.

**A2. Skeleton transaksi OCC/idempotency/lock/broadcast disalin 4× — DRY**
`store/granular.go`: `SetGameScore` (84), `SetGamePlayed` (240), `SetAbsentPlayers` (332),
`SetGameSkipped` (428). Masing-masing mengulang: lookup session (101-104/252/356/452),
replay idempotency (115-121/260-266/357-363/459-465), cek `status != "draft"` (122/267/373/466),
`isLockNotAvailable` (137/277/368/488), cek OCC version, epilogue
`Load→Broadcast→SaveIdempotency` (206-213/319-326/416-423/556-563), dan blok auto-lock
`allGamesDecided` yang **byte-identik** (189-199 vs 541-551).
*Fix minimal:* ekstrak `beginDraftSessionTx(...)` (prolog), `finalizeGranular(...)` (epilog),
dan `autoLockIfDecided(tx, sessionID)`.

**A3. Skor Glicko disalin 2× padahal wajib bit-identik — DRY berbahaya**
`store/rating.go:469-536` (`ingest`) dan `store/rating_revert.go:340-404` (`rebuildAll`)
menulis ulang body yang sama: `GrowRD` → expected-score → `GlickoUpdate` → modifier
`TeamSizeWeight`/`VolatilityFactor` → `ActiveFloor` → increment wins/losses/peak → insert
`rating_deltas`. Komentar di kode sendiri menyatakan keduanya harus identik untuk determinisme.
Ubah satu aturan cap/pembulatan di satu tempat → drift rating senyap.
*Fix minimal:* ekstrak `applyPlayerUpdate(...)` yang dipakai kedua jalur. **Jangan** pecah
seluruh `ingest` (~480 baris) sekaligus.

**A4. ~480 baris `SessionStore.ingest` melanggar SRP**
`store/rating.go:101-582`: satu method menangani load config, tx REPEATABLE READ, advisory
lock, extract, final-gate, fingerprint/reconcile, guard placeholder, filter void/pre-season,
invariant seq, dedupe, resolve player, sort-lock, load registered_at/tier, load runtime,
loop scoring, flush `rating_players`, flush `rating_sources`.
*Fix minimal:* ekstrak per fase (A3 sudah mengangkat inti scoring terlebih dahulu).
Sisanya bisa bertahap.

### MEDIUM

**A5. Dua mekanisme idempotency paralel; satu berupa global mutable state**
`handler/session.go:32-112` (`var idempotencyMu; idempotencyStore = make(map…)`, TTL 24 jam,
cap 1000) vs `store/idempotency.go` (DB-backed). Keduanya pakai header `Idempotency-Key` yang
sama. Yang handler adalah variabel package-level — dependency tersembunyi, tak injectable,
tak lintas-proses. *Fix minimal:* bungkus di struct handler yang di-inject; dokumentasikan
layer mana pemilik dedup.

**A6. Logika domain bocor ke layer transport**
`handler/session.go:608-645` (`newShareCode`/`randomAlnum`) + `allocateSessionID`
(`session.go:256-274`) & `allocateTournamentID` (`tournament.go:260-278`) — dua allocator
hampir identik, dan tak seharusnya di handler. Validasi skor **dobel**: `handler/granular.go:108`
mengulang `*ScoreA<0||>99||==` padahal store memanggil `domain.ValidateScore`
(`store/granular.go:89`). *Fix minimal:* hapus cek di handler, andalkan `ValidateScore`;
pindahkan generator share-code ke `domain`.

**A7. `mapPublishError` default memetakan error PG tak dikenal ke HTTP 400**
`handler/session.go:150-153`: `default: httperr.Wrap(CodeValidation, "invalid session state", pgErr)`.
Karena `httperr.WriteError` hanya log `CodeInternal`/`CodeDatabase`, error server-side yang
jatuh ke cabang ini dikembalikan 400 **dan tidak pernah di-log**. *Fix minimal:* default →
`CodeDatabase`.

**A8. Prolog If-Match + idempotency disalin di tiap handler granular**
`handler/granular.go` (80-99/169-187/212-230) dan `handler/swap.go:27-45` mengulang blok parse
If-Match 3 arah + replay idempotency.
*Fix minimal:* `requireIfMatch(w,r) (*int,bool)` dan `replayIdempotent(w,r,id)`.

**A9. `tournament.Save` vs `team_tournament.TeamSave` menduplikasi seluruh skeleton publish**
`store/tournament.go:212-296` ≈ `store/team_tournament.go:214-291`: cek blank-id, validate,
`pg_try_advisory_xact_lock(hashtextextended(schema+".publish_tournament", id))`, lookup
`FOR UPDATE NOWAIT`, switch versi, upsert header.
*Fix minimal:* ekstrak `lockAndResolveTournament(...)`.

**A10. Fallback migrasi kolom menyulitkan jalur baca/tulis utama — KISS**
`store/session_read.go:176-255` melakukan re-query bersarang di dalam `rows.Next()` saat
deteksi kolom hilang (tutup cursor, query ulang, reset, rescan, `break`).
`store/session_write.go:269-515` (`syncSessionTables`, ~246 baris) menyusun SQL INSERT via
konkatenasi string `cols`/`vals`/`args` (430-467). Keduanya shim migrasi 000014 yang sudah
shipped tapi permanen. *Fix minimal:* probe schema sekali saat startup, hapus re-query
tengah loop + string-building.

**A11. Dua predikat error Postgres mirip dengan matching berbeda — DRY + jebakan presedensi**
`isSkippedColumnMissing` (`session_read.go:400-410`) vs `isUndefinedColumn`
(`granular.go:582-592`). Di `granular.go:591`:
`return strings.Contains(msg,"42703") || strings.Contains(msg,"skipped_player_refs") && strings.Contains(msg,"does not exist")`
— `&&` mengikat lebih kuat, jadi `A || (B && C)`. *Fix minimal:* satu `isUndefinedColumn` di
`session_helpers.go` + tanda kurung eksplisit.

**A12. Nama parameter OCC tidak konsisten**
`SetGameScore/Played/Skipped` pakai `expectedVersion` (row) sementara `SetAbsentPlayers:332`
& `SwapMembers:35` pakai `expectedSessionVersion`, dengan pesan error identik. Pembaca tak
tahu scope-nya. *Fix:* sertakan scope (`game`/`session`) di pesan; bereskan lewat helper A2.

**A13. Magic number `Target: 21` mengabaikan `KindRegistry.DefaultTarget`**
`store/rating_extract.go` membangun `RawMatch` dengan `Target: 21` hardcoded, padahal
`domain.KindRegistry` (`domain/rating_match.go:34-38`) menyimpan `DefaultTarget` per kind yang
justru diabaikan. *Fix minimal:* pakai `domain.KindRegistry[…].DefaultTarget`.

### LOW

- **A14.** `Metrics.Contentions` (`store/metrics.go:14,27`) dideklarasikan & diekspor ke
  `/metrics` tapi **tak pernah di-`Add`** — selalu 0, menyesatkan. Increment saat
  `ErrContention` atau hapus.
- **A15.** Doc-comment salah tempel: `rating_admin.go:17` masih fragmen `SetPlayerTier`
  di atas `logRebuildError`. Hapus 1 baris.
- **A16.** `jsonUnmarshal` (`rating_revert.go:471-473`) hanya wrapper `json.Unmarshal`. Hapus.
- **A17.** `loadSeasons` (`achievement.go:324`) mengembalikan slice yang dibuang pemanggil
  (`:186` pakai `_,`). Buang return slice.
- **A18.** `splitPairNames` (`tournament.go:446-452`): case `'v'`,`'s'` mengembalikan `false`
  (sama dengan default) — dead code menyesatkan. Sederhanakan ke `'&', ',', '/', '-'`.
- **A19.** Default gender `"M"` duplikat di `handler/player.go:159` & `store/tournament.go:511-512`.
  Satukan ke `domain.DefaultGender`.
- **A20.** `handler/player.go:146-173` `Register` mencampur dua store + memicu `RebuildAll`
  (cross-aggregate write di transport). Pindahkan orkestrasi ke service/store method.

**Yang sudah bagus (jangan diutak-atik):** `domain/` benar-benar murni & testable (DIP);
`adminGuard` tunggal & dipakai ulang; sentinel error + `%w` konsisten; `httperr`, `middleware`,
`db`, `logfile` kecil dan SRP.

---

## BAGIAN B — FRONTEND (`apps/web/src`)

### HIGH

**B1. Blok OCC/Idempotency + validasi respons disalin 7× — DRY**
`queries/endpoints.ts`: `Idempotency-Key` muncul **18×**, cek `isValidSnapshot`/throw **8×**.
Blok sama (generate key + fallback, header `If-Match`, `request`, cek snapshot, `console.warn`
+ throw) ada di `publishSession`, `patchGameScore`, `patchGamePlayed`, `patchAbsentPlayers`,
`patchGameSkipped`, `swapMembers`, `publishTournament` (212-349, 453-470).
*Fix minimal:* `makeIdempotencyKey()` + `publishWithOcc(...)` sekali di file yang sama.

**B2. Lifecycle optimistic-mutation disalin 5× padahal factory generik sudah ada — DRY**
`queries/sessions.ts` (125-161/193-222/242-271/337-363/380-403/468-492): pola
`onMutate`(cancel+snapshot+setQueryData)/`onError`(rollback+fetch saat version-mismatch)/
`onSuccess` diulang; loop retry `for(attempt<2){getGame→patch→if versionMismatch continue}`
diulang 4× (181-190/230-239/368-377/447-465). Padahal `queries/useOptimisticMutation.ts:53-135`
sudah mengimplementasikan lifecycle identik → **dua mekanisme paralel** dalam satu layer.
*Fix minimal:* helper `withGranularOptimisticLifecycle(...)` atau perluas `useOptimisticMutation`.

**B3. God-file `utils/canvasPost.ts` (1220 baris) + API posisional 15-17 arg — SRP/KISS**
6 fungsi `draw*` menulis ulang setup canvas + `save/font/fillText/restore` + sponsor/chevrons;
caller mengirim `undefined, undefined` trailing. Konstanta `ANNIVERSARY_LABEL` (`:127`)
**direplikasi sebagai literal** di `TeamGroupSchedule.tsx:89` & `TeamTournamentPage.tsx:229`
(terverifikasi).
*Fix minimal:* tiap `draw*` menerima satu options object; ekspor `ANNIVERSARY_LABEL`; pecah
file per jenis post tanpa mengubah logika.

**B4. Derived state disimpan ganda di GeneratePage — React-idiomatic**
`pages/GeneratePage.tsx:50-62`: `result` local di-init dari `storeResult`, lalu disinkronkan
"adjust during render" (`if (storeResult !== result) setResult(storeResult)`); setiap handler
menulis **dua kali** (`updateSchedule(...)` + `setResult(...)` — :87-122). `playedGames` dan
`result` pada dasarnya store yang sama dalam dua topi.
*Fix minimal:* hapus local `result`, baca `lastResult` dari store sebagai satu-satunya sumber
(`updateSchedule` sudah menjaga `lastResult` sinkron).

**B5. Data demo dipin di kode produksi — hardcoding**
`pages/TournamentPage.tsx:22-39`: `INITIAL_PAIRS` berisi 16 nama pemain nyata, dipakai sebagai
fallback `classic?.pairs ?? INITIAL_PAIRS` (`:101`); default name `'MAJADU Internal Tournament 2026'`
(`:104`) & date `'2026-05-23'` (`:125`). Snapshot gagal-load → menampilkan pasangan palsu.
*Fix minimal:* pindah ke `config/`; fallback → kosong + skeleton.

**B6. Pipeline ekspor foto tim disalin antar-file — DRY**
`TeamGroupSchedule.tsx:67-109` ≈ `TeamTournamentPage.tsx:207-270` (load 2 logo + placeholder,
loop partai → `drawMatchPost` → `canvasToBlob` → `drawTeamMatchPost`); helper nama pasangan
dobel: `TeamGroupSchedule.tsx:32-37 getPairName` vs `TeamTournamentPage.tsx:200-205
getFinalPairName` (identik).
*Fix minimal:* ekspor `buildTeamMatchFiles(...)` + satu `getPairName` dari `utils/teamTournament.ts`.

**B7. Pola "upload foto + hidden input + tombol kamera" disalin 5× — DRY**
`BracketTab.tsx:165-187,431`, `GroupMatches.tsx:164-183,237-256`,
`TeamTournamentPage.tsx:517-528`, `TeamGroupSchedule.tsx:150-169`: semua
`createObjectURL→new Image→onload revoke→setState map`. SVG kamera & download di-inline ~7×
(tersedia `Icon.tsx` 'download' yang tak dipakai).
*Fix minimal:* hook `useImageUploadMap()` + daftarkan `camera` di `Icon.tsx`.

### MEDIUM

- **B8.** Tuple reset slice diulang 12× (`sessionSlice.ts:70,89,101,119`,
  `playersSlice.ts:23,34,50,67`, `fixMatchesSlice.ts:26,47,57,61`) — `schedule:[], lastResult:null,
  playedGames:[], gameScores:{}`. → satu `RESET_GENERATED` di `store/index.ts`.
- **B9.** `BracketTab` copy-paste JSX: 3 blok header ronde (256-337) hanya beda id/label;
  8 baris `onUploadPhoto` wiring identik (342-368); podium (374-417) ≈ `StandingsTab.tsx:84-98`.
  → array round-config + `.map` + komponen `RoundHeader`.
- **B10.** `GROUP_IDS ['A','B','C','D']` dideklarasikan ulang **8×** (terverifikasi) di
  `queries/tournament.ts:13`, `GroupMatches.tsx:10`, `tournament/StandingsTab.tsx:5`,
  `TournamentPage.tsx:20`, `NewTournamentWizard.tsx:17`, `utils/tournament.ts:161`, dst.
  Match-id KO `'qf-1'…` juga hardcoded. → ekspor `GROUP_IDS` + `KO_IDS` dari `utils/tournament.ts`.
- **B11.** `courtLabel` tiga implementasi berbeda: `'A','B'` (`SummaryModal.tsx:193-194`),
  `'C1','C2'` (`ScheduleGrid.tsx:110-113`, komentarnya mengklaim "samakan dengan SummaryModal"),
  `Court 1` (`ScheduleComponents.tsx:88`, dst). → satu util `courtLabel()`.
- **B12.** `SummaryModal.tsx:369` hardcode **`whole session — 36 games`** padahal `totalGames`
  tersedia (`:196`). Terverifikasi. → `${totalGames}`.
- **B13.** `PlayersPage` bypass react-query: `listPlayers` mentah + `useEffect` + dua state
  turunan + `.catch(()=>{})` (`:6,343-357`), padahal `useListPlayers` ada & dipakai
  `AdminPlayersPage.tsx:20`. → pakai hook, derive via `useMemo`.
- **B14.** Toast error + auto-dismiss disalin 4×; pair `{onSuccess,onError}` disalin 9× di
  `SharedSessionPage.tsx:146-214` & 4× di `TournamentPage.tsx:221-249`.
  → `useAutoDismiss()` + `<ErrorBanner>`.
- **B15.** Team-tournament melanggar layer queries (DIP): `TeamTournamentPage.tsx:83-105`
  pakai `useMutation` + `publishTournament` langsung dari `endpoints` (bukan lewat
  `queries/tournament.ts`/`useOptimisticMutation`), jadi retry/rebase OCC tidak berlaku untuk
  team. Normalisasi match dobel di `:75-79` & `:96-101`. → `usePublishTeamTournament`.
- **B16.** God-hook `useSummaryEditModes` mengembalikan 40+ field; `SummaryModal.tsx:119-173`
  mendekonstruksi 44 nama lalu drill ~30 prop → `ScheduleGrid` → `PlayerChipRenderer` (18 prop).
  Tak ada `useCallback` di hook → identitas handler baru tiap render, membatalkan memo downstream.
  → kelompokkan per-mode, bungkus mutator dengan `useCallback`.
- **B17.** Memoization hilang yang berdampak: `ScheduleGrid.tsx:94-96` menghitung
  `new Set(playedGames)` + `computeBackToBackRunBySlot(...)` di **setiap render**, termasuk tiap
  keystroke input skor. → `useMemo([result.schedule, playerMap])`.
- **B18.** Panel statistik pemain duplikat: `PlayerStatsPanel.tsx:84-121` ≈
  `ScheduleComponents.tsx:187-220`. `PlayerStatsPanel` juga dua komponen via cabang boolean
  `standalone`. → ekspor satu, pakai ulang.
- **B19.** Validasi skor tiga varian: kanon `utils/scoreValidation.ts`; `useScoreDraft.ts:29`
  menulis ulang rentang 0–99; `ScoreModal.tsx:25` aturan sendiri tanpa batas atas (terverifikasi).
  → `ScoreModal` pakai `validateScore`.
- **B20.** Dead code & prop mati: `GroupMatches.tsx:99-117` JSX dikomentari 19 baris → prop
  `onResetGroups`/`onRegeneratePics`/`isRegeneratingPics` tak terpakai (padahal
  `TournamentPage.tsx:225-236` membangun mutation lengkap untuk itu);
  `utils/sessionSnapshot.ts:39-52 togglePlayedInSnapshot` **tak punya pemanggil** (terverifikasi);
  `utils/swap.ts:12-13 ChangeTarget` bertag `@deprecated` tapi masih diimpor 8 file.
- **B21.** `NewTournamentWizard` menduplikasi kontrak domain: `TEAM_CLASSES`/`TeamClass`
  (37-38) yang sudah diekspor `utils/teamTournament.ts`; literal `{A:[],B:[],C:[],D:[]}` (263,270,315)
  juga di `TournamentPage.tsx:41,80` & `queries/tournament.ts:95`; step-1 kedua wizard hampir
  identik. → impor ulang + `WizardIdentityStep`.
- **B22.** `createTournament` (`endpoints.ts:476-523`) mengimplementasikan ulang `request()`:
  loop retry, parsing body error (≈ :86-95), AbortController — semua sudah ada; alasan hanya
  akses header `Location`. → `request` opsi `returnHeaders`.

### LOW

- **B23.** `InstagramPostPage.tsx:89-189` gesture drag/pinch/rAF inline; `MONTHS` hardcoded
  (proyek punya `i18n/`); `:28` `new Date().toISOString()` pakai UTC — jebakan yang justru
  dihindari `todayWIB()` (`store/sessionSlice.ts:15-17`).
- **B24.** `SummaryModal.tsx:178-183`: `useMemo` bergantung pada default prop `absentPlayers=[]`
  (identitas baru tiap render) → seluruh rantai memo ter-defeat. → hoist `EMPTY` ke module scope.
- **B25.** Fallback tier tidak konsisten: `DEFAULT_TIER=5` vs `?? 2` (`generator/index.ts:307-308`,
  `PlayersPage.tsx`) vs pesan "Tier to D+" vs default admin `'C'`.
- **B26.** `ScoreboardPage.tsx:210-272`: empat blok `<ScoreboardSide>` untuk satu swap A/B →
  array `sides = isSwapped ? [B,A] : [A,B]`.
- **B27.** `PlayersPage.tsx:97-131 vs 213-243`: gender+tier picker JSX identik; `[1..8] as Tier[]`
  ditulis 3× → komponen `GenderToggle`/`TierToggle` + `TIERS`.
- **B28.** Campur bahasa copy UI (ID vs EN) + `alert('Gagal membuat tournament…')`
  (`NewTournamentWizard.tsx:115,305`) — pola UX beda dari toast inline.
- **B29.** Detail kecil: literal jam `'11:00'/'09:00'` berulang; cast ganda
  `as unknown as` (`queries/sessions.ts:52`); dua generator id (`ShareButton.tsx:13-15` vs
  `sessionSlice.ts:44-46`); logika fullscreen disalin (`HomePage.tsx:18-22` vs
  `ScoreboardPage.tsx:16-29`); `queries/errors.ts:4-29` deteksi error via substring pesan
  (rapuh thd perubahan teks backend); PAGE size lokal 3×.
- **B30.** `queries/endpoints.ts:383-392` `listPlayers` mendeklarasikan field camelCase
  (`playerId`,`tierInduk`) tapi mengembalikan `rows` mentah tanpa mapping (kontras
  `listSessions:351-374` yang mapping snake→camel); `queries/ratings.ts:58-66` pakai `request()`
  inline sementara query lain lewat fungsi di `endpoints.ts` — dua gaya dalam satu layer.

**Yang sudah bagus:** `scheduleSlice`/`uiSlice` bersih; `AdminContext`, `retry.ts`,
`useEscapeKey`, `SessionListPage`, `RatingPlayerPage` tidak ada temuan berarti.

---

## Rekomendasi Urutan Perbaikan

1. **A1** (bug schema — 1 baris) dan **B12** (angka 36 — 1 baris). Quick win, dampak jelas.
2. **A3** (ekstrak scoring inti) — risiko tertinggi kalau dibiarkan; perubahan terlokalisasi.
3. **B1 + B2** (queries layer) dan **A2** (granular store) — duplikasi terbesar, perbaikan mekanis.
4. **A14–A19, B20** — buang dead code/metric palsu (murni hapus, tanpa risiko).
5. Sisanya bertahap. **Jangan** kerjakan A4 (`ingest`), B3 (`canvasPost`), B16/B21 sekaligus —
   pecah per komponen/file.

Catatan: banyak item di sini sudah tercatat sebagai "out of scope" di
`AUDIT_REMEDIATION_TASKS.md` (mis. refactor `SessionStore` god-package, Prettier/plugin baru).
Audit ini **tidak** mengusulkan dependency baru.
