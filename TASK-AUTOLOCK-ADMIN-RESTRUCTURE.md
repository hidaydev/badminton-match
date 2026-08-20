# Task: Auto-Lock + Admin Restructure

> **Created:** 2026-08-20
> **Status:** DRAFT — menunggu approval sebelum eksekusi
> **Scope:** 3 perubahan besar — auto-lock, admin icon di header, admin split jadi 5 pages

---

## Context

### Poin 1: Auto-Lock
Tombol "Lock session" di SummaryModal (SharedSessionPage) dihapus. Server auto-lock
saat semua skor terisi ATAU tanggal lewat. Host tidak perlu ingat untuk lock manual.

**Penting:** Checkbox "mark as played" (✓) = tanda match sedang/main, BUKAN selesai
dengan skor. Auto-lock trigger = semua `gameScores` terisi, bukan semua `playedGames`.

### Poin 2: Admin Icon di Header
Admin card dihapus dari grid utama homepage. Login/logout pindah ke icon di header
(sebelah tombol refresh). Admin-only menus (AdminMenuGrid) tetap di homepage,
muncul hanya saat admin sudah login.

### Poin 3: Admin Standalone
AdminPage monolith (5 section dalam 1 halaman) di-split jadi 5 pages terpisah.
Tidak ada `/admin` dashboard — homepage langsung tampilkan 5 card admin saat login.

---

## 1. Auto-Lock

### 1.1 Frontend: Hapus tombol lock dari ActionsMenu

**File:** `src/components/summary/ActionsMenu.tsx`

- Hapus prop `onLockSession` dari interface `ActionsMenuProps`
- Hapus prop `hasLock` dari interface `ActionsMenuProps`
- Hapus button "🔒 Lock session" (lines 115-123)
- Hapus `onLockSession` dari destructured props

### 1.2 Frontend: Hapus lock logic dari SummaryModal

**File:** `src/components/SummaryModal.tsx`

- Hapus prop `onLock` dari `SummaryModalEditProps`
- Hapus prop `lockLoading` dari `SummaryModalEditProps`
- Hapus `lockConfirm` state (`useState(false)`)
- Hapus `onLock` dan `lockLoading` dari destructured props
- Hapus `onLockSession` callback di ActionsMenu usage (line 441)
- Hapus `hasLock` prop di ActionsMenu usage (line 448)
- Hapus lock confirmation bar (lines 483-500)
- Hapus `lockConfirm` dari condition close button (line 502)
- **Pertahankan:** badge "🔒 Locked" (lines 417-420) — ini indikator status, bukan action
- **Pertahankan:** condition `!locked` di actions visibility (line 422) — actions tetap hilang saat locked

### 1.3 Frontend: Hapus useLockSession dari SharedSessionPage

**File:** `src/pages/SharedSessionPage.tsx`

- Hapus import `useLockSession` (line 13)
- Hapus `const { mutate: lockSession, isPending: lockPending } = useLockSession(sessionId!)` (line 47)
- Hapus prop `onLock` (lines 206-209)
- Hapus prop `lockLoading` (line 210)

### 1.4 Frontend: Pertahankan badge Locked di SummaryModal

**File:** `src/components/SummaryModal.tsx`

- Lines 417-420: badge "🔒 Locked" tetap ada — ini indikator status, bukan action
- Tidak perlu perubahan di bagian ini

### 1.5 Backend: Tambah auto-lock di store/session.go

**File:** `src/../../majadu-api/internal/store/session.go` (repo `majadu-api`)

Di dalam fungsi `Save()`, setelah `syncSessionTables` dan sebelum `tx.Commit()`:

```go
// Auto-lock: semua skor terisi ATAU tanggal lewat
if currentStatus == "draft" {
    allScored := len(snap.PlayedGames) > 0 && countScoredGames(snap) == len(snap.Schedule)
    pastDate := false
    if d, err := time.Parse("2006-01-02", snap.Session.Date); err == nil {
        pastDate = d.Before(time.Now().Truncate(24 * time.Hour))
    }
    if allScored || pastDate {
        if _, err := tx.Exec(ctx, `
            UPDATE sessions SET status = 'locked', version = $2, updated_at = now()
            WHERE id = $1::uuid`, rowID, nextVersion+1); err != nil {
            return nil, err
        }
        nextVersion++
        status = "locked"
    }
}
```

