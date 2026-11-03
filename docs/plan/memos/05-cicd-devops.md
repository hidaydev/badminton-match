# Memo 05 — CI/CD & DevOps (rewrite Nim + rework frontend)

Basis: `docs/audits/2026-11-03/03-ci.md`, `04-deploy-pipeline.md`, `05-security.md`,
kontrak emas `cbs` (AGENTS.md §2–3, `task`, `.github/workflows/ci.yml`) dan `majadu`
(`.github/workflows/*`, `ops/scripts/*`, `ops/github/ruleset-main.json`).
Read-only: tidak ada workflow/script yang diubah. Semua nomor baris menunjuk kondisi repo hari ini.

## 0. Keputusan inti

| # | Keputusan | Alasan singkat |
|---|---|---|
| D1 | Root `./task` (POSIX sh) menggantikan `Makefile` sebagai satu pintu | `Makefile:13,19,25` masih `npm`; 03-ci P2-2. Pola `cbs/task:34-63`, `majadu/task:1-10` |
| D2 | Toolchain Nim 2.4.0 dipin di **tiga** tempat: CI, Dockerfile, `.nimble` | `cbs/.github/workflows/ci.yml:48-51`, `cbs/apps/api/Dockerfile:27`, `cbs/kran.nimble:19` |
| D3 | **Tanpa** `nimble.lock`; pin eksak di `.nimble` + commit pin untuk dep tanpa tag | `majadu.nimble:8-27`: `nimbleLockExists` mematikan global Nimble path saat `nim c` biasa |
| D4 | Build flags tunggal: `-d:release --opt:speed --threads:on --mm:atomicArc` | `cbs/task:496`; `./task build` = flag image, tanpa duplikasi |
| D5 | `-static` **ditolak** | `db_connector` membuka `libpq.so` lewat dynlib saat runtime (`cbs/apps/api/Dockerfile:62-63`); `-static` tidak menghapus kebutuhan itu, hanya menyembunyikannya |
| D6 | Build context image = **root repo**, bukan `apps/api/` | sumber Nim tersebar (`shared/`, `modules/`, `apps/`), `cbs/apps/api/Dockerfile:8-12` |
| D7 | Deploy berhenti menjadi "push = prod"; webhook menunggu check-run hijau | `04-deploy-pipeline.md:82` (CI tidak menggerbangi rilis), `cbs/ops/scripts/deploy-vps.sh:113` |
| D8 | Repo ini **belum** push; semua gerbang di atas diuji lewat `./task rehearse` (D9 di §4) | instruksi sesi: develop lokal sampai stabil |

## 1. CI redesign

### 1.1 Job graph

Nama job = string stabil, karena ruleset dan deploy gate membaca check-run **by name**
(`majadu/ops/github/ruleset-main.json:29-35`, `cbs/ops/scripts/deploy-vps.sh:113-140`).

| Job (name) | Isi | DB | Target |
|---|---|---|---|
| `Repo: check + unit` | `./task check-fast` (format, `nim check` paralel, archcheck, i18n) + unit/property tanpa DB | – | ≤5 m |
| `Database: migrations + integration` | Postgres service, `./task dbtools migrate`, integrasi, guard "skip = gagal" | ya | ≤10 m |
| `Web: types + lint + build` | `pnpm install --frozen-lockfile`, `pnpm check`, `pnpm build`, `apps/scoreboard` ikut | – | ≤6 m |
| `Browser: e2e + axe` | Playwright + axe 2 tema, API nyata, ambang jumlah test | ya | ≤12 m |
| `Image: build + container smoke` | `podman build`, jalankan container, `/healthz` + `/version` + `id -u`=10001 + budget ukuran | – | ≤8 m |
| `Security: gitleaks + deps` | gitleaks PR range, dependency-review, `pnpm audit --prod`, osv-scanner | – | ≤4 m |
| `Gate` | `if: always()`, `needs:` semua di atas, gagal bila salah satu bukan `success` | – | ≤1 m |

