#!/usr/bin/env sh
# badminton test hook for `./task gate-full`: the whole `./task ci` — static gates, release
# build, every suite against its own freshly copied database. It needs a local Postgres
# (MAJADU_PG_DSN); `gate` already ran the static gates, this is the release gate.
set -eu
cd "$(dirname "$0")/.."

sh ./task ci