Helper function `countScoredGames`:
```go
func countScoredGames(snap *domain.CloudSnapshot) int {
    count := 0
    for _, g := range snap.Schedule {
        key := domain.GameKey(g.Slot, g.Court)
        if _, ok := snap.GameScores[key]; ok {
            count++
        }
    }
    return count
}
```

**Note:** `currentStatus` sudah tersedia dari `SELECT ... FOR UPDATE NOWAIT` di awal Save().
`nextVersion` juga sudah ada. Tidak perlu query tambahan.

### 1.6 Verifikasi

- [ ] Buat session, publish, input semua skor → `GET /sessions/{id}` return `locked: true`
- [ ] Buat session, publish, tidak input skor → tidak locked (draft tetap)
- [ ] Buat session dengan tanggal kemarin → auto-lock saat publish
- [ ] Badge "🔒 Locked" muncul di SummaryModal setelah auto-lock
- [ ] Actions menu (swap, score, absent) hilang saat locked
- [ ] Admin masih bisa unlock via `/admin/sessions`

---

## 2. Admin Icon di Header

### 2.1 Tambah admin icon di HomeLayout

**File:** `src/components/HomeLayout.tsx`

- Import `useAdmin` dari `../context/AdminContext`
- Tambah state `adminLoginOpen` untuk modal login
- Tambah admin icon button di header, sebelah kiri refresh button:

```tsx
{/* Admin icon — sebelah refresh */}
{isAdmin !== undefined && (
  <button
    onClick={() => isAdmin ? handleAdminLogout() : setAdminLoginOpen(true)}
    className={`p-1.5 rounded-lg transition-all ${
      isAdmin
        ? 'text-amber-400 hover:text-amber-300 bg-amber-900/30'
        : 'text-fg-dim hover:text-fg'
    } active:scale-90`}
    aria-label={isAdmin ? 'Admin (logged in)' : 'Admin login'}
  >
    {/* Shield/checkmark icon — berbeda tergantung login status */}
    {isAdmin ? (
      <svg>/* admin logged-in icon */</svg>
    ) : (
      <svg>/* admin default icon */</svg>
    )}
  </button>
)}
```

- Tambah login modal (pindah dari HomePage, atau extracted component)

**Pertimbangan:**
- HomeLayout wrap semua route under HomeLayout — admin icon muncul di semua halaman
- Ini OKE — admin icon di header = konsisten, bisa login/logout dari mana saja
- Login modal tetap perlu karena tidak ada `/admin` landing page

### 2.2 Extract login modal ke component

**File baru:** `src/components/AdminLoginModal.tsx`

Extract login modal dari `HomePage.tsx` ke component terpisah:
- Props: `open: boolean`, `onClose: () => void`
- Baca `login` dari `useAdmin()`
- State: `adminTokenInput`
- Form submit → `login(adminTokenInput)` → `onClose()`

### 2.3 Update HomeLayout

**File:** `src/components/HomeLayout.tsx`

- Import `AdminLoginModal`
- Render `AdminLoginModal` di bawah header (fixed overlay)
- Admin icon button di header triggers modal atau logout

### 2.4 Hapus admin card dari HomePage

**File:** `src/pages/HomePage.tsx`

- Hapus `{ icon: 'admin', label: 'Admin Area', ... }` dari array `secondary` (line 17)
- Hapus `handleAdminCard` function (lines 54-61)
- Hapus `adminLoginOpen`, `adminTokenInput` state
- Hapus `handleLogin` function
- Hapus admin login modal JSX (lines 166-197)
- Hapus admin-related styling di card rendering (lines 116-134)
- **Pertahankan:** AdminMenuGrid section (lines 155-163) — tetap muncul saat isAdmin

### 2.5 Update AdminMenuGrid links

