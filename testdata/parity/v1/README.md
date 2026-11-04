# Parity corpus — v1 (Go, retired)

Golden HTTP captures of the v1 API, one case per route it declared. The corpus
is the executable specification the Nim rewrite was diffed against, and it stays
frozen now that the Go tree is gone (T-082).

## Layout

- `<name>.json` — one case: `route`, `request` (method, path, headers, body) and
  `expect` (status, canonicalised body). Every case asserts both status and body.
- `cases.tsv` — the request table the corpus was recorded from. Tab-separated:
  `name`, `route template`, `method`, `path`, `header` (`-` for none), `body`
  (`-` for none). Lines starting with `#` are ignored.
- `routes.txt` — the 48 route templates `registerRoutes` declared, frozen from
  the Go source before it was removed. `./task parity verify` compares it with
  the corpus; it is the file to edit if a route is ever added or dropped here.
- `MANIFEST.sha256` — SHA-256 of every case, checked by `./task parity verify`.

## Commands

```
./task parity record     # re-record every case from cases.tsv, then rewrite the manifest
./task parity record --name healthz --path /healthz --route "GET /healthz"
./task parity replay     # replay all cases against PARITY_BASE
./task parity replay healthz sessions_get
./task parity verify     # manifest checksums + route coverage + 4xx ratio
```

`PARITY_BASE` defaults to `http://127.0.0.1:8091`.

`verify` needs nothing but the files and the Nim toolchain, so it runs anywhere.
`record` and `replay` need a live v1 server; since the source is gone, use the
archived image instead of rebuilding it:

```
./task dev-v1
docker run --rm -p 8091:8080 \
  -e DATABASE_URL=postgresql://$(whoami)@host.docker.internal:5432/bm_v1_dev \
  -e MAJADU_DB_SCHEMA=bm -e MAJADU_ENV=dev -e MAJADU_ADMIN_TOKEN=test-admin \
  localhost/majadu-api:v1-final
```

`test-admin` is the local development token only; it is not a secret. Podman
works the same way with `--network=host` and `127.0.0.1` in the DSN.

## Determinism

Cases must produce the same bytes on every run:

- UUIDs, RFC 3339 timestamps and `/s/<code>` share codes are masked by
  `tools/parity/normalizer.nim`.
- Non-JSON payloads (currently `/metrics`) additionally mask every number,
  because counters and durations change between runs.
- Only error paths are exercised for mutating routes (`POST`, `PUT`, `PATCH`,
  `DELETE`), so replaying never changes the database.
- Session `v1demo0002` is locked by the server's start-up auto-lock pass, which
  makes recordings depend on boot order rather than a fresh database, so the
  corpus is recorded after the server is up.

`./task parity verify` fails if a case is added, removed or edited without
re-recording, if a route in `routes.txt` has no case, if any `expect` is empty,
or if fewer than 40% of cases assert a status of 400 or above.
