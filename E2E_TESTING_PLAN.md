# E2E_TESTING_PLAN.md — Rencana Tes End-to-End (Frontend + Backend + DB)

**Status:** PLAN — belum dieksekusi
**Tanggal:** 2026-08-19
**Tujuan:** sweep komprehensif untuk memverifikasi SEMUA fungsi/tombol/alur di
frontend & backend — menemukan bug (bukan sekadar "jalan"). Laporan per area,
bug → fix → re-test (loop).
**Lingkungan target:** `dev` (backend `api.qouver.com/majadu-dev` · frontend Vercel
`dev` · DB `bm_dev`). Prod tidak disentuh.
**Terkait:** `TIER_8_UNIFICATION.md` (8-tier baru — prioritas tes) ·
`ADMIN_MENU_PLAN.md` · `RATING_ENGINE_DESIGN.md`

---

## 1. Prinsip & Batas

| Aspek | Keterangan |
|---|---|
| **Bisa dites otomatis** | Backend API matrix · Go integration tests (live) · DB parity/consistency · Frontend logic (60 regression) + build · Browser E2E via Playwright (jika tersedia) |
| **Butuh manusia** | Visual/UX judgment (layout, warna, feel) · PWA install di iOS/Android asli · offline behavior · migrasi prod |
| **Data safety** | Data uji memakai pola `it-*` (di-skip backfill/auto-ingest) + tanggal FUTURE (hindari auto-lock ticker) + **cleanup wajib** setelah tes (delete + revert). Data live (381 events/98 pemain) tidak boleh berubah |
| **Kriteria "PASS"** | Endpoint mengembalikan status & shape benar; alur end-to-end konsisten; tidak ada hantu data; auth bekerja; contract error sesuai yang dibaca frontend |

---

## 2. Prasyarat

1. Backend dev live (commit terbaru) — `curl https://api.qouver.com/majadu-dev/version`
2. Admin token (dari VPS env file — tidak di-commit)
3. SSH tunnel ke Postgres (`ssh -L 15432:127.0.0.1:5432 sachiel@43.133.148.191`) untuk
   verifikasi DB + integration tests
4. Frontend: URL deploy Vercel dev (dari dashboard user) ATAU local dev server
   (`VITE_API_URL=https://api.qouver.com/majadu-dev npm run dev`)
5. Playwright: cek `npx playwright --version`; kalau browser belum ada →
   `npx playwright install chromium` (sekali, ~300MB)

---

## 3. Area Tes Backend (API Matrix)

### 3.1 Health & infra
| Endpoint | Positif | Negatif |
|---|---|---|
| `GET /healthz` | 200 ok | — |
| `GET /readyz` | 200 (DB ping) | — |
| `GET /version` | 200, commit == HEAD | — |
| CORS preflight OPTIONS | `Access-Control-Allow-Headers` memuat `Authorization` | — |

### 3.2 Sessions
| Endpoint | Positif | Negatif |
|---|---|---|
| `POST /sessions` | 201 + Location | body invalid → 400 |
| `GET /sessions` | array metadata | — |
| `GET /sessions/{id}` | snapshot valid | id fiktif → 404 |
| `PUT /sessions/{id}` | 200, version naik | tanpa If-Match → 412; version stale → 409 |
| `PATCH /sessions/{id}` | 200 | — |
| `POST /sessions/{id}/lock` | 200 locked | — |
| `POST /sessions/{id}/unlock` | admin: 200; tanpa token → 401 | id fiktif → 404 |
| `POST /sessions/{id}/delete` | admin: 200 + rating source terhapus + rebuild | tanpa token 401; id fiktif 404 |
| `DELETE /sessions/{id}` (anon) | draft → 204 | locked → 409 |

### 3.3 Players
| Endpoint | Positif | Negatif |
|---|---|---|
| `GET /players` | array (placeholder di-filter) | — |
| `POST /players` | playerId baru / existing (idempotent) | nama blank → 400 |
| `POST /players` + tier | tier 8-tier tersimpan (first-set) | tier invalid → 400 |
| `GET /players/{name}/stats` | stats + playerId; pemain tak dikenal → kosong (200) | — |
| `PATCH /players/{id}/tier` | admin: tier berubah + class ikut + RebuildAll | 401; tier invalid 400 |
| `PATCH /players/{id}/name` | admin: rename + alias lama tersimpan | 401; collision 400; placeholder 400 |
| `DELETE /players/{id}` | admin: tanpa force → ditolak bila ada riwayat; force → hapus | 401 |

