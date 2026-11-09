#!/bin/sh
# Fail when a public count no longer matches the artefact it describes.
#
#   ./task docs-check
#
# Only mechanical claims are checked: the number of migration files, the number
# of contract operations in CONTRACT.sha256, and the totals quoted in README.md
# and docs/handbook/current-status.md. Prose claims are not parseable, so this
# does not pretend to review them.
#
# Drift that has already shipped is checked by exact string: a sentence that
# contradicted the configuration was fixed four times and each time came back.
# The list is short on purpose; a rule that fires on harmless prose teaches
# people to ignore the gate.
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

# OPS-25: statements that contradicted the running configuration.
check_absent() {
  file=$1 text=$2 label=$3
  [ -f "$REPO_ROOT/$file" ] || { report "$file is missing"; return 0; }
  if grep -qF -- "$text" "$REPO_ROOT/$file"; then
    report "$file still says '$text' ($label)"
  fi
}

check_absent "docs/ops/operations.md" "stored in a CI secret" \
  "the GHCR read token lives on the VPS, not in a CI secret"
check_absent "docs/ops/operations.md" "The deploy log grows without rotation" \
  "the deploy log is rotated every ten minutes"
check_absent "docs/ops/operations.md" "Logs are rotated by majadu-rotate-log.timer (rename" \
  "rotation also gzips and checks free disk"

# The release order is a control, not prose: the tag must reach the registry
# before main reaches the deploy webhook, or the deploy resolves no digest.
check_release_order() {
  file="docs/ops/release.md"
  [ -f "$REPO_ROOT/$file" ] || { report "$file is missing"; return 0; }
  tag_line=$(grep -n 'git push origin refs/tags/' "$REPO_ROOT/$file" | head -1 | cut -d: -f1)
  main_line=$(grep -n 'git push origin main' "$REPO_ROOT/$file" | head -1 | cut -d: -f1)
  if [ -z "$tag_line" ] || [ -z "$main_line" ]; then
    report "$file no longer shows the tag-then-main push commands"
  elif [ "$tag_line" -ge "$main_line" ]; then
    report "$file pushes main before the tag; the deploy would run without an image"
  fi
}

check_release_order

if [ "$problems" -ne 0 ]; then
  printf 'docs-check: %d problem(s)\n' "$problems" >&2
  exit 1
fi
printf 'docs-check: ok (%s migrations, %s operations)\n' "$migrations" "$operations"
