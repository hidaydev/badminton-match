# Runbook cutover v1 → v2

Dokumen ini adalah prosedur yang dijalankan operator, bukan ringkasan arsitektur.
Cutover **manual dan satu arah**: tidak ada masa berdampingan, tidak ada cutover
dari push, dan tidak ada resume otomatis. Satu-satunya jalan kembali adalah
`rollback.sh`.

Status: urutan di bawah mengikuti script yang ada di repo (`ops/scripts/`), tetapi
**belum pernah dieksekusi di VPS**. Rehearsal D-3 yang membuktikan langkah
Quadlet, Caddy, dan `:v1-final`; sampai rehearsal itu selesai, anggap setiap
langkah di sini belum teruji.

## 0. Prinsip yang tidak boleh dilanggar

- Image v1 ditandai `:v1-final` **sebelum** v1 dimatikan. Kalau pembuatan tag
  gagal setelah v1 berhenti, tidak ada jalan pulang.
- v1 di-`disable`, bukan hanya `stop`. Reboot tidak boleh menghidupkannya lagi
  dan menulis ke `bm`.
- `bm` hanya dibaca: dump, bukan restore target, tidak ada DDL, tidak ada tulisan
  setelah cutover.
- `deploy-vps.sh` tidak pernah menjalankan cutover dan tidak membaca
  `cutover.step`. Kalau sebuah push terlihat "memperbaiki" cutover, itu bukan
  cutover.
- `:v1-final` hanya dipakai `rollback.sh`. Deploy pasca-cutover memakai `:prev`.

## 1. Tata letak di VPS

```
/srv/qouver/apps/majadu/
├── monorepo/                  # clone repo, sumber unit + db/migrations
├── scripts/                   # deploy-vps.sh, cutover.sh, rollback.sh, smoke.sh,
│                              # backup.sh, restore.sh (disalin dari repo)
├── env/
│   ├── majadu-prod.env        # symlink ke .v1 atau .v2 (mode 600)
│   ├── majadu-prod.env.v1     # MAJADU_PG_DSN → bm
│   ├── majadu-prod.env.v2     # MAJADU_PG_DSN → bm2, OWNER/ETL/SOURCE DSN
│   ├── ghcr-token             # mode 600; opsional bila podman sudah login
│   └── alert.env              # mode 600; opsional, MAJADU_ALERT_WEBHOOK
├── caddy/
│   ├── active.caddy           # symlink: site-v1 / site-v2 / site-maintenance
│   └── site-*.caddy           # disalin cutover.sh dari ops/caddy/
├── cutover/                   # cutover.step, v1-final.digest, snapshot.*,
│                              # majadu-api.container.v1, env-target.v1
├── deploy/                    # deployed-version, last-release.json
├── backups/                   # mode 700; dump harian + bm-cutover-*.dump
└── logs/                      # deploy.log, cutover.log, caddy-access.log
```

`/etc/caddy/Caddyfile` mengimpor `/srv/qouver/apps/majadu/caddy/active.caddy`
**di dalam** site `api.qouver.com`, menggantikan handler `/majadu/*` yang lama.
Site itu juga melayani `/hooks`, `/sds`, dan `/skyward`; snippet majadu tidak
boleh menggantikan seluruh site. Prefix `/majadu` dipertahankan setelah cutover,
jadi redirect OIDC, `PUBLIC_BASE_URL`, dan web client tidak berubah. Langkah
sekali-jalan (termasuk `skip_log` untuk `/majadu/s/*` dan `/majadu/ws/*`; preflight
menolak Caddyfile yang hanya menyebut yang pertama) ada di
`ops/caddy/Caddyfile.api.qouver.com`.

## 2. Checklist D-7

- [ ] Tag rilis sudah terbit dan GitHub Release memuat digest
      `ghcr.io/hidaydev/badminton-match@sha256:…`.
- [ ] Rehearsal T-063 lulus dan `./task rehearsal check` hijau
      (`tools/rehearsal/timings.json` ≤ 30 menit, restore ≤ 15 menit, jendela
      cutover ≤ 10 menit, `--from` terbukti).