### 3.4 Tournaments
| Endpoint | Positif | Negatif |
|---|---|---|
| `GET /tournaments` | list metadata (classic + team) | — |
| `POST /tournaments` | 201 + Location (classic & team) | format invalid → 400 |
| `GET /tournaments/{id}` | snapshot (branch format) | 404 |
| `PUT/PATCH /tournaments/{id}` | 200 version naik | If-Match 412; stale 409 |
| `POST /tournaments/{id}/delete` | admin: hapus + rating source bersih + rebuild | 401; 404 |

### 3.5 Ratings (write = admin)
| Endpoint | Positif | Negatif |
|---|---|---|
| `POST /ratings/ingest-session` | processed>0; re-run → no-op (idempotent) | 401; source tidak final → 409; source diedit → 409 `source_changed` |
| `POST /ratings/ingest-tournament` | classic & team branch | wajib `finalized` dulu |
| `POST /ratings/revert-session` / `-tournament` | events terhapus + RebuildAll; re-revert → no-op | 401 |
| `POST /ratings/rebuild-all` | rebuilt == jumlah pemain aktif | 401 |
| `POST /ratings/season` | arsip → tutup → musim baru → RebuildAll | 401; tanggal invalid 400 |
| `POST /ratings/players/{id}/rebaseline` | rating = baseline tier, peak=max | 401; player belum rated 404; tanpa tier 400 |

### 3.6 Ratings (read = publik)
| Endpoint | Positif |
|---|---|
| `GET /ratings/leaderboard?active&limit&offset` | total + rows (`tier/tier_derived/tier_display` 8-band) |
| `GET /ratings/players/{playerId}` | detail + history (DESC) |
| `GET /ratings/sources` | daftar + event_count + finalized |
| `GET /ratings/seasons` | musim terbuka + arsip |
| `GET /ratings/seasons/{id}/standings` | standings beku (tier 8) |

### 3.7 Priority urutan (8-tier baru = fokus)
1. Tier 8: forming player baru (D+ → 1250 → derived D+) · floor (B+ → rating rendah → display B) ·
   naik kelas (B+ → 1900+ → A) · RebuildAll identik · rename/tier admin
2. Regression inti: session lifecycle · rating ingest/revert · tournament classic & team

---

## 4. Area Tes Frontend

### 4.1 Statis (selalu jalan)
- `npm run check` — types + lint + tailwind + 60 regression (standings, tournament, team,
  sparkline, tiering 8-band, placeholders, retry, quality)
- `npm run build` — compile produksi bersih

### 4.2 Browser E2E (Playwright — kalau tersedia)
Matrix rute & aksi utama:

| Rute | Aksi yang dites |
|---|---|
| `/` | Grid menu 8 card (termasuk Ratings & Admin) navigasi benar |
| `/session/new` → players → constraints → generate | Wizard 4 langkah: guard route, picker tier **8 opsi**, bulk import, generate + QualityBanner + retry, publish |
| `/sessions` | List + filter tanggal |
| `/s/:sessionId` | SummaryModal: toggle played, set score, swap, absent (void confirm), change player, lock; **tidak ada tombol delete** |
| `/ratings` | Leaderboard: badge 8-tier, podium, provisional, trend, season picker (live/frozen), load more |
| `/ratings/:playerId` | Stat cards, sparkline, recent matches, cross-link ke player history |
| `/tournaments` | List + format badge + navigasi detail |
| `/tournaments/new` + wizard | Classic (16 pairs) & Team (6×6): setup → draw → confirm |
| `/tournaments/:id` | Tab groups/bracket/standings (classic) · klasemen/jadwal/final (team) |
| `/admin` | **Login** (token benar/salah/401) → unlock/delete session · ingest/revert/finalize/rebuild-all (feedback inline + disable saat running) · **delete tournament** · season close&start · player (add/rename/tier 8/rebaseline/hapus) |
| `/player-history` & `/player-history/:name` | List, detail stats, cross-link ke ratings |
| `/scoreboard` | Fullscreen overlay increment |
| `/instagram-post` | Load editor + template |

