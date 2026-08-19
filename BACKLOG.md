# BACKLOG.md — Inventaris Task Tertunda / Backlog / Deferral

**Dibuat:** 2026-08-19
**Status:** Analisis komprehensif — daftar lengkap semua task yang belum selesai,
tertunda (deferred), opsional, dan keputusan terbuka dari seluruh dokumen MD di repo.
**Metode:** grep semua checkbox `[ ]` di seluruh `*.md` + verifikasi kode
(badminton-match + majadu-api) untuk memisahkan **backlog asli** dari
**checkbox stale** (sudah selesai tapi docs tidak di-update).
**Tujuan:** satu sumber kebenaran backlog — pengganti berburu item di 10+ dokumen.

---

## 0. TL;DR — Backlog dalam 30 detik

- **1 item kritis:** migrasi prod (`bm` Supabase → VPS) — belum mulai.
- **1 item security:** ganti password superuser postgres `qouver` (pernah terekspos).
- **1 item kolaborasi:** PR #1 lumberjack (backend) — analisis sudah diberi, belum ada aksi.
- **~10 item backlog fungsional** (sedang → kecil): rename player, team career stats,
  rebaseline, kalibrasi band, audit log ingest, decay rating, `sources?changed=true`, dll.
- **1 item blocking user:** visual pass browser (ratings/admin/tournament wizard).
- **Banyak checkbox docs yang STALE** (sudah selesai, tidak dicentang) — lihat §3.

---

## 1. Metodologi

1. `grep '\[ \]'` di semua `*.md` → 20 checkbox kosong + pertanyaan terbuka.
2. Verifikasi tiap item terhadap kode:
   - frontend: `src/` (routes, halaman, hooks — App.tsx, AdminPage, dst.)
   - backend: `/Users/user/Projects/majadu-api/internal/` (handler/store/domain)
3. Klasifikasi hasil: **A. pending asli** (belum ada kode) · **B. stale** (kode sudah ada)
   · **C. di luar scope / keputusan terbuka**.
4. Prioritas: 🔴 kritis → 🟡 sedang → 🟢 kecil/opsional.

---

## 2. A. Backlog Aktif (terverifikasi — belum ada implementasi)

### 2.1 🔴 Kritis

#### A1. Migrasi prod — Supabase `bm` → Postgres VPS
| | |
|---|---|
| **Sumber** | roadmap.md #1 · current-status.md "Pending #2" · backend-go-decision §6.7 |
| **Deskripsi** | Backup data `bm` dari Supabase → restore ke Postgres VPS (DB `bm`, skema parity sudah ada, kosong) → push backend `main` (CI → auto-update) → arahkan frontend `main` (mapping branch di vite.config sudah siap) → pensiunkan Supabase/PostgREST sepenuhnya |
| **Status komponen** | Backend prod container `majadu-api` (commit 21f4d95) SUDAH deploy di VPS, DB `bm` kosong · Frontend `main` belum |
| **Butuh** | Sesi khusus + backup data asli + parity check |
| **Blocker** | — (menunggu waktu & keputusan user) |

#### A2. Ganti password superuser postgres `qouver`
| | |
|---|---|
| **Sumber** | HANDOFF.md §2/§8.6 (security) |
| **Deskripsi** | Password pernah terekspos di chat. Ganti: `podman exec -it qouver-postgres psql -U qouver -c "ALTER USER qouver PASSWORD '<baru>';"` + update `compose.yaml` VPS |
| **Catatan** | Tidak terverifikasi sudah diganti di sesi berikutnya (tidak disebut di current-status) — perlu konfirmasi |

#### A3. Visual pass browser (user)
| | |
|---|---|
| **Sumber** | current-status "Pending #1" · RATINGS_FRONTEND_PLAN #16 · ADMIN_MENU_PLAN #13 |
| **Deskripsi** | User melakukan pemeriksaan visual di browser: wizard tournament (classic + team), halaman ratings (leaderboard/class badge/season picker/detail), admin area (login → /admin → unlock/ingest/season/player). Checklist ada di RATINGS_FRONTEND_PLAN §9 P3 |
| **Blocker** | Hanya bisa dikerjakan user (bukan agent) — item lain bisa jalan paralel |

### 2.2 🟡 Sedang

