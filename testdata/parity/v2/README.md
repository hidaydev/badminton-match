# Parity corpus — v2 (Nim)

One or more cases per contract operation in `apps/api/src/routes_gen.nim` (75
operations, 143 cases), recorded
against the real Nim server, plus a fixture-state fingerprint. Together they are
the executable form of the frozen contract: a response that changes shape,
status or the rows it leaves behind makes `./task parity v2 verify` fail.

## Layout

- `<name>.json` — one case: `route` (the operation id), `request` (method, path,
  headers, body) and `expect` (status, canonicalised body). A 204 declares
  `"emptyBody": true` instead of pretending the empty body is a payload.
- `cases.tsv` — the request table, replayed in file order because the corpus is
  stateful. Six tab-separated fields: `name`, `operationId`, `method`, `path`,
  headers (`;`-separated, `-` for none), body (`-` for none, `@file` for a body
  file next to this table).
- `fixture.sql` — deterministic fixture: two communities, an owner, an admin, a
  host, a member, an outsider and an applicant; four players; a locked session
  with a played game; a draft session; a deletable draft; a completed classic
  tournament with a scored match; a completed team tournament; a signed-off
  rating source; a pending claim, join request and invite.
- `bodies/tournament_create.json` — the full 16-pair classic body used by
  `createTournament`.
- `state.json` — one column projection per table, each with an explicit
  `ORDER BY`, plus the row count and SHA-256 of the canonical JSON. The
  `selftest` block names the mutation the tool applies and rolls back.
- `MANIFEST.sha256` — checksums of every JSON file in this directory.

## Commands

```
./task parity v2 verify   # end to end on a disposable database (see below)
./task parity v2 lint     # manifest + 75/75 operations + 4xx ratio + invariants
./task parity v2 reset    # rebuild fixture.sql only
./task parity v2 record   # reset, capture cases.tsv, snapshot state, manifest
./task parity v2 replay   # replay cases.tsv in order against a running server
./task parity v2 state    # compare state.json and run the mutation self-test
```

`verify` creates `bm2_parity_v2` when it is missing, migrates and seeds it,
rebuilds the fixture, boots the API on `http://127.0.0.1:18092`, replays every
case, then compares the state digest and runs the self-test. It refuses to point
at `bm2_dev`, `bm2_template`, `bm2_r0` or `postgres`.

Environment:

| Variable | Default | Meaning |
|---|---|---|
| `PARITY_V2_DSN` | `postgresql://$(whoami)@127.0.0.1:5432/bm2_parity_v2` | disposable database |
| `PARITY_V2_BASE` | `http://127.0.0.1:18092` | API origin |
| `SHARE_CODE_KEYS` | local fixture key | share-link keyring |
| `SHARE_CODE_ACTIVE_KEY_ID` | `1` | active key id |

`record` expects a server already running against a reset fixture; the v1
recording instructions apply, with `PARITY_V2_DSN` and `PARITY_V2_BASE` instead.

## Fixture state

The share link is inserted by the tool, not by SQL: its ciphertext must come from
the real keyring. The fixed code is
`5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a`, bound to session
`40000000-0000-4000-8000-000000000001` in community
`10000000-0000-4000-8000-000000000001`.

The session tokens are fixed values (`parity-admin-token`, `parity-host-token`,
…) so the cookie in `cases.tsv` is stable; only the SHA-256 is stored, exactly
as the application does it.

## Determinism

`tools/parity/normalizer.nim` masks, in both recording and replay:

- UUIDs, RFC 3339 timestamps and PostgreSQL text timestamps;
- 128-bit share codes and 256-bit websocket tickets (hex);
- OIDC `state`, `nonce`, `code_challenge`, `redirect_uri` and the provider
  origin of the authorize URL;
- the `asOf` day on the ranking board.

Everything else is compared byte for byte. `state.json` excludes timestamps and
generated ids on purpose; it projects natural keys and values with an explicit
order, and every projection must return at least one row.

## Divergences

A case that intentionally differs from the v1 corpus carries both `expectNim`
(the Nim response) and `expectedDivergence` (`reason`, `owner`). The lint fails
when one is present without the other. The currently recorded corpus has no
intentional divergence; gaps seen while recording are reported in the task
notes instead of being frozen into a 5xx expectation.