- [ ] `majadu-prod.env.v1` dan `.v2` ada, mode 600, dan `bm2` belum berisi data
      produksi.
- [ ] `ghcr-token` (bila dipakai) mode 600 dan bisa `podman pull` digest rilis.
- [ ] `alert.env` berisi webhook, atau keputusan sadar bahwa alert hanya masuk
      journal.
- [ ] Kapasitas disk ≥ 3× ukuran `bm` (dump + `bm2` + WAL).
- [ ] Rehearsal D-3 di VPS dijadwalkan sebagai **maintenance window yang
      diumumkan**, bukan downtime mendadak.
- [ ] Rencana komunikasi: siapa yang diberi tahu saat maintenance mulai dan saat
      selesai.

## 3. D-3 — rehearsal di VPS (maintenance window diumumkan)

Dijalankan pada VPS sungguhan karena Quadlet dan Caddy tidak ada di mesin dev.
Harness-nya `tools/rehearsal/`; baca README di sana sebelum menjalankan.

1. Umumkan jendela maintenance (mulai + perkiraan selesai).
2. Pastikan `bm_staging` berisi salinan staging (`backup.sh --tag cutover` lalu
   `restore.sh --target bm_staging --recreate`).
3. Siapkan dua env rehearsal (`v1.env`, `v2.env`, mode 600) dari template di
   `ops/env/`. `bm2_rehearsal` dibuat ulang oleh harness, tidak perlu disiapkan.
4. `./task rehearsal run --version v<rilis> --dry-run` — periksa sandbox, unit,
   site Caddy, dan perintah yang akan dijalankan.
5. `MAJADU_REHEARSAL_CONFIRM=yes ./task rehearsal run --version v<rilis>` —
   harness menjalankan cutover, rollback, lalu membuktikan
   `--from restore-staging`, dan menulis `tools/rehearsal/timings.json`.
6. `./task rehearsal check` harus hijau; commit `timings.json`.
7. `./task rehearsal clean --drop-databases`.
8. Umumkan hasil rehearsal (durasi nyata) di channel yang sama.

Kalau rehearsal gagal, cutover D-day **ditunda**; tidak ada "coba saja di
produksi".

## 4. D-1

- [ ] Pastikan tidak ada perubahan skema yang belum di-release di `main`.
- [ ] Pastikan `VERSION` di `main` sama dengan tag rilis yang akan dipakai.
- [ ] Backfill data v1 yang masih dibutuhkan (skor, sesi draft) **sebelum**
      dump; setelah v1 dimatikan tidak ada lagi tulisan.
- [ ] Cek `curl -fsS https://api.qouver.com/healthz` (v1) dan satu share link
      lama untuk memastikan baseline.
- [ ] Catat jumlah baris v1 yang akan dibandingkan setelah ETL:
      pemain, sesi, game, turnamen.
- [ ] Siapkan sesi SSH kedua untuk memantau `journalctl --user -u majadu-api -f`
      dan log Caddy.

## 5. D-day

Semua perintah dijalankan dari SSH ke VPS sebagai pemilik app, dari
`/srv/qouver/apps/majadu`.

1. **Umumkan maintenance mulai.** Catat jam mulai.
2. **Jalankan cutover** (satu perintah; script memegang `flock` yang sama dengan
   deploy sehingga deploy yang datang di tengah menunggu):

   ```sh
   MAJADU_OWNER_SUB='<google-sub>' MAJADU_OWNER_EMAIL='<email>' \
     sudo -E /srv/qouver/apps/majadu/scripts/cutover.sh --version v2.0.0
   ```

   `--version` harus versi yang rilisnya sudah ada. Script berhenti sendiri bila
   `cutover_state.completed_at` sudah terisi.

