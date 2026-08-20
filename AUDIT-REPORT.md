# AUDIT REPORT — Auto-Lock + Admin Restructure

> **Date:** 2026-08-20
> **Scope:** Frontend (`badminton-match` commit `103e0a9`) + Backend (`majadu-api` commit `0a5e9e5`)
> **Auditor:** Automated review (reviewer agent)
> **Status:** ✅ Semua fix sudah diimplementasi (commit `Audit fixes: auto-lock, admin restructure, clean code`)

---

## TL;DR

- **4 high-severity issues** — integration tests broken, auto-locked sessions never ingested, blank `/admin` page, stale UI after auto-lock
- **5 medium-severity issues** — dead code, version inconsistency, timezone mismatch, generic lock error, TOCTOU on delete
- **6 low-severity issues** — dead hook, i18n regression, pager clamp, timer cleanup, a11y, snapshot isolation
- **1 design note** — auto-lock irreversible tanpa confirmation

---

## High Severity

### H1 — Integration tests akan fail setelah auto-lock

**Location:** `majadu-api/internal/store/session_integration_test.go`

**Problem:**
Dua integration test pakai hardcoded date `"2026-08-12"` (tanggal lampau). Setelah auto-lock ditambahkan, test ini akan fail:

1. `TestIntegrationSessionRoundTrip` — Save kedua (input skor `0-0`) trigger auto-lock karena `allScored` true + `pastDate` true. Version jadi 3 bukan 2 yang di-assert. `st.Delete` gagal dengan `ErrLocked`.

2. `TestIntegrationSessionWritePathSemantics` — "save after unlock" step tidak ada skor, tapi `pastDate` trigger auto-lock. `st.Delete` akhirnya gagal dengan `ErrLocked`.

**Impact:**
Tests hanya jalan kalau `MAJADU_TEST_DATABASE_URL` di-set (env-guarded), jadi `make check` tetap hijau. Tapi tests ini akan fail di next integration run dan secara silent mendokumentasikan bahwa "editing a past-dated session must remain possible" — semantic yang dihapus oleh kode baru.

**Fix:**
1. Update existing tests pakai future date: `time.Now().AddDate(0, 0, 1).Format("2006-01-02")`
2. Tambah dedicated integration tests untuk auto-lock:
   - (a) all-scored → locked + version bump
   - (b) past date → locked
   - (c) empty schedule + today's date → stays draft
   - (d) create with past date → stays draft (documented exemption)
   - (e) unlock after auto-lock still works

---

### H2 — Auto-locked via Save() tidak pernah di-ingest oleh ticker

**Location:** `majadu-api/cmd/server/main.go:90-102`

**Problem:**
Ticker di `main.go` hanya menjalankan `AutoIngestLockedSessions` kalau **ticker itu sendiri** yang mengunci ≥1 session di cycle itu:

```go
if n > 0 {
    ni, err := locker.AutoIngestLockedSessions(runCtx)
    // ...
}
```

`AutoIngestLockedSessions` memang memilih semua non-draft session tanpa fingerprint, tapi hanya dipanggil kalau `n > 0` (ticker mengunci ≥1 session).

Session yang di-auto-lock via `Save()` (misal: semua skor terisi di hari yang sama, tanggal belum lewat) **tidak dihitung dalam `n`**. Ticker tidak akan mengunci session ini lagi (tanggal belum lewat), jadi `n` tetap 0 dan **session itu tidak pernah di-ingest** — kecuali kebetulan ada draft lain yang expired di cycle yang sama.

**Impact:**
Rating ingest tidak jalan untuk session yang auto-locked via save. Ini use case paling umum: host input semua skor saat sesi berlangsung → session locked → rating tidak masuk.

**Fix:**
Pilihan:
- (A) Jalankan `AutoIngestLockedSessions` **unconditionally** setiap tick (idempotent, skip failures internally)
- (B) Trigger ingest langsung dari `Save()` setelah auto-lock (lebih responsif, tapi add latency ke write path)

Rekomendasi: (A) — paling simpel, zero risk.

---

### H3 — `/admin` (bare path) render blank page

**Location:** `src/App.tsx:99-105`

**Problem:**
Route definition sekarang:
```tsx
<Route path="admin">
  <Route path="sessions" element={...} />
  <Route path="players" element={...} />
  ...
</Route>
```

