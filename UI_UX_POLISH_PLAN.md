# UI_UX_POLISH_PLAN.md — Home Admin Trigger + English + Player History Merge + Mobile Audit

**Status:** PLAN — belum diimplementasikan
**Tanggal:** 2026-08-19
**Tujuan:** menyelesaikan 4 isu UX dari user: (1) bahasa Inggris, (2) restrukturisasi
admin (trigger di home + menu card + perbaikan halaman admin), (3) Player History
diserap ke Ratings, (4) audit mobile (text/label desekan).
**Keputusan final user (2026-08-19):** admin menu grid di home **TIDAK collapsible**
(langsung terlihat saat login) · Admin Area card = switch/logout.

---

## 1. Ringkasan Keputusan

| # | Keputusan | Nilai |
|---|---|---|
| 1.1 | Bahasa | English untuk SEMUA string user-facing. Skeleton i18n: **opsional** (lihat §2, keputusan terbuka A/B) |
| 1.2 | Admin Area card | = trigger/switch: belum login → popup password · sudah login → styling amber + tombol **Logout** |
| 1.3 | Section ADMIN di home | Muncul PERMANEN di bawah section APP kalau `isAdmin` (tanpa collapse). Isi = **grid card menu admin** → `/admin?section=X` |
| 1.4 | Halaman `/admin` | Tetap ada (operasi sesungguhnya). Section diurut ulang + autofocus via `?section=` + perbaikan mobile |
| 1.5 | Player History | Menu & halaman terpisah DIHAPUS — diserap ke `/ratings/:playerId` (section CAREER) |
| 1.6 | Collapsible | TIDAK dipakai di mana pun (home maupun /admin) — halaman admin cukup diurutkan + dipaginasi |

---

## 2. Isu 1 — Bahasa Inggris (dengan opsi i18n)

### Kondisi
UI mayoritas sudah English. String Indonesia yang perlu diganti:
- **AdminPage** (terbanyak): "Tier diubah + recalculate" · "Nama diubah (alias lama disimpan)" ·
  "Player ditambahkan" · "Nama wajib diisi" · "Hapus sesi/tournament/player …" ·
  "Rebaseline rating … (efektif sampai rebuild berikutnya)" · "Season ditutup & musim baru dimulai" ·
  "Tanggal mulai season baru" · "Default = tanggal mulai season aktif. Menutup = arsip …" ·
  "Rebuild done — semua rating dihitung ulang" · "Rebuilding…" · "Rebuild All = hitung ulang …" ·
  label section ("Session · unlock", "Rating · ingest / revert", "Tournament · delete", dst.)
- **TeamTournamentPage**: "saving…" · "Gagal menyimpan." · "Gagal menghapus."
- **Empty states lain** (grep ulang saat eksekusi): "No sessions.", "No sources.", dst.

### Opsi implementasi
| Opsi | Deskripsi | Kelebihan | Kekurangan |
|---|---|---|---|
| **A. Skeleton i18n ringan** | `src/i18n/en.ts` (typed dict) + `t()` + `useT()` — zero deps (~60 baris) | Semua string satu tempat; siap multi-bahasa nanti | Churn lebih besar (semua pemakaian lewat hook) |
| **B. Inline English** (rekomendasi) | Ganti string → English langsung di tempat | Minimal, cepat, tidak ada indirection | Kalau nanti mau i18n, sweep ulang |

**Rekomendasi: B** — aplikasi single-language, cost-conscious. Skeleton A bisa ditambah
belakangan kalau kebutuhan multi-bahasa nyata muncul. ⚠️ **KEPUTUSAN TERBUKA: konfirmasi A/B.**

---

## 3. Isu 2 — Restrukturisasi Admin

### 3.1 Home Page — trigger & section ADMIN

```
HOME PAGE (sebelum login)
  APP: [Sessions][Ratings][Scoreboard][Tournament][IG Post][Admin Area]
        (Admin Area = icon gembok, style normal, klik → popup password)

HOME PAGE (setelah login)
  APP: [Sessions][Ratings][Scoreboard][Tournament][IG Post][Admin ▸]
        (Admin = border amber + badge "admin", klik → LOGOUT)

  ADMIN  ← label section amber, selalu terlihat (tanpa collapse)
    [Unlock Session] [Players] [Ratings] [Tournament] [Season]
    (grid card menu admin, style amber pembeda, klik → /admin?section=X)
```