**File:** `src/components/admin/AdminMenuGrid.tsx`

- Update `section` field jadi full path:
  ```ts
  const ITEMS = [
    { icon: 'unlock', label: 'Unlock Session', desc: '...', to: '/admin/sessions' },
    { icon: 'players', label: 'Players', desc: '...', to: '/admin/players' },
    { icon: 'ratings', label: 'Ratings', desc: '...', to: '/admin/ratings' },
    { icon: 'tournament', label: 'Tournament', desc: '...', to: '/admin/tournaments' },
    { icon: 'season', label: 'Season', desc: '...', to: '/admin/seasons' },
  ]
  ```
- Update onClick: `navigate(it.to)` (bukan `navigate('/admin?section=...')`)

### 2.6 Verifikasi

- [ ] Header tampilkan admin icon (default style)
- [ ] Tap admin icon → login modal muncul
- [ ] Login berhasil → icon berubah amber, AdminMenuGrid muncul di homepage
- [ ] Tap admin icon (sudah login) → confirm logout → icon kembali default, AdminMenuGrid hilang
- [ ] AdminMenuGrid card navigate ke `/admin/*` pages
- [ ] Admin icon muncul di semua halaman (home, sessions, ratings, dll)

---

## 3. Admin Standalone — 5 Pages

### 3.1 Extract shared components

**File baru:** `src/components/admin/ActionButton.tsx`

Extract `ActionButton` dari `AdminPage.tsx`:
```tsx
interface ActionButtonProps {
  onClick: () => void
  children: React.ReactNode
  tone?: 'neutral' | 'amber' | 'red' | 'green'
  disabled?: boolean
}
```

**File baru:** `src/components/admin/Pager.tsx`

Extract `Pager` dari `AdminPage.tsx`:
```tsx
interface PagerProps {
  page: number
  total: number
  onPage: (p: number) => void
}
```

**File baru:** `src/components/admin/AdminPageShell.tsx`

Shared layout untuk semua admin pages:
- Banner "Admin" dengan logout button (dari AdminPage lines 169-175)
- Flash messages (error/success) — dari AdminPage
- `run()` helper function — dari AdminPage
- Auth guard (`if (!isAdmin) return ...`)

```tsx
interface AdminPageShellProps {
  children: (ctx: {
    run: (fn: () => Promise<unknown>, okLabel: string, refresh?: () => void) => Promise<void>
    error: string | null
    okMsg: string | null
  }) => React.ReactNode
}
```

### 3.2 Buat AdminSessionsPage

**File baru:** `src/pages/admin/AdminSessionsPage.tsx`

Logic dari `AdminPage.tsx` section "Session" (lines 180-213):
- `useListSessions()` + pagination
- Per session: title, date, status (locked/draft), unlock button, delete button
- `adminRequest('POST', '/sessions/{id}/unlock')`
- `adminRequest('POST', '/sessions/{id}/delete')`

### 3.3 Buat AdminPlayersPage

**File baru:** `src/pages/admin/AdminPlayersPage.tsx`

Logic dari `AdminPage.tsx` section "Player" (lines 215-295):
- `useListPlayers()` + pagination + search/filter
- Add player form (name + tier)
- Per player: name, tier badge, tier change, rename, rebaseline, delete
- `adminRequest('POST', '/players')`
- `adminRequest('PATCH', '/players/{id}/tier')`
- `adminRequest('PATCH', '/players/{id}/name')`
- `adminRequest('POST', '/ratings/players/{id}/rebaseline')`
- `adminRequest('DELETE', '/players/{id}')`

### 3.4 Buat AdminRatingsPage

**File baru:** `src/pages/admin/AdminRatingsPage.tsx`

Logic dari `AdminPage.tsx` section "Rating" (lines 297-339):
- `useRatingSources()` + pagination
- Per source: source_id, event_count, finalize toggle, ingest, revert
- Rebuild All button + feedback
- `adminRequest('POST', '/ratings/sources/{id}/finalize')`
- `adminRequest('POST', '/ratings/ingest-session')`
- `adminRequest('POST', '/ratings/revert-session')`
- `adminRequest('POST', '/ratings/rebuild-all')`

