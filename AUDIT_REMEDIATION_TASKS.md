# Audit Remediation Tasks

Sumber: hasil audit best-practices (`docs/audits/AUDIT_FULLSTACK_2026-09-10.md` + deep-dive
2026-09-14). Fokus: perbaikan konkret, perubahan sekecil mungkin, tanpa refactor besar.

Alur kerja: **kerjakan item → review/audit hasil → fix temuan → loop → item berikutnya**.
Satu commit + satu push di akhir.

## Scope

| # | Item | Sev | Status | Verifikasi |
|---|------|-----|--------|------------|
| 1 | CI web checks (`.github/workflows/web.yml`) | high | [x] | YAML valid; `npm run check` lulus lokal |
| 2 | Fix race `useDebouncedPublish` (deps `onError` + ref reset) | high | [x] | lint + tsc + review logika |
| 3 | Fix data-loss `updatePlayer` + guard `sessionSlice` | high | [x] | regression test ada (3 test) |
| 4 | Normalisasi query key ratings agar ter-invalidate | high | [x] | grep key lama = none |
| 5 | `strict: true` di `tsconfig.node.json` & `tsconfig.scripts.json` | medium | [x] | `tsc -b` lulus |
| 6 | Fix `StandingsTab` deps memo + perbandingan null | medium | [x] | lint (disable dihapus) |
| 7 | `publishTournament`: If-Match + Idempotency-Key + validasi respons | medium | [x] | kontrak server dicek |

Full check akhir: `npm run check` → **81 test pass**, types/lint/tailwind hijau.

## Ringkasan perubahan

- **CI**: `.github/workflows/web.yml` — `npm ci` + `npm run check` untuk push/PR `apps/web/**`.
  Sebelumnya hanya ada "API Checks"; perubahan web tidak divalidasi di CI sama sekali.
- **Race publish** (`hooks/useDebouncedPublish.ts`): `onError` dipindah ke ref. Sebelumnya
  callback inline dari `GeneratePage` (identitas baru tiap render) membuat effect cleanup
  berjalan tiap render, me-reset `inFlightRef` dan memicu publish tanpa debounce.
  Cleanup juga kini men-null-kan `publishTimerRef` setelah `clearTimeout`.
- **Data-loss** (`store/playersSlice.ts`): `updatePlayer` tidak lagi me-reset
  `schedule/lastResult/playedGames/gameScores`. id pemain stabil → schedule & skor tetap valid.
  Efeknya: rename pemain saat sesi live (mis. dari `ShareButton` resolve flow) tidak lagi
  menghapus skor.
- **Guard idempoten** (`store/sessionSlice.ts`): `setCourts`, `setSessionStart`, `setSlotMinutes`,
  `setCourtTime` tidak reset schedule/skor bila nilai tidak berubah.
- **Cache ratings** (`queries/ratings.ts`, `queries/sessions.ts`): key diseragamkan ke prefix
  `['ratings', ...]` sehingga `invalidateQueries(['ratings'])` menjangkau leaderboard, player,
  achievements, seasons, standings, sources. Sebelumnya 4 dari 6 query tak pernah ter-invalidate.
- **Tournament publish** (`queries/endpoints.ts`): kirim `If-Match` + `Idempotency-Key`,
  validasi bentuk respons (paritas dengan `publishSession`).
- **StandingsTab**: memo `ranked` menyertakan `groups` (hapus `eslint-disable` yang menyembunyikan
  bug), dan perbandingan skor null-safe (`scoreA > scoreB` hanya bila keduanya ada).
- **tsconfig**: `strict: true` untuk `tsconfig.node.json` & `tsconfig.scripts.json`.
- **Test**: `scripts/tests/storeSlices.test.ts` (3 test) mengunci perilaku reset store.

## Out of scope (dicatat, tidak dikerjakan sekarang)

- Refactor `SessionStore` god-package (terlalu luas/berisiko).
- Integration test Go di CI: butuh Postgres + migrasi `000001`–`000011` yang sengaja tidak ada di
  repo → tetap di-skip. Limitasi didokumentasikan, bukan bug.
- `eslint-plugin-jsx-a11y`, vitest/RTL, Prettier (dependency baru — butuh persetujuan).
- Perbaikan fokus ring/WCAG menyeluruh (38 `focus:outline-none`) — backlog terpisah.
- `store.migrate` hard-reset (keputusan desain, bukan regresi).
- Sisa `eslint-disable` di `ScoreboardPage`/`SetupPage`/`AdminContext`/`safeLazy` (sengaja,
  di luar scope perubahan ini).
