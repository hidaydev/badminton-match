# Docs

Runtime, operations, and process documentation as it stands today. All files use
lowercase and hyphens; `README.md` is the only exception.

## Start Here

- [`../HANDOVER.md`](../HANDOVER.md): state of the release branch when work changed hands (2026-11-10)
- [`handbook/README.md`](handbook/README.md): index handbook
- [`handbook/current-status.md`](handbook/current-status.md): current condition, infrastructure, testing
- [`handbook/architecture.md`](handbook/architecture.md): FE/BE architecture, WebSocket, PWA
- [`handbook/data-model.md`](handbook/data-model.md): v2 database schema (`bm2`) and API data shape

## Directory Map

| Folder | Contents |
|---|---|
| `handbook/` | runtime: product, architecture, schema, routes, status, roadmap, scoring presets, `deps.lock` format |
| `ops/` | access and incidents, releases, OAuth, cutover, pre-push hook, RC environment |
| `docs/` root | [`decisions.md`](decisions.md), [`design-system.md`](design-system.md), [`privacy.md`](privacy.md) |

## Conventions

- One fact, one place: schema in `data-model.md`, status and test numbers in
  `current-status.md`, priorities in `roadmap.md`.
- Everything published here is written in English, including internal notes. Code,
  comments, and commit messages follow the same rule.
- Chat with the owner stays in Indonesian.
- Documents describing an old era or a plan that is already finished are not
  kept in the working tree. Get them from history: `git log --all -- docs/`.