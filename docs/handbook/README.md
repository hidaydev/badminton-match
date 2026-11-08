# Handbook

The documents in this folder describe the **v2 runtime** (Nim backend + React
frontend) that exists in the repo today.

## Start Here

- [current-status.md](current-status.md): repo condition, testing, infrastructure
- [product-overview.md](product-overview.md): product description and feature areas
- [architecture.md](architecture.md): Nim/React architecture, contracts, auth, WebSocket

## Reference

- [data-model.md](data-model.md): `bm2` database schema, tables, constraints, config
- [features-and-routes.md](features-and-routes.md): web routes and 75 API operations
- [scoring-presets.md](scoring-presets.md): scoring preset rules and numbers
- [deps-format.md](deps-format.md): `deps.lock` format and pinning rules
- [roadmap.md](roadmap.md): what already exists and the next priorities
- [design-system.md](../design-system.md): colors, typography, components, tokens

## Related

- [`../ops/`](../ops/): releases, operations, OAuth, cutover
- [`../ops/rc-environment.md`](../ops/rc-environment.md): RC environment
- [`../decisions.md`](../decisions.md): architecture decision records
- Historical documents (rewrite plan, Go v1 ADRs, old design spec) are in git
  history: `git log --all -- docs/`.