#### A4. PR #1 lumberjack (backend, kontribusi eksternal)
| | |
|---|---|
| **Sumber** | current-status "Infra & ops" |
| **Deskripsi** | PR open & dirty oleh ppabimanyu. Analisis sudah diberikan ke user: **AdminToken hilang** (env rename memutus auth), **`validate()` dibuang** (invariant turun), **env rename breaking** (MAJADU_* → nama lain). User sudah copas komentar; belum ada aksi dari author |
| **Aksi** | Putuskan: request revisi, close, atau merge manual (sangat disarankan revisi dulu — ada risiko security/regresi) |

#### A5. Endpoint rename canonical player
| | |
|---|---|
| **Sumber** | ADMIN_MENU_PLAN §7 #11 (DITUNDA) |
| **Deskripsi** | Rename nama kanonikal pemain. `registerPlayer` + alias saat ini = **merge** (bukan rename). Butuh endpoint khusus (mis. `PATCH /players/{id}/name` → update `players.canonical_name` + alias) |
| **Mengapa tertunda** | Menghindari salah-salah merge dua pemain berbeda |

#### A6. Team player career stats (belum aggregate team matches)
| | |
|---|---|
| **Sumber** | current-status "Pending #3" (terverifikasi: `store/stats.go` hanya query sessions) |
| **Deskripsi** | `GET /players/{name}/stats` belum menghitung match tournament format **team** (6 tim × 6 pemain). Perlu query tambahan ke `tournament_team_*` tables (partai → W/L, partner, opponent) |
| **Risiko** | Beda semantik dengan classic tournament stats yang sudah ada — perlu desain kecil |

#### A7. Auth JWT (ditunda)
| | |
|---|---|
| **Sumber** | roadmap #2 · current-status "Pending #3" · backend-go-decision §7 |
| **Deskripsi** | Middleware JWT/session di Go, alur host tanpa friction. Sementara memakai single admin token (`MAJADU_ADMIN_TOKEN`) |
| **Catatan** | Keputusan timing: sebelum/bersamaan/sesudah migrasi prod — masih terbuka |

#### A8. Port auto-rebase ke dev
| | |
|---|---|
| **Sumber** | current-status "Pending #3" (backlog) |
| **Deskripsi** | Mekanisme auto-rebase branch (CI?) — detail spesifik perlu dikonfirmasi ke user; disebut sebagai backlog tanpa dokumen |

#### A9. Sticky wizard bottom bar
| | |
|---|---|
| **Sumber** | current-status "Pending #3" (deferred) |
| **Deskripsi** | Bottom bar wizard session (setup→players→constraints→generate) yang sticky di viewport — ditunda |

### 2.3 🟢 Kecil / Opsional

#### A10. Rebaseline endpoint — `POST /ratings/players/{id}/rebaseline`
| | |
|---|---|
| **Sumber** | RATING_TIERING_REVAMP §8 P3 #11 (opsional) — terverifikasi **tidak ada** di kode |
| **Deskripsi** | Set `rating_players.rating = mid kelas` LANGSUNG (tanpa rebuild — rebuild menimpa rating manual dari events). Ingest berikutnya melanjutkan dari baseline baru secara alami |
| **Desain penting** | Rev 2: "set + rebuild" SALAH (rebuild menimpa). Hanya set langsung |
| **Guna** | Re-baseline pemain yang kelasnya diubah admin ke level rating baru |

#### A11. Kalibrasi lebar band terhadap data riil
| | |
|---|---|
| **Sumber** | RATING_TIERING_REVAMP §8 P2 #10 |
| **Deskripsi** | Ukur frekuensi ganti sub-tier per pemain di data riil bm_dev. Jika terlalu bising (ganti sub-tier tiap game), lebar band (sekarang 100) diubah via `rating_config.class_bands` (tanpa migration) |
| **Catatan** | Dengan delta settled 12.8/match (~1/9 band), pindah sub-tier wajar membutuhkan ±7-8 match — kemungkinan sudah OK, tapi belum diverifikasi terukur |

#### A12. `rating_ingest_runs` audit log (opsional)
| | |
|---|---|
| **Sumber** | RATING_ENGINE_DESIGN §10 #18c (didefer ke P3/opsional) — terverifikasi **tidak ada** |
| **Deskripsi** | Log riwayat ingest/reconcile/revert: mode, source, jumlah events, timestamp. `rating_sources.ingested_at` sudah menyimpan sebagian info ini |
| **Nilai** | Audit operasional (siapa kapan ngapain) — nilai rendah untuk single-admin, tinggi untuk debugging |

