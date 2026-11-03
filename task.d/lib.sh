#!/bin/sh
# Shared helpers for task.d/*.sh. Sourced, never executed directly.
set -eu

: "${REPO_ROOT:?REPO_ROOT is not set; run through ./task}"
: "${WORKTREE:?WORKTREE is not set; run through ./task}"
: "${NIMCACHE_CHECK:?NIMCACHE_CHECK is not set; run through ./task}"
: "${NIMCACHE_BUILD:?NIMCACHE_BUILD is not set; run through ./task}"

BUILD_FLAGS="-d:release --opt:speed --stackTrace:on --lineTrace:on --threads:on --mm:atomicArc"
CHECK_FLAGS="--hints:off"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

nim_check() {
  nim check $CHECK_FLAGS --nimcache:"$NIMCACHE_CHECK" "$@"
}

nim_build() {
  nim c $CHECK_FLAGS $BUILD_FLAGS --nimcache:"$NIMCACHE_BUILD" "$@"
}

test_binary() {
  _file=$1
  _name=$(printf '%s' "$_file" | sed "s|$REPO_ROOT/||" | tr '/.' '__')
  mkdir -p "$NIMCACHE_BUILD/bin"
  printf '%s\n' "$NIMCACHE_BUILD/bin/$_name"
}

nim_run() {
  _file=$1
  shift
  nim c -r $CHECK_FLAGS --nimcache:"$NIMCACHE_BUILD" \
    -o:"$(test_binary "$_file")" "$_file" "$@"
}

nim_run_check() {
  _file=$1
  shift
  nim c -r $CHECK_FLAGS --nimcache:"$NIMCACHE_CHECK" \
    -o:"$(test_binary "$_file")" "$_file" "$@"
}

list_test_files() {
  # Unit tests always run. Integration tests only when INTEGRATION=1.
  find "$REPO_ROOT/apps" "$REPO_ROOT/modules" "$REPO_ROOT/shared" "$REPO_ROOT/tools" \
    -name '*_test.nim' -type f 2>/dev/null | sort | while IFS= read -r file; do
      case "$file" in
        */tests/integration/*)
          [ "${INTEGRATION:-0}" = "1" ] && printf '%s\n' "$file"
          ;;
        *)
          printf '%s\n' "$file"
          ;;
      esac
    done
}

api_entrypoint() {
  printf '%s\n' "$REPO_ROOT/apps/api/src/main.nim"
}