Aturan yang mengikat semua job:

- `timeout-minutes: 15` di **setiap** job, termasuk `Gate` dan job nightly (kontrak §2; hari ini
  `ci.yml:25,58,85` sudah patuh — pertahankan).
- `runs-on: ubuntu-24.04`, bukan `ubuntu-latest` (03-ci P3-7).
- `permissions` minimal per job; default workflow `contents: read` (`ci.yml:14-15` sudah benar).
  Job security boleh `pull-requests: read` (pola `majadu/.github/workflows/ci.yml:186-188`) —
  tanpa itu komentar PR gitleaks gagal (`03-ci.md:230-247`).
- **Nol** `${{ }}` di dalam `run:`. Semua konteks lewat `env:` (`ci.yml:43-45` adalah contoh
  yang sudah benar; pertahankan polanya, termasuk untuk `github.ref_name`).
- Semua `uses:` dipin SHA + komentar versi (`majadu/.github/workflows/ci.yml:29-40`), karena
  `gitleaks-action@v2` masih runtime Node 20 (`ci.yml:93`; 03-ci P2-6).
- `concurrency.cancel-in-progress` **hanya untuk PR** (`ci.yml:19` membatalkan run `main`,
  03-ci P2-8).
- `paths-ignore` dihapus; `Gate` yang selalu jalan menutup lubang "required check menggantung"
  (03-ci P2-7).
- `workflow_dispatch` wajib ada (03-ci P3-6, `cbs/.github/workflows/ci.yml:26-29`).

### 1.2 Cache

| Cache | Path | Key |
|---|---|---|
| Nim compiler cache | `~/.cache/nim` | `nim-<os>-2.4.0-<hash .nimble+config.nims>` + `restore-keys` |
| Nimble deps | `~/.nimble` | `nimble-<os>-2.4.0-<hash .nimble>` (`cbs/.github/workflows/ci.yml:53-57`) |
| pnpm store | via `setup-node` `cache: pnpm` | `cache-dependency-path: pnpm-lock.yaml` (`ci.yml:73-74`) |
| Playwright browser | `~/.cache/ms-playwright` | `playwright-<os>-<hash pnpm-lock.yaml>` (`cbs/.github/workflows/ci.yml:218-222`) |

Catatan kejujuran: nimcache Nim dinamai dari **absolute path** proyek. Cache hanya hit bila
checkout berada di path yang sama (`/home/runner/work/<repo>/<repo>` — stabil di Actions), jadi
gunakan `--nimcache:$PWD/.build/nimcache` agar key dan path tidak bergantung pada home runner.
Cache miss = build dingin, bukan kegagalan. Jangan cache `.build/bin`: artefak yang diuji harus
dikompilasi di job yang mengujinya.

Playwright: `playwright install chromium` **tanpa** `--with-deps` (lib sistem sudah ada di
`ubuntu-24.04`; `--with-deps` pernah menghabiskan 14m47s — `cbs/.github/workflows/ci.yml:230-234`).

### 1.3 Artifact

| Artifact | Sumber | Retensi |
|---|---|---|
| `coverage-lcov` | `gcovr --lcov` dari job DB + unit | 7 hari |
| `e2e-evidence` | `test-results/` (trace, screenshot), log API — `if: failure()` | 7 hari |
| `gitleaks.sarif` | upload ke code scanning | 30 hari |
| `image-meta.json` | `podman inspect` (Id, digest, size, labels) | 7 hari |
| `preflight/` | bundel rehearsal (§4) | 14 hari |

### 1.4 Coverage gate

- Kompilasi ukur: `nim c --passC:--coverage --passL:--coverage` → `.gcda` → `gcovr`.
- Ambang: **ratchet**, bukan angka karangan. `ci/coverage-floor.txt` diisi dari hasil run hijau
  pertama, lalu hanya boleh naik; turun >1.0 pp gagal.