Catatan: login admin di browser → token di localStorage; **reload halaman → request admin tetap bawa Bearer** (regresi fix token).

### 4.3 Data uji frontend
Sesi/tournament test `it-e2e-*` dibuat via API dulu (cepat), lalu diverifikasi di UI.

---

## 5. Alur E2E Lengkap (backbone)

### Alur A — Session → Rating (inti)
```
1. POST /sessions (create) + PUT (publish snapshot: 12 pemain, tier campur 3-6)
2. Auto-lock simulasi: POST /sessions/{id}/lock
3. POST /ratings/ingest-session → processed == total game valid
4. GET /ratings/leaderboard → pemain baru muncul (forming tier benar)
5. GET /players/{name}/stats → games > 0
6. Edit skor → ingest ulang → 409 source_changed
7. POST /ratings/revert-session → rating balik → ingest ulang sukses
8. POST /sessions/{id}/delete → sesi hilang + source hilang + leaderboard bersih
```

### Alur B — Tournament classic + team
```
1. POST /tournaments (classic 16 pairs) → PUT groups → skor grup → bracket → skor
2. finalize → ingest-tournament → leaderboard mengandung pemain tournament
3. POST /tournaments/{id}/delete → bersih dari sumber + leaderboard
4. Ulangi dengan format team (6 tim × 6 pemain, 3 partai)
```

### Alur C — Admin (8-tier)
```
1. POST /players + tier 'B+' → leaderboard: rating 1850, tier B+, display B+
2. PATCH /players/{id}/tier 'B' → class ikut → RebuildAll → rating jadi 1750
3. PATCH /players/{id}/name → nama baru + alias lama resolve (stats tetap)
4. POST /ratings/players/{id}/rebaseline → rating = baseline
5. DELETE /players/{id} (force=false → ditolak bila ada riwayat)
```

---

## 6. Verifikasi DB (setelah tiap alur)

Via tunnel, cek konsistensi:
- `rating_players` ≡ proyeksi `rating_events` (re-run RebuildAll → angka identik)
- Tidak ada `source_id` yatim (events tanpa source di tabel sessions/tournaments)
- `session_players.tier` ∈ 1-8 · `players.tier` ∈ 8-tier valid
- Tidak ada `rating_players.class`/`class_source` (sudah drop)
- Konfigurasi: `class_bands` 8 · `session_tier_init` 8 · `season_start` konsisten

---

## 7. Checklist Akhir (definisi SELESAI)

- [ ] Backend: semua endpoint matrix PASS (positif + negatif + auth)
- [ ] Alur A/B/C lengkap PASS tanpa hantu data
- [ ] Frontend: `npm run check` + `npm run build` hijau
- [ ] Browser E2E: semua rute utama di-klik, tanpa console error
- [ ] 8-tier: forming/floor/naik-kelas/rebuild identik diverifikasi
- [ ] Data uji `it-*` semua dibersihkan (0 row test di DB)
- [ ] Bug yang ditemukan → fix → re-test → laporan

---

## 8. Pelaporan Hasil

Format per area:
```
AREA: Sessions
  [PASS] POST /sessions create → 201
  [PASS] PUT dengan If-Match → 200
  [FAIL] ... (detail + dugaan akar masalah + fix)
```

Bug diklasifikasi: 🔴 blocking (alur utama rusak) · 🟡 minor · 🟢 kosmetik.
Semua 🔴/🟡 di-fix & re-test sebelum sweep dianggap selesai; 🟢 dilaporkan.

---

## 9. Yang TIDAK dicakup (dilaporkan ke user)

1. Visual/UX subjective pass (butuh mata manusia)
2. PWA install prompt & offline di device asli (iOS/Android)
3. Migrasi prod (backup Supabase → restore → deploy main)
4. Load/perf (di luar scope — single club scale)
