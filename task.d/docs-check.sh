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
# The design system document is the exception: DS-26 asks for a version and a
# review date a machine can hold to, so its two header lines are checked here.
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
# The three documents a reader lands on when they ask "how big is the API" quoted
# 75 while the artefact said 76, and nothing compared them. The count is checked
# wherever it is written down.
check_count "docs/handbook/architecture.md" '[0-9]+ operations' "$operations" "operations"
check_count "docs/handbook/product-overview.md" '[0-9]+ operations' "$operations" "operations"
check_count "docs/test-plan.md" '[0-9]+ operations' "$operations" "operations"

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

# ISO-19: a requirement whose evidence was deleted is an unmet requirement.
# Every code span that looks like a path in the register has to resolve.
check_requirement_paths() {
  file="docs/handbook/requirements.md"
  [ -f "$REPO_ROOT/$file" ] || { report "$file is missing"; return 0; }
  refs=$(grep -o '`[A-Za-z0-9_./-]*`' "$REPO_ROOT/$file" | tr -d '`' | sort -u)
  for ref in $refs; do
    case "$ref" in
      */*.nim|*/*.ts) ;;
      *) continue ;;
    esac
    [ -f "$REPO_ROOT/$ref" ] ||
      report "$file references $ref, which does not exist"
  done
}

check_requirement_paths

# ISO-21: the prerequisites table is a copy of three files, so a copy is what
# drifts. The versions are read from their source and the table has to agree.
check_tool_versions() {
  file="CONTRIBUTING.md"
  [ -f "$REPO_ROOT/$file" ] || { report "$file is missing"; return 0; }
  node_version=$(grep -E '^[[:space:]]*node-version:' \
    "$REPO_ROOT/.github/workflows/ci.yml" |
    head -1 | grep -oE '[0-9]+([.][0-9]+)*' | head -1)
  pnpm_version=$(grep -oE '"packageManager":[[:space:]]*"pnpm@[0-9.]+"' \
    "$REPO_ROOT/package.json" | head -1 | sed 's/.*pnpm@//;s/"$//')
  if [ -z "$node_version" ] || [ -z "$pnpm_version" ]; then
    report "cannot read the Node or pnpm version from ci.yml and package.json"
    return 0
  fi
  grep -q "^| Node.js | $node_version |" "$REPO_ROOT/$file" ||
    report "$file does not state Node.js $node_version from ci.yml"
  grep -q "^| pnpm | $pnpm_version |" "$REPO_ROOT/$file" ||
    report "$file does not state pnpm $pnpm_version from package.json"
}

check_tool_versions

# DS-26: this document is cited by several findings, and a document that cannot
# say which version it describes or when a person last read it is a copy of a
# memory. The date is the part a machine can hold to, so the gate fails 90 days
# after the last review: the review happens because the build is red, not because
# someone remembered.
MAX_DESIGN_REVIEW_AGE_DAYS=90

date_epoch() {
  # BSD date (macOS) and GNU date (the runner) share no flags, so both are tried
  # and an empty answer is the caller's signal that the input did not parse.
  date -j -f "%Y-%m-%d" "$1" "+%s" 2>/dev/null ||
    date -d "$1 00:00:00" "+%s" 2>/dev/null ||
    printf ''
}

check_design_system_version() {
  file="docs/design-system.md"
  if [ ! -f "$REPO_ROOT/$file" ]; then
    report "$file is missing"
    return 0
  fi
  version=$(sed -n 's/^Version: *//p' "$REPO_ROOT/$file" | head -1)
  reviewed=$(sed -n 's/^Last reviewed: *//p' "$REPO_ROOT/$file" | head -1)
  if [ -z "$version" ]; then
    report "$file has no 'Version:' line"
  elif ! printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    report "$file Version '$version' is not X.Y.Z"
  fi
  if [ -z "$reviewed" ]; then
    report "$file has no 'Last reviewed: YYYY-MM-DD' line"
    return 0
  fi
  _epoch=$(date_epoch "$reviewed")
  if [ -z "$_epoch" ]; then
    report "$file Last reviewed '$reviewed' is not a YYYY-MM-DD date"
    return 0
  fi
  _now=$(date +%s)
  if [ "$_epoch" -gt "$_now" ]; then
    report "$file Last reviewed $reviewed is in the future"
    return 0
  fi
  _age=$(( (_now - _epoch) / 86400 ))
  if [ "$_age" -gt "$MAX_DESIGN_REVIEW_AGE_DAYS" ]; then
    report "$file was last reviewed $reviewed, $_age days ago (limit $MAX_DESIGN_REVIEW_AGE_DAYS); review it and bump the date"
  fi
}

check_design_system_version

if [ "$problems" -ne 0 ]; then
  printf 'docs-check: %d problem(s)\n' "$problems" >&2
  exit 1
fi
printf 'docs-check: ok (%s migrations, %s operations)\n' "$migrations" "$operations"
