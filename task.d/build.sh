#!/bin/sh
. "$(dirname "$0")/lib.sh"

require_cmd nim

out_dir="$REPO_ROOT/.cache/$WORKTREE/bin"
mkdir -p "$out_dir"

nim_build -o:"$out_dir/majadu-api" "$(api_entrypoint)"
printf 'build: %s\n' "$out_dir/majadu-api"