Perilaku:
- **Belum login**: klik "Admin Area" → popup password (existing) → sukses → section ADMIN
  muncul otomatis (tidak navigate ke /admin lagi).
- **Sudah login**: card Admin jadi Logout (konfirmasi? — langsung logout saja, konsisten
  dengan kebiasaan sekarang). Section ADMIN hilang.
- Card menu admin: icon + label + deskripsi singkat, gaya card APP tapi aksen amber.

### 3.2 Card menu admin → `/admin?section=X`

| Card | `?section=` | Fungsi di AdminPage |
|---|---|---|
| Unlock Session | `sessions` | list sesi + unlock/delete |
| Players | `players` | add/rename/tier/rebaseline/delete player |
| Ratings | `ratings` | ingest/revert/finalize + Rebuild All |
| Tournament | `tournament` | list tournament + delete |
| Season | `season` | close & start + arsip |

AdminPage membaca `useSearchParams` → scroll ke section terkait (`ref`/`scrollIntoView`) —
section TIDAK perlu collapsible, cukup fokus scroll.

### 3.3 AdminPage — urutan section (best UX)

Baru: Session → Player → Rating → Tournament → Season.
Alasan: frekuensi operasi (unlock/edit sesi = harian) → dampak (season = jarang & besar).

### 3.4 AdminPage — perbaikan mobile

1. **Season info terpotong** → baris meta jadi 2 baris + `flex-wrap` (hapus `truncate`):
   ```
   Season 2026-1          [● active]
   2026-05-23 → active · 88 days     ← wrap bebas
   ```
2. **Player section scroll panjang** (2.089 pemain di DB!) → **pagination** (PAGE 10,
   pakai `Pager` existing) + **filter search nama** (local, wajib — 209 halaman tanpa
   search tidak berguna).
3. **Baris aksi penuh tombol** (unlock+delete / ingest+revert+finalize / tier+rename+
   rebaseline+delete) → `flex-wrap` pada baris + gap konsisten; tombol `text-[10px]`
   sudah ok di layar sempit.

---

## 4. Isu 3 — Player History diserap ke Ratings

### 4.1 Navigasi baru

```
SEBELUM:
  [Player History] menu → /player-history → /player-history/:name ⇄ /ratings/:playerId
  (cross-link bolak-balik = nested navigation)

SESUDAH:
  [Ratings] → /ratings (leaderboard) → klik player → /ratings/:playerId
    ├─ header (nama + badge tier + rating)
    ├─ stat cards (Rating · Peak · Games · Tier)
    ├─ sparkline rating
    ├─ Recent matches (history rating)
    └─ CAREER  ← konten PlayerDetailPage lama dipindah ke sini
       (W/L, points for/against, top partners, top opponents, daftar sesi)
```

- **Tanpa cross-link** "View player history ⇄ View rating" — sudah satu halaman.
- **Tanpa perubahan backend**: `/ratings/:playerId` sudah punya `name` →
  `getPlayerStats(name)` (resolve via alias) untuk data career.
- **Seragam design**: reuse pola kartu & tipografi RatingPlayerPage (1 set token,
  ukuran font konsisten).

### 4.2 Route lama

| Route | Aksi |
|---|---|
| `/player-history` | Redirect → `/ratings` |
| `/player-history/:name` | Resolver kecil: `getPlayerStats(name)` → dapat `playerId` → Navigate `/ratings/:playerId` (404/empty → /ratings) |
| Menu "Player History" di grid home | Dihapus (grid jadi 6 card: Sessions, Ratings, Scoreboard, Tournament, IG Post, Admin) |

⚠️ **KEPUTUSAN TERBUKA**: redirect dengan resolver (aman untuk bookmark lama) vs hapus
route langsung. Rekomendasi: resolver redirect.

---

## 5. Isu 4 — Audit Mobile (text/label desekan)

### Hotspot yang sudah teridentifikasi
| Area | Masalah | Fix |
|---|---|---|
| AdminPage baris aksi | 3-5 tombol inline per baris | `flex-wrap` + gap konsisten |
| Standings / leaderboard | kolom sempit | `tabular-nums`, gap lebih kecil, label `text-[10px]` seragam |
| Season meta | truncate | 2 baris + wrap (§3.4.1) |
| SummaryModal / PlayerMatchDetailSheet | belum diaudit | audit menyusul |

