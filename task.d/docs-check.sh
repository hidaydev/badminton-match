#!/bin/sh
# Fail when a public count no longer matches the artefact it describes.
#
#   ./task docs-check
#
# Only mechanical claims are checked: the number of migration files, the number
# of contract operations in CONTRACT.sha256, and the totals quoted in README.md
# and docs/handbook/current-status.md. Prose claims are not parseable, so this
# does not pretend to review them.
set -eu
. "$(dirname "$0")/lib.sh"

problems=0
report() {
  printf 'docs-check: %s\n' "$*" >&2
  problems=$((problems + 1))
}

migrations=$(find "$REPO_ROOT/db/migrations" -maxdepth 1 -type f -name '*.sql' | wc -l | tr -d ' ')
contract="$REPO_ROOT/packages/contracts/openapi/CONTRACT.sha256"
[ -f "$contract" ] || fail "missing $contract"
operations=$(sed -n 's/.*operations \([0-9][0-9]*\).*/\1/p' "$contract" | head -1)
[ -n "$operations" ] || fail "$contract has no 'operations <n>' line"

check_count() {
  file=$1 pattern=$2 expected=$3 label=$4
  [ -f "$REPO_ROOT/$file" ] || { report "$file is missing"; return 0; }
  claimed=$(grep -oE "$pattern" "$REPO_ROOT/$file" | head -1 | grep -oE '[0-9]+' | head -1)
  if [ -z "$claimed" ]; then
    report "$file no longer quotes a $label count"
  elif [ "$claimed" != "$expected" ]; then
    report "$file says $claimed $label, the artefact has $expected"
  fi
}

check_count "README.md" '[0-9]+ migrations' "$migrations" "migrations"
check_count "README.md" '[0-9]+ operations' "$operations" "operations"
check_count "docs/handbook/current-status.md" '[0-9]+ migrations' "$migrations" "migrations"
check_count "docs/handbook/current-status.md" '[0-9]+ operations' "$operations" "operations"

if [ "$problems" -ne 0 ]; then
  printf 'docs-check: %d problem(s)\n' "$problems" >&2
  exit 1
fi
printf 'docs-check: ok (%s migrations, %s operations)\n' "$migrations" "$operations"