### 3.5 Buat AdminTournamentsPage

**File baru:** `src/pages/admin/AdminTournamentsPage.tsx`

Logic dari `AdminPage.tsx` section "Tournament" (lines 341-368):
- `useListTournaments()`
- Per tournament: name, date, format badge, delete button
- `adminRequest('POST', '/tournaments/{id}/delete')`

### 3.6 Buat AdminSeasonsPage

**File baru:** `src/pages/admin/AdminSeasonsPage.tsx`

Logic dari `AdminPage.tsx` section "Season" (lines 370-411):
- `useRatingSeasons()`
- Date picker + "Close & Start New" button
- Season list: name, status (active/closed), date range, days count, standings link
- `adminRequest('POST', '/ratings/season')`

### 3.7 Update App.tsx routes

**File:** `src/App.tsx`

Ganti:
```tsx
<Route path="admin" element={<Suspense fallback={<Loading />}><AdminPage /></Suspense>} />
```

Jadi:
```tsx
<Route path="admin">
  <Route path="sessions" element={<Suspense fallback={<Loading />}><AdminSessionsPage /></Suspense>} />
  <Route path="players" element={<Suspense fallback={<Loading />}><AdminPlayersPage /></Suspense>} />
  <Route path="ratings" element={<Suspense fallback={<Loading />}><AdminRatingsPage /></Suspense>} />
  <Route path="tournaments" element={<Suspense fallback={<Loading />}><AdminTournamentsPage /></Suspense>} />
  <Route path="seasons" element={<Suspense fallback={<Loading />}><AdminSeasonsPage /></Suspense>} />
</Route>
```

### 3.8 Hapus AdminPage.tsx

**File:** `src/pages/AdminPage.tsx`

- Hapus file ini setelah semua logic dipindah ke 5 pages baru
- Pastikan tidak ada import lain yang refer ke `AdminPage`

### 3.9 Update i18n

**File:** `src/i18n/en.ts`

- Tambah keys untuk admin page titles jika perlu
- Pastikan semua string yang dipakai di admin pages sudah ada di dictionary

### 3.10 Verifikasi

- [ ] `/admin/sessions` — list sessions, unlock, delete berfungsi
- [ ] `/admin/players` — add, search, rename, tier, rebaseline, delete berfungsi
- [ ] `/admin/ratings` — sources list, finalize, ingest, revert, rebuild berfungsi
- [ ] `/admin/tournaments` — list, delete berfungsi
- [ ] `/admin/seasons` — date picker, close & start, season list berfungsi
- [ ] Back button di header → navigate(-1) berfungsi di semua admin pages
- [ ] Lazy loading per page (tidak render semua sekaligus)

---

## 4. Final Verification

- [ ] `npm run check` — types + lint + tailwind + regression tests PASS
- [ ] `npm run build` — production build berhasil
- [ ] Manual test: buat session → publish → input semua skor → auto-lock trigger
- [ ] Manual test: login admin via header icon → AdminMenuGrid muncul
- [ ] Manual test: tap card admin → navigate ke `/admin/*` pages
- [ ] Manual test: logout admin → AdminMenuGrid hilang, icon kembali default

---

## Execution Order

```
Phase 1 — Admin split (paling banyak code change, foundation untuk phase 2)
  3.1 → 3.2 → 3.3 → 3.4 → 3.5 → 3.6 → 3.7 → 3.8 → 3.9

Phase 2 — Admin icon di header (depend ke admin pages sudah ada)
  2.2 → 2.3 → 2.1 → 2.4 → 2.5

Phase 3 — Auto-lock (depend ke admin unlock sudah available di /admin/sessions)
  1.1 → 1.2 → 1.3 → 1.4 → 1.5

Phase 4 — Verification
  1.6 → 2.6 → 3.10 → 4
```

**Note:** Backend auto-lock (1.5) di repo `majadu-api` — di-push terpisah dari frontend changes.
