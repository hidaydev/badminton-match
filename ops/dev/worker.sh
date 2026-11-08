#!/bin/sh
# Disposable database helper for the test runner (QA-06).
#
#   ops/dev/worker.sh provision <base> <n>
#       Build <base>_<n>_seed from bm2_template (migrations and seeds, once per
#       worker), then make <base>_<n> as a copy. Repeating it rebuilds the seed,
#       so a new migration lands here without a manual step.
#   ops/dev/worker.sh seed <name>
#       Build <name> from bm2_template alone. This is what `./task test` does
#       once per run when WORKERS is unset.
#   ops/dev/worker.sh fresh <seed> <live>
#       Replace <live> with a copy of <seed>. This is the per-file reset.
#   ops/dev/worker.sh drop <db>...
#   ops/dev/worker.sh dsn <db>
#       Print the DSN that names <db> with the caller's credentials.
#
# Environment:
#   MAJADU_PG_DSN        the database the caller prepared. Only its user, host,
#                        port and options are reused; it is never written here.
#   MAJADU_PG_ADMIN_DSN  a maintenance database. Defaults to MAJADU_PG_DSN with
#                        its database replaced by `postgres`.
#
# The logic lives in task.d/lib.sh so the runner and this entry point cannot
# drift; this script is the way to reach it by hand.
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WORKTREE=worker
NIMCACHE_CHECK="$REPO_ROOT/.cache/$WORKTREE/check"
NIMCACHE_BUILD="$REPO_ROOT/.cache/$WORKTREE/build"
export REPO_ROOT WORKTREE NIMCACHE_CHECK NIMCACHE_BUILD
mkdir -p "$NIMCACHE_CHECK" "$NIMCACHE_BUILD"

. "$REPO_ROOT/task.d/lib.sh"

usage() {
  printf 'usage: %s <provision|seed|fresh|drop|dsn> ...\n' "$0" >&2
  exit 2
}

command=${1:-}
[ -n "$command" ] || usage
shift

case "$command" in
  provision)
    [ "$#" -eq 2 ] || fail "usage: worker.sh provision <base> <n>"
    worker_database "$1" "$2"
    printf 'worker %s: %s_%s (seed %s_%s_seed)\n' "$2" "$1" "$2" "$1" "$2"
    ;;
  seed)
    [ "$#" -eq 1 ] || fail "usage: worker.sh seed <name>"
    database_seed "$1"
    printf 'seed: %s\n' "$1"
    ;;
  fresh)
    [ "$#" -eq 2 ] || fail "usage: worker.sh fresh <seed> <live>"
    database_clone "$1" "$2"
    ;;
  drop)
    [ "$#" -ge 1 ] || fail "usage: worker.sh drop <db>..."
    database_drop "$@"
    ;;
  dsn)
    [ "$#" -eq 1 ] || fail "usage: worker.sh dsn <db>"
    dsn_with_database "${MAJADU_PG_DSN:-}" "$1"
    ;;
  *)
    fail "unknown command: $command (provision, seed, fresh, drop, dsn)"
    ;;
esac