#### A13. Decay rating inactivity (opsional)
| | |
|---|---|
| **Sumber** | RATING_ENGINE_DESIGN §3.6 — terverifikasi: config `decay_*` sudah ada di `rating_config.go` tapi `DecayEnabled=false` default & **logika aplikasi belum diimplementasi** |
| **Deskripsi** | −5 poin/minggu setelah 60 hari idle (basis tanggal sumber), floor 1000. Pass non-replayable terpisah (didokumentasikan non-deterministik) — sengaja tidak default |
| **Keputusan** | RD growth sudah menangani ketidakpastian inactivity — decay ini bonus. Hanya aktifkan kalau leaderboard butuh "penalti absen lama" |

#### A14. `GET /ratings/sources?changed=true` (re-extraction)
| | |
|---|---|
| **Sumber** | RATING_ENGINE_DESIGN §10 #17 catatan — terverifikasi param **belum ada** |
| **Deskripsi** | Filter sumber yang fingerprint-nya divergen dari sumber (untuk UI admin: "mana yang berubah setelah ingest"). Perlu re-extract + bandingkan — ditunda karena jarang dipakai (flow normal = revert dulu baru ingest) |

#### A15. Snapshot contract `placeholder?: boolean`
| | |
|---|---|
| **Sumber** | ABSENT_TBD_PLAYERS_DESIGN §8 #11 (DITUNDA — keputusan deviasi) |
| **Deskripsi** | Field eksplisit di `Player` snapshot untuk placeholder. Pattern-based (`IsPlaceholderName`) sudah menangani semua permukaan (void, no-register, badge) — flag eksplisit menambah permukaan kontrak tanpa manfaat fungsional sekarang |
| **Aksi** | Revisit hanya kalau ada kebutuhan mengidentifikasi placeholder yang namanya bukan pola (jarang) |

---

## 3. B. Checkbox Stale — SUDAH SELESAI (docs lag, bukan backlog)

Item ini masih `[ ]` di docs tapi kode sudah ada / catatan task lain membuktikan selesai.
**Aksi:** centang + update status di docs (cleanup kecil). → **SELESAI 2026-08-19**
(S1–S14 sudah dicentang & diberi catatan status di dokumen masing-masing —
RATING_TIERING_REVAMP, RATING_ENGINE_DESIGN, ABSENT_TBD, roadmap,
backend-go-decision, HANDOFF). Tabel di bawah untuk referensi:

| # | Item | Lokasi checkbox | Bukti selesai |
|---|---|---|---|
| S1 | `ClassForRating` 12-band + `floorOf` + `initForSessionTier` + unit test | RATING_TIERING_REVAMP #2 | T1/T2 notes "forming mid kelas + class di-flush"; badge 12-band live di UI |
| S2 | `rating_config`: `ClassBands` + `SessionTierInit` (typed + validasi) | RATING_TIERING_REVAMP #3 | `domain/rating_config.go` + `store/rating_config.go` |
| S3 | Integration test: player baru tier C → class C + rating mid + floor display | RATING_TIERING_REVAMP #4 | `TestIntegrationTierFirstSetSticky` PASS live |
| S4 | Backfill class player existing dari tier session pertama | RATING_TIERING_REVAMP #9 | T1 note "backfill 128 tier/registered + 106 class" |
| S5 | P4 frontend: leaderboard, player detail, admin tombol | RATING_ENGINE_DESIGN #23–25 | RATINGS_FRONTEND_PLAN P1–P2 selesai (60 PASS, commit `eaf37e4`); ADMIN_MENU_PLAN P1 selesai |
| S6 | Update RATING_ENGINE_DESIGN: absent_policy/placeholder_policy/gate | ABSENT_TBD #15 | Doc Rev 3.1 sudah memuat semuanya |
| S7 | Rating ingest policy void/placeholder + test | ABSENT_TBD #16 | Policies terimplementasi (RATING_ENGINE_DESIGN §8) + integration live PASS |
| S8 | Menu tournament list | roadmap #3 | `TournamentListPage` + routes `/tournaments`, `/tournaments/new` ada di App.tsx |
| S9 | Pertanyaan backend-go-decision: nama repo · kontrak API · subdomain | backend-go-decision §7 | Repo = `majadu-api` · kontrak = mirror snapshot (bridge PUT) · subdomain = `api.qouver.com` path-based |
| S10 | Vercel env strategy | HANDOFF §5 #1 | Selesai via branch mapping di vite.config.ts (`__API_BASE_URL__`) |
| S11 | Backup cron VPS | HANDOFF §6 #7 | Timer harian 03:00 → `/srv/qouver/backups/postgres/` (current-status) |
| S12 | Regression test fix (12/12) | HANDOFF §6 #9 | `resolve-ts-imports.mjs` — 60 test PASS saat ini |
| S13 | Fix `isGoodQuality` b2b | HANDOFF §6 #3 | ✅ (quality.test.ts + backToBackFloor) |
| S14 | Drop kolom `snapshot` tournament | HANDOFF §6 #4 | Migrasi `f6_drop_snapshot.sql` applied VPS |

