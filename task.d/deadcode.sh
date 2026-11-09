#!/bin/sh
# SQ-01: a second, quiet `nim check` pass for the finding classes the fast gate
# hides. `nim_check` in lib.sh runs with `--hints:off` so its output stays
# readable, but `XDeclaredButNotUsed` is a hint: dead code was invisible by
# construction. This pass keeps only the defect classes and fails on anything
# the reviewed allowlist does not name.
#
# The allowlist is `tools/archcheck/allowlist_deadcode.txt`, one `path:name` per
# line, with a reason above it.
. "$(dirname "$0")/lib.sh"

require_cmd nim
require_cmd mktemp

categories='XDeclaredButNotUsed|UnusedImport|ShadowIdent|CaseTransition|UserWarning'
allowlist="$REPO_ROOT/tools/archcheck/allowlist_deadcode.txt"

log=$(mktemp "${TMPDIR:-/tmp}/majadu-hint.XXXXXX")
bad=0
for entry in "$(api_entrypoint)" "$REPO_ROOT"/tools/*/main.nim; do
  code=0
  nim check --hints:on --warnings:on --nimcache:"$NIMCACHE_CHECK" \
    "$entry" >"$log" 2>&1 || code=$?
  if [ "$code" -ne 0 ]; then
    cat "$log" >&2
    rm -f "$log"
    fail "deadcode: nim check failed for ${entry#"$REPO_ROOT"/}"
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    file=$(printf '%s' "$line" | sed 's/(.*//')
    name=$(printf '%s' "$line" | sed -n "s/.*'\([^']*\)'.*/\1/p" | head -1)
    key="${file#"$REPO_ROOT"/}:$name"
    if [ -f "$allowlist" ] && grep -Fxq "$key" "$allowlist"; then
      printf 'deadcode: allowed %s\n' "$key"
    else
      printf 'deadcode: %s\n' "$line" >&2
      bad=$((bad + 1))
    fi
  done <<EOF
$(grep -E "\[($categories)\]" "$log" || true)
EOF
done
rm -f "$log"

[ "$bad" -eq 0 ] ||
  fail "deadcode: $bad finding(s) are not in ${allowlist#"$REPO_ROOT"/}"
printf 'deadcode: %s\n' \
  "no unallowlisted dead declaration, unused import, shadow or case transition"