### Prosedur audit
1. Grep semua baris `flex` dengan >1 elemen inline + `truncate` di `src/pages` & `src/components`.
2. Normalisasi: `gap-*` konsisten, `min-w-0` di parent flex, `flex-wrap` untuk tombol,
   `tabular-nums` untuk angka.
3. Fokus: AdminPage · StandingsTab · Leaderboard · TeamTournament · Scoreboard ·
   PlayerMatchDetailSheet · SessionListPage.

---

## 6. Task List (fase eksekusi)

### Fase A — English sweep
- [ ] A1. Keputusan i18n: A (skeleton) / B (inline) — konfirmasi user
- [ ] A2. Sweep string Indonesia di `AdminPage` → English (daftar §2)
- [ ] A3. Sweep `TeamTournamentPage` ("saving…", "Gagal menyimpan.", "Gagal menghapus.")
- [ ] A4. Grep `[^\x00-\x7F]` di `src/` (non-ASCII di string user-facing) → bersihkan
- [ ] A5. `npm run check` hijau

### Fase B — Home trigger & section ADMIN
- [ ] B1. HomePage: card Admin jadi switcher (login popup / logout, styling amber + badge)
- [ ] B2. Komponen baru `AdminMenuGrid` (5 card → `/admin?section=X`) — render kalau `isAdmin`, tanpa collapse
- [ ] B3. Section label "Admin" (amber) di bawah "App" grid
- [ ] B4. Login sukses → tidak navigate ke /admin lagi (section muncul di home)
- [ ] B5. `npm run check` + verifikasi manual di browser (login → logout → styling)

### Fase C — AdminPage improvements
- [ ] C1. Urut ulang section: Session → Player → Rating → Tournament → Season
- [ ] C2. Autofocus `?section=X` (useSearchParams + scrollIntoView; tanpa collapsible)
- [ ] C3. Season meta 2 baris + wrap
- [ ] C4. Player: pagination (PAGE 10) + filter search nama
- [ ] C5. Baris aksi `flex-wrap` + gap konsisten (mobile)
- [ ] C6. `npm run check` + verifikasi mobile viewport

### Fase D — Player History → Ratings
- [ ] D1. Hapus card "Player History" dari grid home
- [ ] D2. `/ratings/:playerId`: tambah section CAREER (W/L, poin, top partners/opponents, sesi) dari `getPlayerStats(name)` — reuse desain rating (font seragam)
- [ ] D3. Hapus cross-link "View player history ⇄ View rating"
- [ ] D4. Route `/player-history` → redirect `/ratings`
- [ ] D5. Route `/player-history/:name` → resolver redirect ke `/ratings/:playerId` (atau hapus — konfirmasi)
- [ ] D6. `PlayerHistoryPage`/`PlayerDetailPage` dihapus dari App.tsx (atau jadi komponen career)
- [ ] D7. `npm run check` + verifikasi navigasi (leaderboard → detail → career)

### Fase E — Mobile audit
- [ ] E1. Grep hotspot flex/truncate → daftar normalisasi
- [ ] E2. Fix per area (AdminPage, standings, leaderboard, team, scoreboard, sheets)
- [ ] E3. `npm run check` + audit akhir (semua rute, viewport 375px)

### Fase F — Verifikasi & docs
- [ ] F1. `npm run check` + `npm run build` hijau
- [ ] F2. Update `current-status.md` + doc ini (status)
- [ ] F3. Visual pass browser (user) untuk isu 2/3/4
- [ ] F4. Commit (tanpa push, kecuali diminta)

---

## 7. Checklist Akseptasi

- [ ] Semua string user-facing = English (tidak ada non-ASCII di UI)
- [ ] Home: login admin → section ADMIN (5 card) muncul di bawah APP; card Admin jadi Logout
- [ ] Klik card admin → /admin terbuka di section yang tepat (scroll)
- [ ] /admin: urutan baru · season tidak terpotong · player terpaginasi + search · tombol rapi di mobile
- [ ] Tidak ada lagi menu/rute Player History terpisah; career ada di `/ratings/:playerId`
- [ ] Tidak ada cross-link nested "lihat rating ⇄ lihat history"
- [ ] Audit mobile: tidak ada text desekan di rute utama (375px)

---

## 8. Di Luar Scope

- Language switcher / multi-bahasa aktual (cukup English)
- Perubahan backend (semua bisa tanpa backend — kecuali redirect resolver yang
  memakai endpoint existing)
- Visual rebranding (tidak termasuk)