---

## 4. C. Di Luar Scope / Keputusan Terbuka

| # | Item | Status | Sumber |
|---|---|---|---|
| O1 | **Multi-user auth / per-role** — satu token = "admin tunggal" (sesuai skala klub). Upgrade → Supabase Auth/JWT = backlog | By design | ADMIN_MENU_PLAN §8 |
| O2 | **Admin UI edit skor sesi terkunci** — cukup unlock → edit normal | By design | ADMIN_MENU_PLAN §8 |
| O3 | **Nasib M-DEF** — sinkronisasi `rating_players` ke M-DEF vs pensiunkan M-DEF setelah leaderboard rating lahir | ✅ **DIPUTUSKAN (2026-08-19): M-DEF PENSIUN** — repo di-archive (SUPERSEDED.md), tanpa sinkronisasi | RATING_ENGINE_DESIGN §11 |
| O4 | Pipeline M-DEF `020_majadu_import_rpc` — perlu di-recreate di VPS kalau M-DEF lanjut | ✅ **TIDAK PERLU** (O3 → pensiun) | RATING_ENGINE_DESIGN §11 |
| O5 | **Hardening lanjutan** — monitoring/alert API, staging env | Opsional | roadmap #4 |
| O6 | **Fitur rating lain** — promosi/degradasi band, perbandingan antar pemain | 🚫 **DROP (2026-08-19)** — promosi/degradasi sudah otomatis via class_display; H2H/insights ditunda tanpa batas | RATINGS_FRONTEND_PLAN §10 |

---

## 5. D. Rekomendasi Urutan Kerja

```
SEKARANG (mendadak)
  1. A2  — ganti password qouver (security, 5 menit) + verifikasi A4 (PR lumberjack)
  2. A3  — jadwalkan visual pass browser bersama user

MIGRASI PROD (sesi khusus, satu fokus)
  3. A1  — backup Supabase bm → restore VPS → backend main → frontend main

SPRINT FITUR (nilai terbaik dulu)
  4. A5  — endpoint rename player (dipakai admin, backlog paling diminta)
  5. A6  — team player career stats
  6. A11 — kalibrasi lebar band (verifikasi data, kemungkinan no-op)
  7. A10 — rebaseline endpoint (opsional, kecil)

SESUAI KEBUTUHAN
  8. A13 decay · A12 audit log · A14 changed=true · A15 placeholder flag
  9. A7 auth JWT · A8 auto-rebase · A9 sticky bar (tunda)

MAINTENANCE DOCS (bisa kapan saja, 15 menit)
  10. Centang S1–S14 di docs masing-masing (dokumen ini jadi acuan)
```

---

## 6. Referensi Dokumen yang Di-scan

| Dokumen | Status relevansi |
|---|---|
| `docs/handbook/current-status.md` (2026-08-22) | **Primer** — kondisi terkini |
| `docs/handbook/roadmap.md` | Fase berikutnya |
| `docs/handbook/backend-go-decision.md` | Pertanyaan terbuka + keputusan |
| `RATING_ENGINE_DESIGN.md` (Rev 3.3) | Backlog rating opsional |
| `RATING_TIERING_REVAMP.md` (Rev 3.7) | Backlog tiering |
| `RATINGS_FRONTEND_PLAN.md` | Backlog UI ratings |
| `ADMIN_MENU_PLAN.md` | Backlog admin |
| `ABSENT_TBD_PLAYERS_DESIGN.md` | Backlog absent/placeholder |
| `HANDOFF.md` (2026-08-11) | Historis — banyak item sudah selesai (lihat §3) |
| Backlog gitignored (`TASK_LIST.md` · `DESIGN_BACKLOG.md` · `TOURNAMENT_BACKLOG.md`) | **TIDAK ada di lokal** — hanya di VPS/branch lain; itemnya tidak masuk analisis ini |