3. Urutan yang dijalankan script (jangan dikerjakan manual kecuali resume):

   | Langkah | Yang terjadi | Sinyal |
   |---|---|---|
   | `preflight` | cek tools, tarik digest rilis, tag `:release`, salin snippet Caddy | log “release vX resolves to” |
   | `preserve-v1` | tag `:v1-final` dari container v1 yang hidup, verifikasi ID, simpan unit + target env | `v1-final.digest` tertulis |
   | `maintenance` | Caddy → `site-maintenance.caddy` (`caddy validate` dulu) | situs 503 + `Retry-After` |
   | `stop-v1` | `systemctl --user stop` + `disable` | unit v1 `inactive (dead)` dan `disabled` |
   | `snapshot` | `backup.sh --tag cutover`, sha256 dicatat | `backups/bm-cutover-*.dump` |
   | `restore-staging` | dump → `bm_staging` | `restore: done` |
   | `prepare-bm2` | roles, migrasi, seed, `ownerseed` | `dbtools: migrated 25 file(s)` |
   | `import` | ETL + `verify` | `problems: 0` |
   | `state` | isi `cutover_state`, tukar env ke `.v2` | `env now points at v2` |
   | `start` | `:release` → `:local`, enable + start v2 | unit `active (running)` |
   | `site` | Caddy → `site-v2.caddy` | situs kembali 200 |
   | `readyz` | poll `/readyz` 90 detik | `{"status":"ok"}` |
   | `smoke` | 6 cek perilaku | `smoke: all checks passed` |
   | `finish` | `completed_at = now()` | `cutover vX complete` |

4. **Verifikasi manual setelah script selesai:**
   - `curl -fsS https://api.qouver.com/readyz` → 200.
   - `curl -fsS https://api.qouver.com/version` → versi yang baru.
   - Login Google sebagai `platform_owner`, buka satu sesi, satu papan peringkat.
   - Satu share link **baru** (`/s/{kode}`) bisa dibuka tanpa login. Tautan v1
     yang sudah tersebar (`/s/{sessionId}`) tetap resolve selama sesi itu masih
     punya link hidup: `modules/share/store.nim:102-110` menerima UUID sebagai
     pengganti kode. Tautan itu ikut mati bila link-nya dicabut; konsekuensi
     rollback ada di §7.
   - Aktifkan timer **setelah** `MAJADU_PG_DSN` menunjuk `bm2`, satu per satu:
     `systemctl --user enable --now majadu-snapshot.timer majadu-ingest.timer
     majadu-janitor.timer majadu-readyz.timer majadu-rotate-log.timer`, lalu
     `systemctl --user list-timers` harus menampilkan keenamnya. Deploy hanya
     memasang berkas unit, tidak pernah meng-enable timer.
     `majadu-audit-retention.timer` membaca `MAJADU_AUDIT_DSN` dari env file dan
     berjalan bulanan; `majadu-ingest.timer` merating sesi yang di-approve tiap
     30 menit; `majadu-readyz.timer` menembak `/readyz` tiap 5 menit dan
     `majadu-rotate-log.timer` merotasi log tiap jam. Keduanya hanya bergantung
     pada host (bukan skema), tetapi `majadu-readyz` sengaja baru diaktifkan di
     sini: sebelum cutover port 8080 milik v1.
   - `psql "$OWNER_DSN" -c "select * from platform.cutover_state"` → satu baris,
     `completed_at` terisi, `rows_imported` cocok dengan hitungan `bm_staging`.

5. **Umumkan selesai.** Catat jam selesai dan durasi aktual.

## 6. Kalau gagal

Script berhenti dengan exit ≠ 0 dan `cutover.step` menunjuk langkah terakhir.
Pilih satu, jangan dua-duanya:

**A. Lanjutkan dari langkah yang gagal** — hanya kalau penyebabnya jelas dan
sudah diperbaiki (mis. password role salah):

```sh
/srv/qouver/apps/majadu/scripts/cutover.sh --version v2.0.0 --from <langkah>
```

`--from` tidak memeriksa ulang langkah sebelumnya; operator yang memastikan
keadaan di disk masih sesuai (mis. `:v1-final` sudah ada dan benar).

**B. Kembali ke v1:**

```sh
sudo /srv/qouver/apps/majadu/scripts/rollback.sh --abandon-data
```

