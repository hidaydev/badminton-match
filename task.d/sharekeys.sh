#!/bin/sh
# Key tool for session share links. The only documented entry point: it issues a
# new key for SHARE_CODE_KEYS and re-encrypts links that are still sealed with a
# retired one. See tools/sharekeys/main.nim for the commands.
. "$(dirname "$0")/lib.sh"

require_cmd nim

exec nim c -r --hints:off --nimcache:"$NIMCACHE_BUILD/sharekeys" \
  -o:"$NIMCACHE_BUILD/bin/majadu-sharekeys" "$REPO_ROOT/tools/sharekeys/main.nim" "$@"