Tidak ada `<Route index>` atau `element` di parent. Old `/admin` URL (atau bookmarks) sekarang render **blank page** — hanya HomeLayout header, konten kosong.

React Router v7: matched route tanpa element → render `null`.

**Impact:**
Low direct impact (tidak ada code yang link ke `/admin` lagi), tapi old bookmarks/URLs silently break. User bisa bookmark `/admin` dan bingung kenapa kosong.

**Fix:**
Tambah redirect:
```tsx
<Route path="admin">
  <Route index element={<Navigate to="/admin/sessions" replace />} />
  <Route path="sessions" element={...} />
  ...
</Route>
```

---

### H4 — Auto-lock stale UI — host tidak tahu session sudah locked

**Location:** `src/pages/SharedSessionPage.tsx` + `src/queries/sessions.ts`

**Problem:**
`useGetSession` tidak punya `refetchInterval` — hanya refetch on window focus atau manual reload. Tab yang terbuka melewati auto-lock trigger (semua skor terisi / tanggal lewat) tetap menampilkan SummaryModal yang editable.

Ketika host coba save:
1. Server return `409 "session is locked"`
2. `getSaveErrorMessage` (`src/queries/errors.ts`) **tidak match** "locked" — tampilkan generic "Failed to save, please try again."
3. `onError` di `useOptimisticMutation` rollback cache ke previous snapshot (unlocked) + tidak refetch (hanya refetch on version mismatch)
4. UI tetap editable, save terus gagal sampai user manual reload

**Impact:**
- Host tidak tahu session sudah locked sampai save gagal
- Error message tidak menjelaskan masalah
- UI stuck dalam state editable yang sebenarnya sudah locked

**Fix:**
1. Tambah `refetchInterval: 30_000` (atau 60_000) ke `useGetSession` di SharedSessionPage
2. Tambah mapping di `getSaveErrorMessage`:
   ```ts
   if (message.includes('locked')) return 'Session is locked — no further edits allowed.'
   ```
3. Di `useOptimisticMutation` `onError`, refetch juga saat lock conflict (status 409 + message contains "locked")

---

## Medium Severity

### M1 — `AdminRatingsPage.runRebuild` — dead error path + double flash

**Location:** `src/pages/admin/AdminRatingsPage.tsx:20-36`