- Cakupan dihitung pada `apps/api/src` + `modules/`; file `generated/` dikecualikan.
- `nim check` dan test tidak boleh "hijau karena kosong": kalau `.nim` ada tapi test tidak,
  gate gagal (pola `cbs/task:359-364`).

### 1.5 Nightly

`scheduled` job terpisah (tidak berbagi concurrency group PR):

1. gitleaks **seluruh riwayat** (`--log-opts=--all`), karena gitleaks-action hanya memindai range
   push/PR — 8 temuan lama di file yang sudah dihapus tidak pernah tertangkap
   (`05-security.md:155-157`).
2. `osv-scanner` atas `pnpm-lock.yaml`, `.nimble`, dan digest image.
3. `podman build --pull=always` untuk mendeteksi base digest yang bergerak (D5/D6), tanpa push.
4. `./task ci-repeat 2` — flake hanya muncul saat diulang (`cbs/task:733-746`).
5. `ossf/scorecard-action` (`majadu/.github/workflows/scorecard.yml:3-8`).

## 2. Nim-specific build

**Toolchain.** CI: `jiro4989/setup-nim-action@<sha>` dengan `nim-version: '2.4.0'`
(`cbs/.github/workflows/ci.yml:48-51`). Docker: tarball resmi + `sha256sum -c`
(`cbs/apps/api/Dockerfile:27-44`). `.nimble`: `requires "nim >= 2.4.0 & < 2.5.0"`.
Ketiganya harus sama; satu tempat berbeda = biner yang diuji bukan biner yang dikirim.

**Runtime libs.** Runner tidak membawa `libpcre3`, dan `std/re` + mesin rute Mummy membukanya saat
runtime → `sudo apt-get install -y libpcre3` di setiap job Nim yang menjalankan biner
(`cbs/.github/workflows/ci.yml:62-66`). Postgres client lib untuk `db_connector` juga harus ada
di job DB.

**Flags.** Satu sumber: `./task build`. `-d:release --opt:speed --threads:on --mm:atomicArc`.
`--mm:atomicArc` bukan preferensi: Mummy menolak `yrc` saat kompilasi dan ORC tidak thread-safe
untuk `Request` yang berpindah thread (`cbs/task:43-53`, `cbs/apps/api/Dockerfile:52-59`).
CI harus menguji **flag yang sama** dengan produksi; kalau tidak, kelas bug ini lolos ke image.

**Reproducibility.**
- `SOURCE_DATE_EPOCH` dari commit, versi/commit di-`-d:` (bukan timestamp runtime).
- `--passC:"-ffile-prefix-map=$PWD=."` supaya stack trace tidak memuat path runner.
- `--passL:"-s"` (strip) + `--passC:-ffunction-sections --passL:-Wl,--gc-sections`.
- Build kedua dari tree yang sama harus menghasilkan binary identik; ini diuji di job `Image`
  (`sha256` binary build-1 vs build-2), bukan diasumsikan.

**Dependency pinning.** Ikuti majadu apa adanya:
- semua dep `==` eksak; dep tanpa tag dipin ke commit SHA (`majadu.nimble:24-27`);
- requirement transitif yang mengapung (`>=`) didaftarkan eksplisit supaya pohon tidak berubah diam-diam;
- `nimble.lock` ditolak dengan alasan tertulis (`majadu.nimble:15-19`, `docs/DECISIONS.md` D-046) —
  wajib dicatat di `docs/DECISIONS.md` repo ini, bukan hanya di komentar.
- Pengganti lock: `./task deps-check` membandingkan hasil `nimble install -d -y` (versi + checksum
  tiap paket) dengan `deps.lock.txt` yang di-commit. Gagal = minta commit ulang secara sadar.

