<div align="center">

# 🏸 Majadu

**Run a badminton club from one screen: sessions, scores, tournaments, and rank points.**

[![CI](https://github.com/hidaydev/badminton-match/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/hidaydev/badminton-match/actions/workflows/ci.yml)
[![Coverage gate](https://github.com/hidaydev/badminton-match/actions/workflows/coverage.yml/badge.svg?branch=main)](https://github.com/hidaydev/badminton-match/actions/workflows/coverage.yml)
![Release](https://img.shields.io/badge/Release-2.0.3-brightgreen?style=flat-square)
![React](https://img.shields.io/badge/React-19-61DAFB?style=flat-square&logo=react&logoColor=black)
![TypeScript](https://img.shields.io/badge/TypeScript-5.8%20%2F%206-3178C6?style=flat-square&logo=typescript&logoColor=white)
![Nim](https://img.shields.io/badge/Nim-2.4-FFE953?style=flat-square&logo=nim&logoColor=black)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-18-4169E1?style=flat-square&logo=postgresql&logoColor=white)
![Tailwind CSS](https://img.shields.io/badge/Tailwind-4-38BDF8?style=flat-square&logo=tailwindcss&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-2ea44f?style=flat-square)

<p align="center">
  <a href="#-overview">Overview</a> •
  <a href="#-key-features">Features</a> •
  <a href="#%EF%B8%8F-architecture--stack">Architecture</a> •
  <a href="#-repository-layout">Layout</a> •
  <a href="#-local-development">Quickstart</a> •
  <a href="#-quality-gates--testing">Gates</a> •
  <a href="#%EF%B8%8F-versioning--release-sop">Release SOP</a> •
  <a href="#-deployment">Deployment</a> •
  <a href="#-documentation">Docs</a>
</p>

</div>

---

## ⚡ Overview

**Majadu** is a mobile-first, multi-community Progressive Web App designed specifically for recreational and club badminton. It handles the entire lifecycle of a badminton community: planning match nights, allocating courts, recording scores with optimistic concurrency, running knockout and team tournaments, and automatically computing rolling 12-week rank points.

| Metric | Specification |
|---|---|
| **Contract** | **76 operations** defined in OpenAPI, generating type-safe Nim server routes and TypeScript web clients |
| **Database** | **56 migrations** on PostgreSQL 18, strictly keyed and scoped by `community_id` |
| **Domain Architecture** | 9 cohesive modules: account, community, player, session, tournament, rating, achievement, share, platform |
| **Test Quality Gates** | 1,524 Nim test cases across 140 suites, 144 parity replays, 170 end-to-end browser scenarios |
| **Security Baseline** | First-party `HttpOnly` session cookies, signed Cosign container images, zero credentials in client state |

---

## ✨ Key Features

| Domain | Capabilities |
|---|---|
| **🏸 Sessions & Courts** | Real-time courtside management, participant check-in, dynamic scheduling, per-game scoring, absent/skip/swap mechanics, and match lock/unlock. All mutations enforce `If-Match` (OCC) and `Idempotency-Key`. |
| **🏆 Tournaments** | Classic draws (16 pairs → 4 groups → knockout) and team tournaments (6 teams × 6 tiers → group stages + finals, 3 rubbers per match), computed and rendered client-side. |
| **📈 Dynamic Ratings** | Rolling 12-week window calculation based on a player's best 10 entries per session or tournament, weighted by opponent tier ratings across 8 sticky skill tiers. |
| **🎖️ Achievements** | Automated, idempotent badge evaluation computed from historic match records and tournament achievements. |
| **👥 Player Management** | Canonical player identities, alias registries, gender categorization, sticky skill tiers, and verified claim/merge workflows with audit logging. |
| **🏢 Multi-Tenancy** | Single deployment serving multiple clubs with slugged routes, hierarchical roles (`member`, `host`, `admin`), join requests, and per-club configuration overrides. |
| **🔗 Safe Sharing** | Cryptographically sealed share links (HMAC + encrypted payload), public spectator views, and automatic share-code redaction in server access logs. |
| **🎨 Social Canvas** | Client-side generation of high-resolution Instagram feed posts (1080×1350) and stories (1080×1920) for session summaries and tournament podiums. |
| **⚡ Live Updates** | Low-latency in-memory WebSocket multiplexing per session and share ticket, with automated 5s HTTP fallback. |

---

## 🏗️ Architecture & Stack

Majadu follows Clean Architecture principles with strict boundary enforcement:

```text
 ┌────────────────────────────────────────────────────────┐
 │                   Client Layer (PWA)                   │
 │   React 19 • TypeScript • Tailwind CSS 4 • Vite 8      │
 └───────────────────────────┬────────────────────────────┘
                             │  HTTP / OpenAPI & WebSocket
 ┌───────────────────────────▼────────────────────────────┐
 │                  Delivery & API Layer                  │
 │          Nim 2.4 • Mummy HTTP & WebSocket Server       │
 ├────────────────────────────────────────────────────────┤
 │                      Domain Core                       │
 │  9 Pure Domain Modules (Rules, Entities, Invariants)   │
 ├────────────────────────────────────────────────────────┤
 │                 Shared Platform Library                │
 │    DB Binder • Clock • Logger • Metrics • UUIDv7       │
 └───────────────────────────┬────────────────────────────┘
                             │  SQL / Transactions
 ┌───────────────────────────▼────────────────────────────┐
 │                     Data Layer                         │
 │        PostgreSQL 18 (Multi-tenant Schemas)            │
 └────────────────────────────────────────────────────────┘
```

- **Domain Isolation**: Modules inside `modules/<domain>/` hold business logic and database access. Modules never import HTTP, React, or delivery concerns.
- **Contract-Driven**: `packages/contracts/openapi` is the single source of truth. Generated routes (`routes_gen.nim`) and client interfaces (`packages/web-client/src/api.ts`) are generated via `./task contract-gen`.
- **Zero Hardcoded Configuration**: Business numbers, limits, and scoring parameters reside in `platform.config` and `community.settings`. The static architectural checker (`tools/archcheck`) enforces this continuously.

---

## 📂 Repository Layout

```text
majadu/
├── apps/
│   ├── web/                 # Primary React 19 PWA (Vite, Tailwind 4)
│   ├── scoreboard/          # Dedicated courtside scoring kiosk PWA
│   └── api/                 # High-performance Nim API server
├── modules/                 # Pure domain logic:
│                            #   account, community, player, session,
│                            #   tournament, rating, achievement, share, platform
├── shared/platform-lib/     # Core primitives: db, clock, log, metrics, uuidv7
├── packages/
│   ├── contracts/openapi/   # OpenAPI contract definitions (core.yaml + community.yaml)
│   └── web-client/          # Auto-generated TypeScript API client
├── db/                      # 56 append-only migrations, seeds, platform config
├── ops/                     # Podman Quadlet, Caddy reverse-proxy, backup, restore
├── tools/                   # dbtools, contract-gen, archcheck, parity, release
├── e2e/                     # Playwright test suites (a11y, visual, multi-browser)
├── testdata/                # Parity test corpora (v1 golden, v2 live)
├── docs/                    # Architecture, data model, runbooks, design system
├── task                     # Single unified project dispatcher (`./task help`)
└── package.json             # Root pnpm monorepo configuration
```

---

## 🚀 Local Development

### Prerequisites
- **Nim** 2.4+
- **Node.js** 22+ & **pnpm** 10+
- **PostgreSQL** 18 (e.g. containerized on `127.0.0.1:5432`)

### Quickstart
1. **Prepare the database:**
   ```bash
   ./task dev-db     # Create dev roles and databases
   ```
2. **Start the API server:**
   ```bash
   ./task dev        # API on http://127.0.0.1:8080 (pass --watch for hot rebuild)
   ```
3. **Start the frontend web application:**
   ```bash
   pnpm dev          # Web on http://localhost:5173
   ```
4. **Bootstrap seed administrator (first-time setup):**
   ```bash
   MAJADU_PG_DSN=postgresql://$(whoami)@127.0.0.1:5432/bm2_dev \
     ./task bootstrap --sub stub-user-1 --email stub@example.com
   ```

---

## ✅ Quality Gates & Testing

All validation runs through the single `./task` dispatcher.

| Command | Target & Description |
|---|---|
| `./task check` | Static analysis: `nim check`, architectural boundary check (`archcheck`), and unit test suites (database-free). |
| `./task test` | Full integration tests against isolated PostgreSQL databases. Supports `--timing` and parallel sharding via `WORKERS=N`. |
| `./task ci` | Composite gate: linting, contract parity, builds, and integration tests. |
| `./task coverage` | Line coverage verification per module, ratcheted against committed baseline JSON metrics. |
| `./task docs-check` | Verifies documentation count parity (**56 migrations**, **76 operations**), link integrity, and release order rules. |
| `./task parity v2 verify` | Golden contract replay: 144 test fixtures confirming binary and payload parity against frozen and live corpora. |
| `./task e2e` | Multi-browser end-to-end tests (iPhone 17 WebKit, POCO F5 Chromium, desktop, and WebSocket). |
| `pnpm check:web` | Web frontend checks: TypeScript compilation, ESLint, Tailwind token validation, and Vitest unit coverage. |

---

## 🏷️ Versioning & Release SOP

Majadu adheres strictly to **SemVer 2.0** derived automatically from **Conventional Commits** via `tools/release`.

### Release Workflow (`./task release`)

```text
 ┌──────────────┐     ┌──────────────────────┐     ┌────────────────────────┐
 │ Commit fixes │ ──> │ ./task release       │ ──> │ ./task release --apply │
 │  feat / fix  │     │ (dry-run inspection) │     │ (sync VERSION & pins)  │
 └──────────────┘     └──────────────────────┘     └───────────┬────────────┘
                                                               │
 ┌─────────────────────────────────────────────────────────────┘
 │
 ├──> 1. git commit -m "chore(release): vX.Y.Z"
 ├──> 2. git push origin HEAD:refs/heads/release/vX.Y.Z (wait for green CI + Coverage)
 ├──> 3. git tag -s vX.Y.Z (SSH-signed & verified)
 └──> 4. PUSH ORDER:
         a) git push origin refs/tags/vX.Y.Z   <-- TAG FIRST (builds & signs GHCR image)
         b) git push origin HEAD:main         <-- MAIN SECOND (triggers VPS deploy)
```

#### Step-by-Step Release Commands

1. **Ensure Clean Working Tree & Verify Conventional Commits:**
   The release tool evaluates commit subjects since the last tag. At least one `feat:` (minor) or `fix:`/`perf:` (patch) commit is required.

2. **Dry Run:**
   ```bash
   ./task release
   ```
   Inspect the computed SemVer bump and generated changelog preview.

3. **Apply Version Bump:**
   ```bash
   ./task release --apply
   ```
   *Automatically updates:*
   - `VERSION`
   - `CHANGELOG.md`
   - `.cache/release/v<version>.md` (release tag notes)
   - `testdata/parity/v2/version.json` (version fixture)
   - `testdata/parity/v2/MANIFEST.sha256` (fixture checksum)

4. **Commit the Release:**
   ```bash
   git add VERSION CHANGELOG.md testdata/parity/v2/
   git commit -m "chore(release): v<version>"
   ```

5. **Push Pre-release Branch to Verify Gates:**
   ```bash
   git push origin HEAD:refs/heads/release/v<version>
   ```
   Wait for GitHub Actions `CI` and `Coverage` jobs to turn green. Release tag verification refuses any commit without a recorded, passing Coverage run (QA-15).

6. **Create and Verify SSH-Signed Tag:**
   ```bash
   git -c gpg.format=ssh -c user.signingkey=~/.ssh/id_ed25519.pub \
     tag -s -F .cache/release/v<version>.md v<version>

   # Verify the signature against the repository trust anchor:
   git -c gpg.format=ssh -c gpg.ssh.allowedSignersFile=.github/allowed_signers \
     verify-tag v<version>
   ```

7. **Push to Remote (CRITICAL ORDER):**
   ```bash
   # 1. Push the tag FIRST:
   git push origin refs/tags/v<version>

   # 2. Push main SECOND:
   git push origin HEAD:main
   ```

> [!CAUTION]
> **Why Tag Must Precede Main:**
> Pushing the tag triggers `.github/workflows/release.yml`, which compiles, signs (via `cosign`), and publishes the container image to GHCR. Pushing `main` triggers the VPS deploy webhook (`deploy-vps.sh`), which immediately polls for the signed image. If `main` is pushed first, the VPS polling window will expire before the image finishes building, causing an avoidable deployment timeout.

---

## 🚢 Deployment

- **Web Frontend**: Deployed automatically to Vercel from `apps/web` on pushes to `main`.
- **API Server**: Managed by rootless Podman with systemd Quadlet on the VPS behind Caddy.
- **Image Provenance**: Every release image is pulled by cryptographic digest and validated against `env/cosign.pub` before swapping the `:local` container.
- **Zero-Downtime Rollback**: The previous operational image is preserved as `:prev`, allowing instant fallback on smoke check failures.

---

## 📚 Documentation

Detailed technical documentation lives under [`docs/`](docs/README.md):

| Document | Purpose |
|---|---|
| [`docs/handbook/current-status.md`](docs/handbook/current-status.md) | Living system status: operational stack, contracts, gates, infrastructure |
| [`docs/handbook/architecture.md`](docs/handbook/architecture.md) | Architectural layers, execution pipeline, modules, and domain boundaries |
| [`docs/handbook/data-model.md`](docs/handbook/data-model.md) | Database schemas, multi-tenancy models, and the platform config registry |
| [`docs/handbook/features-and-routes.md`](docs/handbook/features-and-routes.md) | Catalog of frontend routes and 76 backend API operations |
| [`docs/ops/operations.md`](docs/ops/operations.md) | Production operations, log rotation, security access, incident SOPs |
| [`docs/ops/release.md`](docs/ops/release.md) | Comprehensive release runbook, gate criteria, and rollback instructions |
| [`docs/ops/cutover.md`](docs/ops/cutover.md) | Historic migration runbook from v1 Go to v2 Nim |
| [`docs/decisions.md`](docs/decisions.md) | Architectural Decision Records (ADRs) |
| [`docs/privacy.md`](docs/privacy.md) | User data retention, privacy policy, and anonymization procedures |
| [`docs/design-system.md`](docs/design-system.md) | Design tokens, typography, component standards, and dark mode rules |
| [`apps/api/README.md`](apps/api/README.md) · [`apps/web/README.md`](apps/web/README.md) | Per-application developer guides and environment specifications |

---

## 📄 License

Code and original graphics in `apps/web/public` are licensed under the [MIT License](LICENSE). Third-party fonts and assets are subject to their respective licenses detailed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
