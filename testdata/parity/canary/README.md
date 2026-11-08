# Parity canary

One case whose expected body is deliberately wrong. `./task parity v2 canary`
replays it against a freshly booted API and **passes only when replay rejects
it**: if the comparator ever stops comparing bodies, the canary starts passing
and the command fails instead.

The case targets `/healthz` because it needs no fixture row, so the canary
cannot drift when the seeded data changes. The corpus in `../v2` stays the
regression pin; this directory is the oracle's own test.

Runs in CI with the parity job (`.github/workflows/nightly.yml`), never in
`./task check`: it needs a database and a listening API.