**Problem:**
`run()` dari `AdminPageShell` catch semua error internal dan tidak re-throw. Jadi:
- `catch (e) { setRebuildMsg({ kind: 'err', ... }) }` = **dead code** — failed rebuild hanya tampilkan banner atas (dari shell), bukan inline message di dekat tombol (seperti old AdminPage)
- Sukses = text muncul **dua kali**: shell `okMsg` (via `run`'s `flash(okLabel)`) DAN inline `rebuildMsg`, cleared di waktu berbeda (4d vs 5s)

Old AdminPage panggil `adminRequest(...)` langsung di `runRebuild`, kasih satu inline message untuk kedua outcome.

**Fix:**
Panggil `adminRequest('POST', '/ratings/rebuild-all')` langsung (bukan via `run`), atau ubah `run` untuk return result/rethrow.

---

### M2 — Ticker lock tidak bump version; save-path bump +2

**Location:** `majadu-api/internal/store/session.go` (auto-lock) vs `AutoLockExpiredSessions`

**Problem:**
- `AutoLockExpiredSessions` (line 652): `UPDATE sessions SET status='locked', updated_at=now()` — **tanpa version bump**
- `Save()` auto-lock: `nextVersion++` → version naik +2 dalam satu request (N → N+1 untuk save, N+1 → N+2 untuk lock)

Client yang fetch `vN`/draft lalu di-lock oleh ticker masih lihat `vN` tapi locked. Client yang di-lock via Save() lihat `vN+2`. Logical transition yang sama menghasilkan version berbeda tergantung path mana yang jalan.

**Impact:**
Tidak corrupt data (status dicek sebelum version di Save), tapi version semantics jadi ambiguous untuk consumer yang infer "version change = content change".

**Fix:**
Tambah `version = version + 1` di `AutoLockExpiredSessions`, atau document mengapa ticker path sengaja tidak bump.

---

### M3 — Timezone: save-path UTC midnight vs DB `current_date`

**Location:** `majadu-api/internal/store/session.go` auto-lock

**Problem:**
`time.Now().Truncate(24 * time.Hour)` truncates ke **UTC midnight** (Go truncates from zero time = UTC). `time.Parse("2006-01-02", ...)` juga UTC.

Save-path rule efektifnya: `session_date < current UTC date`.

Ticker pakai `session_date < current_date` (DB session timezone, biasanya `Asia/Jakarta`).

Di VPS (DB `Asia/Jakarta`, container sering UTC), save-path "today" tertinggal 7 jam dari Jakarta midnight: session dated "yesterday" di Jakarta belum di-lock save-path antara 00:00-07:00 Jakarta, tapi ticker sudah lock di 00:00.

**Impact:**
Dua path bisa disagree tentang session yang sama dalam window 7 jam. Host save di jam 6 pagi masih bisa edit session "kemarin" yang sudah di-lock oleh ticker → `ErrLocked` + frontend problem dari H4.

**Fix:**
- (A) `SELECT current_date` di tx, bandingkan dengan `snap.Session.Date`
- (B) Pakai string compare: `time.Now().Format("2006-01-02")` vs `snap.Session.Date` (pastikan server `TZ` match DB)

---

### M4 — Frontend: lock conflict (409) tampilkan generic error + UI tetap editable

**Location:** `src/queries/errors.ts` + `src/queries/useOptimisticMutation.ts`

**Problem:**
Ketika session sudah locked (oleh auto-lock di device lain, atau oleh ticker), PUT return `409 "session is locked"`.

`getSaveErrorMessage` match: `version mismatch`, `being updated by another request`, `unresolved player`, `duplicate canonical resolution` — tapi **bukan** `locked`.

User lihat: "Failed to save, please try again."

`onError` di `useOptimisticMutation`:
- Rollback cache ke previous snapshot (unlocked)
- Refetch hanya terjadi on version mismatch
- UI tetap editable, save terus gagal

**Impact:**
Auto-lock menghapus tombol lock manual dari UI. Host tidak punya UI path untuk "notice" lock. Error message tidak menjelaskan masalah.

**Fix:**
1. Tambah mapping di `getSaveErrorMessage`:
   ```ts
   if (message.includes('locked')) return 'Session is locked — no further edits allowed.'
   ```
2. Di `useOptimisticMutation` `onError`, refetch juga saat lock conflict (409 + "locked")

---

### M5 — `Delete()` tidak pakai `FOR UPDATE` — TOCTOU

**Location:** `majadu-api/internal/store/session.go Delete()`

**Problem:**
`Delete` (line 542) select row tanpa `FOR UPDATE`. Concurrent `Save` bisa pass status check sementara row sedang di-publish/locked. `DELETE` selanjutnya menunggu row lock dari `Save` lalu menghapus session yang baru saja di-save (mungkin baru auto-locked).

Auto-lock membuat status flip mid-flight lebih mungkin terjadi.

**Fix:**
Tambah `FOR UPDATE NOWAIT` ke Delete's SELECT, map `55P03` → `ErrContention` (mirror `Unlock`).

---

## Low Severity

### L1 — `useLockSession` sekarang dead code

**Location:** `src/queries/sessions.ts:216-223`

**Problem:**
Hook ini tidak punya caller setelah SharedSessionPage diupdate. Import `useOptimisticSessionMutation` juga mungkin jadi unused.

**Fix:**
Hapus `useLockSession` dan cek apakah import lain masih dipakai.

---

### L2 — Admin pages hardcode English — i18n keys orphan

**Location:** 5 admin pages baru

**Problem:**
Old AdminPage pakai `t('admin.*')` untuk semua string. 5 pages baru hardcode English literals: `'Unlock'`, `'Delete'`, `'No sessions.'`, `'Session · unlock'`, `'Player added'`, `'Tier changed + recalculated'`, `'Rebaselined — rating set to mid tier'`, `'Player deleted'`, `'Tournament deleted + ratings rebuilt'`, `'Ingested'`, `'Reverted'`, `'Finalized'`.

~15 keys di `src/i18n/en.ts` jadi orphan: `admin.unlocked`, `admin.noSessions`, `admin.playerAdded`, `admin.sessionDeleted`, `admin.sectionSession/Player/Rating/Tournament/Season`, dll.

Pages campur `t()` dan literals (misal AdminSessionsPage line 32 pakai `'Unlocked'` tapi line 39 pakai `en.admin.sessionDeleteConfirm`).

**Impact:**
Low (single language), tapi inconsistent dengan established pattern.

**Fix:**
Pakai `t('admin.*')` yang sudah ada, atau hapus keys orphan secara deliberate.

---

### L3 — `Pager` page index tidak clamp saat data shrink

**Location:** `src/components/admin/Pager.tsx` + 3 admin pages

**Problem:**
Kalau list shrink (misal: delete item terakhir di page terakhir), slice kosong tapi Pager tampilkan "4 / 3" dan data ada di page sebelumnya.

**Fix:**
Clamp `page` di Pager: `page = Math.min(page, pages - 1)`, atau tambah `useEffect` yang reset ke 0.

---

### L4 — `AdminPageShell.flash` setTimeout tidak cleanup

**Location:** `src/components/admin/AdminPageShell.tsx:31-35`

**Problem:**
`setTimeout(..., 4000)` tidak pernah di-clear. Dua action dalam 4 detik: timer pertama clear message action kedua lebih awal. Saat unmount, `setState` dipanggil setelah unmount.

Sama dengan flaw di old AdminPage, tapi sekarang dipakai di 5 pages.

**Fix:**
Simpan timer id di ref, `clearTimeout` di `useEffect` cleanup / on next flash.

---

### L5 — `AdminLoginModal` — empty submit silently no-op + missing a11y

**Location:** `src/components/AdminLoginModal.tsx`

**Problem:**
- Submit dengan field kosong → `login('')` return false, tidak ada feedback
- Token non-empty diterima locally; wrong password baru terlihat sebagai 401 di admin pages (pre-existing AdminContext semantics)
- Missing `role="dialog"`, `aria-modal`, Escape-to-close (sibling modals punya ini)

**Fix:**
Tambah minimal error state ("enter the admin password"), dan align a11y attributes dengan existing modals.

---

### L6 — `Load()` multi-query tanpa snapshot isolation

**Location:** `majadu-api/internal/store/session.go Load()`

**Problem:**
Setiap tabel di-fetch dalam autocommit query terpisah (lines 100-254). Concurrent `Save` (delete + re-insert semua child tables) antara query bisa yield mixed snapshot (misal: new `session_players`, old `scheduled_games`).

Karena `Save()` return `s.Load(...)` setelah commit, concurrent writer bisa menyebabkan response internal inconsistency.

**Impact:**
Pre-existing, tapi auto-lock's extra UPDATE memperlebar write window sedikit.

**Fix:**
Jalankan seluruh read dalam satu read-only transaction (`pool.BeginTx` with `REPEATABLE READ`), atau satu CTE query.

---

## Design Note — Auto-lock irreversible tanpa confirmation

> Auto-lock when all scores entered **irreversible** tanpa admin token. Kalau host salah input skor terakhir, session langsung locked. Tidak ada prominent UI yang bilang "sessionmu sekarang locked — verifikasi skor sebelum input yang terakhir."
>
> **Pertimbangan:**
> - Confirmation dialog saat skor terakhir diinput
> - Grace period (misal: 5 menit) sebelum all-scored lock berlaku
> - Tampilkan warning "this will lock the session" sebelum score terakhir disubmit

---

## Execution Order (Rekomendasi)

```
Phase 1 — Critical fixes (data integrity + UX)
  H1: Update integration tests + tambah auto-lock tests
  H2: Jalankan AutoIngestLockedSessions unconditionally
  H4: Tambah refetchInterval + locked error mapping

Phase 2 — Consistency + safety
  H3: Redirect /admin → /admin/sessions
  M1: Fix AdminRatingsPage.runRebuild
  M2: Bump version di ticker
  M3: Fix timezone compare
  M4: Map locked error di frontend
  M5: Tambah FOR UPDATE ke Delete

Phase 3 — Cleanup
  L1: Hapus useLockSession dead code
  L2: i18n consistency
  L3: Pager clamp
  L4: Timer cleanup
  L5: AdminLoginModal a11y
  L6: Load() snapshot isolation
```