**Ukuran image.** Budget eksplisit: **≤120 MB**. Isi runtime hanya `ca-certificates`, `libpq5`,
`libpcre3`, binary. Diukur di job `Image`; lewat budget = merah (mencegah "kecil tapi tidak
sengaja" berubah jadi 400 MB tanpa ada yang melihat).

## 3. Dockerfile + Quadlet + kontrak deploy

### 3.1 Dockerfile

1. Multi-stage: build (`debian:bookworm-slim@sha256…` + Nim 2.4.0 tarball ber-checksum) →
   runtime (`debian:bookworm-slim@<digest sama>`).
2. **Digest, bukan tag**: `apps/api/Dockerfile:2,15` masih `golang:1.26-alpine` / `alpine:3.20`
   (04-deploy P2-4). Pakai pola `ARG DEBIAN_DIGEST=sha256:…` + `FROM …@${DEBIAN_DIGEST}`
   (`cbs/apps/api/Dockerfile:22-25,64`).
3. Layer: `COPY <pkg>.nimble` → `nimble install -d -y` → `COPY . .` → `nim c`
   (`cbs/apps/api/Dockerfile:46-59`). `.dockerignore` wajib memuat `.local/`, `node_modules`,
   `.build`, `dist`, `docs`, `.git`.
4. Non-root: `useradd --system --uid 10001` + `USER`, **harus** sama dengan
   `UserNS=keep-id:uid=10001` di quadlet (`ops/systemd/majadu-api.container:18`).
5. `HEALTHCHECK` di Dockerfile (`--interval=10s --timeout=3s --retries=3`, endpoint liveness) —
   hari ini tidak ada (04-deploy P3-6).
6. Build args: `VERSION`, `COMMIT`, `DATE` wajib **dikirim** oleh deploy; hari ini default
   `dev/none/unknown` dan live membuktikannya (`04-deploy-pipeline.md:176-188`).

### 3.2 Quadlet (`ops/systemd/majadu-api.container`)

Wajib ada dan sinkron 1:1 dengan server: `NoNewPrivileges=true`, `DropCapability=ALL`,
`HealthCmd=`/`HealthInterval=`, `OnFailure=` untuk alert, `Restart=always` (sudah ada `:20`),
`EnvironmentFile` mode 600 (`:15`), `PublishPort=127.0.0.1:8080:8080` (`:13`).
Hari ini repo **lebih lemah** dari server: dua baris hardening hilang (04-deploy P2-5), dan
`switch_local_image()` menulis ulang unit dengan `sed` (`deploy-vps.sh:27-41`) sehingga repo
bukan sumber kebenaran. Ganti dengan `sync_units()`: `cp` dari repo + `.bak` + `cmp`
(`cbs/ops/scripts/deploy-vps.sh:405`).

### 3.3 Kontrak deploy — status hari ini

| Aturan kontrak | v1 hari ini | Target |
|---|---|---|
| Fail-closed ref guard | **PASS** `deploy-vps.sh:15-18` | pertahankan literal, jangan disentuh |
| Repo guard (`$1`) | tidak ada (04-deploy P3-5) | tolak repo asing, `exit 0` + log |
| `flock` konkurensi | **FAIL** `-n` + `exit 0` = rilis dibuang senyap (`:22-24`) | `flock -w 900` lalu `exit 1` (`majadu/ops/scripts/deploy-vps.sh:119-125`) |
| Retensi `:local`/`:prev` saja | **PASS** `:72-75` | + hapus image lama by ID setelah sukses (`cbs/ops/scripts/deploy-vps.sh:662-671`) |
| Tanpa tag commit-SHA | **PASS** | pertahankan; dilarang `:$REV` |
| Restart gagal → rollback | **FAIL** `set -e` keluar di `:77` | `trap ERR` + `rollback <reason>` (`majadu/ops/scripts/deploy-vps.sh:149-183`) |
| Health gate = readiness | **FAIL** poll `/healthz` (`:79`) yang selalu 200 (`apps/api/internal/handler/health.go:21-23`) | poll `/readyz` (`:27-40`), deadline 60 s, `curl --max-time 3` |
| Rollback terverifikasi | **FAIL** `:93-96` `|| true`, tanpa re-check | setelah rollback poll `/readyz`; tulis `rolled back OK/FAILED` |
| Identitas image | **FAIL** tanpa `--build-arg` (`:75`) | kirim `VERSION/COMMIT/DATE` dari `NEW_REV` |
| Container benar-benar image baru | tidak ada | bandingkan `podman inspect .Image` vs `image inspect :local` (`cbs/ops/scripts/deploy-vps.sh:694-700`) |
| Deploy menunggu CI hijau | **FAIL** push = deploy (04-deploy P2-2) | `ci_gate "$NEW_REV"` fail-closed (`cbs/…:113`) |
| `rollback.sh` + `smoke.sh` | tidak ada (04-deploy P2-3) | port dari `majadu/ops/scripts/{rollback,smoke}.sh` |
| Self-update script aman | `cp`+`mv` tanpa `bash -n` (`:59-67`) | `bash -n` sebelum `mv` |
| Alert kegagalan | tidak ada | `trap ERR` + notify + `logs/last-release` (04-deploy P1-5) |
| File mode script | `644` (tidak executable) | `755` di repo |

`smoke.sh` memeriksa **perilaku**, bukan port: `/version` == `VERSION` checkout, `/healthz`,
`/readyz` body tidak kosong, `/metrics` **404** dari luar, share code tak dikenal 404
(`majadu/ops/scripts/smoke.sh:36-54`).

## 4. Environments

| Lingkungan | Isi | Pemicu |
|---|---|---|
| `local` | `./task dev` (API + Vite), Postgres container lokal, DB per worktree | developer |
| `rehearsal` | `./task rehearse`: deploy script asli dijalankan terhadap pod throwaway | developer, sebelum merge |
| `staging` | quadlet kedua `majadu-api-staging` @ `127.0.0.1:8081`, schema `bm_staging`, Caddy `staging.` | push `main` setelah CI hijau (opsional, diputuskan owner) |
| `prod` | `majadu-api` @ `8080`, schema `bm`, Caddy `api.` | webhook + `ci_gate` |

**Rehearsal (pengganti "push lalu berharap").** `deploy-vps.sh` dijalankan **file yang sama**,
dengan batas lingkungan lewat env — bukan salinan skrip:

```
MAJADU_APP_DIR=$PWD/.build/rehearse      MAJADU_PORT=18080
MAJADU_SERVICE_CMD=$PWD/.build/fake-systemctl   MAJADU_SKIP_GIT_SYNC=1
MAJADU_REF=refs/heads/main               MAJADU_IMAGE=localhost/majadu-api-rehearse
```

Langkah `./task rehearse`:
1. tolak working tree kotor; catat `git rev-parse HEAD` di bundel bukti;
2. `podman pod create -p 127.0.0.1:18080:8080` + Postgres throwaway + migrate dari nol;
3. jalankan deploy (build → rotate `:prev` → swap → restart → readiness gate);
4. jalankan `smoke.sh` terhadap `127.0.0.1:18080`;
5. **latihan rollback**: build kedua dengan `MAJADU_REHEARSE_FAIL=1` (biner keluar non-zero saat
   start) → deploy harus gagal, `:prev` dipulihkan, `/readyz` hijau lagi, exit code 1.
   Tanpa langkah ini jalur rollback tidak pernah dieksekusi sampai insiden nyata.
6. tulis `.build/rehearse/<stamp>/report.md` (pola `majadu/task:1002-1105`).

Batas yang diakui: rehearsal **tidak** menguji quadlet/systemd dan tidak menguji Caddy. Keduanya
hanya terbukti di VPS. Karena itu `staging` (bila diaktifkan) adalah satu-satunya jalur yang
menguji unit nyata sebelum prod. `--dry-run` milik majadu berhenti setelah guard
(`majadu/ops/scripts/deploy-vps.sh:111-116`) — itu bukan rehearsal.

## 5. Observability

**Log.** Satu baris JSON per request ke stdout: `ts`, `level`, `request_id`, `method`,
`route_template` (bukan path mentah — share code adalah kunci tulis, `00-index.md:22`),
`status`, `duration_ms`, `bytes`. Tanpa body, tanpa query string, tanpa `Authorization`,
tanpa nama pemain, tanpa `DATABASE_URL`. Log file mode **0600** dan tanpa IP klien + stack trace
hari ini ditulis `0644` (`05-security.md:128`). `request_id` dikembalikan sebagai header dan
dipakai di log deploy untuk korelasi.

**Metrics.** `GET /metrics` (Prometheus text) hanya di loopback: `http_requests_total{route,status}`,
`http_request_duration_seconds` (histogram), `db_pool_in_use`, `db_ready` gauge,
`build_info{version,commit}`. Caddy **tidak** boleh mengeksposnya → smoke mengharapkan 404 dari
publik (`majadu/ops/scripts/smoke.sh:53-54`).

**Health vs readiness.**
- `/healthz` = liveness, tidak menyentuh DB, selalu 200 (`health.go:21-23`).
- `/readyz` = DB ping **+** kecocokan schema head: bandingkan versi migration yang tercatat di
  ledger dengan yang diharapkan biner. Bila ledger belum ada di repo (keputusan memo DB),
  readiness tetap ping-only dan identitas rilis dijamin lewat `/version` + image check.
- `/version` = `{version, commit, date}`, dipakai deploy gate dan smoke.

**Alerting.**
- `OnFailure=` pada unit quadlet → notifikasi; `start-limit-hit` juga.
- Deploy: `trap ERR` → notifikasi + `logs/last-release`; monitor membaca mtime `last-release`
  (deploy basi > 1 jam setelah push = alarm).
- `/readyz` gagal >2 menit berturut-turut = alarm; gagal sesaat tidak.
- Nightly job merah = masalah, bukan noise.

**Retensi.** journald user dibatasi (`SystemMaxUse=`), `deploy.log` dirotasi (harian, 90 hari),
log aplikasi size-based 50 MB × 5. Tanpa batas, disk VPS adalah timer kegagalan yang berdetak.

## 6. Guardrails untuk repo publik

| Guardrail | Alat | Di mana |
|---|---|---|
| Secret scanning riwayat penuh | gitleaks `--log-opts=--all` | nightly + `pre-commit` staged |
| Push protection | GitHub secret scanning (native) | setting repo |
| Dependency review | `actions/dependency-review-action` | PR, `pull-requests: read` |
| Advisory scan | `pnpm audit --prod --audit-level high` + osv-scanner | CI `Security` |
| Workflow lint | `actionlint` | `pre-commit` + `./task check` |
| Shell lint | `shellcheck -S warning` + `bash -n` | `./task check` (`cbs/task:251-275`) |
| Branch protection | `ops/github/ruleset-main.json` | setting repo |
| Commit signing | SSH signing key + ruleset `required_signatures` | aktif **setelah** kunci terpasang di semua mesin |
| Dependabot | npm, docker, github-actions | `.github/dependabot.yml` (belum ada) |

`ruleset-main.json` (adaptasi `majadu/ops/github/ruleset-main.json:11-37`): `deletion`,
`non_fast_forward`, `pull_request` (squash+merge), `required_status_checks` dengan context
persis nama job §1.1. `strict_required_status_checks_policy: false` untuk repo solo.

**Tidak boleh masuk repo:** env nyata (hanya `ops/env/*.env.example`), dump schema
(`.local/schema-bm-2026-11-03.sql` ada di working copy, di-ignore `.gitignore:67` — jangan pernah
dihapus dari ignore), IP/host server (`ops/caddy/Caddyfile.api.qouver.com:3` masih memuat IP —
ganti placeholder `<VPS_IP>`), secret HMAC (`ops/webhook/webhook.json:13` placeholder, benar),
`.local/`, `dist/`, token dev di dokumen rencana lama (`05-security.md:155-157`).

**Pre-commit hook** (`.githooks/`, dipasang `./task hooks` → `core.hooksPath`, pola `cbs/task:500-512`):
1. `gitleaks protect --staged --redact` (fail-closed; kalau gitleaks tidak ada di mesin, blokir
   commit **atau** minta `MAJADU_SKIP_HOOKS=1` eksplisit);
2. tolak path terlarang: `*.env`, `.local/*`, `*schema*.sql`, `*.pem`, `*.p12`;
3. tolak file >2 MB (dump, fixture biner);
4. `nimpretty --check` pada `.nim` staged; `nim check` cepat pada file yang berubah;
5. `actionlint` pada `.github/workflows/*`; `shellcheck` pada `*.sh` staged.

## 7. Parallel-work enablement

Satu Postgres container lokal (`majadu-pg`, `127.0.0.1:5433`), **satu database per worktree**:
`createdb majadu_dev_<slug>`; `.local/dev.env` per worktree (di-ignore) memuat
`MAJADU_DATABASE_URL`, `MAJADU_PORT` (8090 + offset), `MAJADU_NIMCACHE=$PWD/.build/nimcache`.
Skrip seed/reset **menolak** nama DB yang tidak berakhiran `_dev`/`_test` (pola `majadu/task:166-189`)
— ini yang mencegah satu subagent menghapus DB subagent lain.

Worktree: `.worktrees/<slug>` sudah di-ignore (`.gitignore:13`). Aturan untuk subagent:
port tidak boleh di-hardcode, DB selalu bernama unik, `.build/` selalu di dalam worktree.

Kontensi CI: `concurrency` per ref + `cancel-in-progress` hanya PR (§1.1); job dipisah sehingga
perubahan Nim tidak mengunduh browser dan perubahan CSS tidak mengompilasi Nim; `schedule` punya
group sendiri. Kalau antrean tetap padat, pecah `nim-check` per modul (shard), bukan menaikkan
timeout.

## 8. Urutan eksekusi

1. `./task` runner + `task lint`/`task build` yang identik dengan CI (D1, D4).
2. `.nimble` pin + `deps.lock.txt` + `./task deps-check` (D3).
3. `pre-commit` hooks + `.gitleaks.toml` allowlist fixture.
4. Dockerfile baru (digest, non-root 10001, HEALTHCHECK, args) + `./task rehearse` (§4).
5. Workflow baru: 6 job + `Gate`, cache, artifact, coverage ratchet.
6. `deploy-vps.sh` v2: flock `-w`, `/readyz`, `trap ERR`, build-arg, `sync_units`, `smoke.sh`,
   `rollback.sh`; verifikasi lewat rehearsal **dan** satu deploy terkontrol ke staging.
7. `ruleset-main.json` + secret scanning + dependabot + signing — **terakhir**, setelah semua
   required check benar-benar hijau (urutan ini eksplisit di `03-ci.md:345-346`).
8. Nightly suite + coverage floor dari run hijau pertama.

## 9. Risiko

| Risiko | Dampak | Mitigasi |
|---|---|---|
| Nim cold compile + test > 15 m | job merah karena waktu | ukur dulu; shard per modul; nimcache (§1.2) |
| nimcache tidak hit (path-dependent) | CI lambat, bukan salah | `--nimcache` di dalam workspace; tanpa asumsi hit |
| `nimble install` mengambang (tanpa lock) | biner beda dari yang diuji | pin eksak + `deps-check` + nightly drift |
| Rollback tidak pernah diuji | insiden = tebak-tebakan | langkah 5 rehearsal wajib, bukan opsional |
| Rehearsal ≠ quadlet/systemd | bug unit lolos ke prod | staging sebelum prod; unit di-`cmp` dengan server |
| Ruleset aktif sebelum check stabil | semua PR terblokir | aktifkan terakhir (§8.7) |
| Repo publik + IP/secret | kebocoran permanen (riwayat) | gitleaks full history, placeholder, pre-commit |
| 8 job × 15 m pada akun gratis | antrean panjang | pisah path, cache, jangan naikkan timeout |
