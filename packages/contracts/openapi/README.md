# OpenAPI contract and its gate

Two hand-written specs, one generated contract, and a fingerprint that makes any
contract change reviewable:

| File | Owner | Kind |
|---|---|---|
| `core.yaml` | T-008a | hand-written (JSON syntax, valid YAML) |
| `community.yaml` | T-008b | hand-written (JSON syntax, valid YAML) |
| `api.yaml` | generator | merged document, do not edit |
| `CONTRACT.sha256` | generator | fingerprint, do not edit |
| `apps/api/src/routes_gen.nim` | generator | Nim route skeletons, do not edit |
| `packages/web-client/src/api.ts` | generator | TypeScript client, do not edit |

`core.yaml` and `community.yaml` are JSON documents with a `.yaml` extension so
`tools/contract-gen` can parse them with `std/json` instead of pulling a YAML
dependency. Both together define exactly **76 operations**; the generator fails
on any other count or on a duplicate `operationId`.

## Fingerprint

`CONTRACT.sha256` is a deterministic text record written by
`tools/contract-gen/gen.nim`:

```text
format 1
operations 76
spec packages/contracts/openapi/community.yaml <sha256 of the file bytes>
spec packages/contracts/openapi/core.yaml <sha256>
generated apps/api/src/routes_gen.nim <sha256>
generated packages/contracts/openapi/api.yaml <sha256>
generated packages/web-client/src/api.ts <sha256>
```

`tools/contract-gen/check.nim` recomputes every digest from the tree and fails on
any difference, so a stale record cannot be merged unnoticed.

## Changing the contract

1. Edit `core.yaml` and/or `community.yaml` only. Do not touch `api.yaml`,
   `routes_gen.nim`, `api.ts`, or `CONTRACT.sha256` by hand.
2. Run `./task contract-gen`. It rewrites the merged document, both generated
   outputs, and `CONTRACT.sha256`.
3. Run `./task contract-check`. Both the fingerprint and the generated files must
   match the specs.
4. Commit the spec edit **together with** the regenerated files and the
   `CONTRACT.sha256` diff. That diff is the record of the contract change: it
   names the file that changed and its new digest, which is what reviewers use to
   spot an unannounced contract edit.
5. Note the intent in the task backlog row or changelog when the change is
   behavioural (a new operation, a changed status code, a new field), so the
   review has prose next to the digest.

Never complete a spec edit with `git checkout -- packages/contracts/openapi/CONTRACT.sha256`
or by editing the fingerprint to silence the gate: the failure means the tree and
the record disagree.

## Gates

- `./task contract-gen --check` — the generated files match the generator.
- `./task contract-check` — added by T-016; runs the fingerprint check, then the
  generator check. It is part of `./task ci` and of the `contract` job in
  `.github/workflows/ci.yml`.
- `./task check` stays database-free and does not run either of them.