Rollback menghitung dulu berapa baris bm2 yang ditulis setelah `completed_at`
(sesi, game, pemain, turnamen, event rating) dan **menolak berjalan** bila ada
tulisan tanpa `--abandon-data`; angka yang akan hilang dicetak di pesan error
dan di log. Tambahkan `--drop-bm2` bila database bm2 ikut dihapus, bukan
ditinggal untuk diperiksa.

Rollback memulihkan `:v1-final`, unit dan env yang disimpan saat `preserve-v1`,
mengembalikan Caddy ke `site-v1.caddy` (dengan `caddy validate`), `enable` +
`start` v1, menunggu `/healthz`, mengarsipkan baris `cutover_state` ke
`cutover/cutover.state.json`, lalu menghapusnya supaya cutover berikutnya tidak
diblokir.

Kalau rollback sendiri gagal, jangan mengulang cutover: pulihkan manual dari
`cutover/majadu-api.container.v1`, `cutover/env-target.v1`, dan tag
`:v1-final`, lalu buka insiden.

## 7. Konsekuensi yang harus diumumkan saat rollback

- **Semua sesi login v2 tidak berlaku.** Pengguna harus login ulang; cookie v2
  menunjuk `account.sessions` yang ditinggalkan.
- **Share link v2 mati.** Kode lama v1 juga tidak dipertahankan saat cutover,
  jadi tidak ada yang otomatis hidup kembali. Tautan harus diterbitkan ulang
  setelah v1 hidup.
- **Bundle FE v2 di cache browser harus di-reload paksa.** `no-store` hanya
  berlaku untuk dokumen baru; tab lama memakai bundle yang sudah dimuat.
- **Data `bm2` setelah cutover dibuang** (default: ditinggalkan; `--drop-bm2`
  menghapus database). Tidak ada migrasi balik ke `bm`.
- **`cutover_state` dihapus**, sehingga cutover bisa dijalankan lagi; baris
  lamanya ada di `cutover/cutover.state.json`.
- **`bm` tidak berubah** selama cutover maupun rollback: ia hanya dibaca.

## 8. D+1

- [ ] `/readyz` hijau 24 jam; tidak ada restart tak terduga
      (`systemctl --user status majadu-api`).
- [ ] `cutover_state.rows_imported` masih sama dengan hitungan `bm_staging`
      (cron pemeriksa atau manual).
- [ ] Tidak ada `majadu-alert@` di journal.
- [ ] Backup harian `bm2` berjalan dan bisa dibaca (`pg_restore --list`).
- [ ] Sesi pertama yang dibuat pengguna nyata tampil di papan peringkat.
- [ ] `rating.snapshots` bertambah untuk tanggal kemarin
      (`select max(taken_on) from rating.snapshots`), dan panah di papan
      memakai snapshot itu.
- [ ] Catat penyimpangan (angka, UI, login) di catatan insiden bila ada.

## 9. D+30

- [ ] `bm` tetap read-only; role `bm2_*` tidak bisa `CONNECT` ke sana
      (`ops/db/roles.sql` sudah memastikan lewat asersi).
- [ ] Dump harian `bm` berhenti; simpan satu dump final di luar rotasi.
- [ ] `:v1-final` dipertahankan sampai T-082: arsipkan sebagai tarball
      (`podman save`) **sebelum** tag dihapus, lalu hapus bersama dekomisi Go.
- [ ] Tinjau apakah `majadu-prod.env.v1` dan `ops/scripts` v1 masih diperlukan;
      jangan hapus `:v1-final` lebih awal dari 30 hari.

## 10. Yang belum terbukti sampai rehearsal D-3

- `cutover.sh`, `rollback.sh`, dan `deploy-vps.sh` belum pernah dijalankan pada
  VPS ini.
- `caddy validate` baru dijalankan pada file yang dibuat di repo, bukan pada
  Caddy yang hidup.
- Quadlet (`StartLimit*`, `MemoryMax`, `OnFailure`) belum di-parse systemd
  sungguhan.
- Durasi di §5 adalah target, bukan hasil ukur; `timings.json` dari rehearsal
  yang menggantikannya.
