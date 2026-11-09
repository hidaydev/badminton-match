#!/bin/sh
# Slowest-test report for the flake register (QA-20).
#
# A red run names one test; it does not say which tests are drifting. This
# prints the slowest Nim suites from the last `--timing` run and the slowest
# Playwright specs from the JSON reporter, so the nightly artifact set carries
# the data a flake review compares across runs. Variability needs at least two
# runs, which is why the nightly keeps the artifacts for its retention window
# instead of only on failure.
. "$(dirname "$0")/lib.sh"

timing_dir="$REPO_ROOT/.cache/$WORKTREE/timing"
found=0
shown=0
if [ -d "$timing_dir" ]; then
  for file in "$timing_dir"/*.tsv; do
    [ -f "$file" ] || continue
    found=1
    printf 'slowest suites in %s\n' "${file#"$REPO_ROOT"/}"
    LC_ALL=C sort -t"$(printf '\t')" -k2,2nr "$file" | head -10 |
      while IFS="$(printf '\t')" read -r name ms status; do
        printf '  %6s s  %s\n' "$(( ${ms:-0} / 1000 ))" "$name"
      done
    shown=$((shown + 1))
  done
fi
if [ "$found" -eq 0 ]; then
  printf 'flakereport: no timing table; run ./task test --timing first\n'
fi

playwright_json="$REPO_ROOT/apps/web/test-results/playwright.json"
if [ -f "$playwright_json" ] && command -v node >/dev/null 2>&1; then
  printf 'slowest browser specs in %s\n' "${playwright_json#"$REPO_ROOT"/}"
  node - "$playwright_json" <<'JS'
const { readFileSync } = require('node:fs')
const report = JSON.parse(readFileSync(process.argv[2], 'utf8'))
const rows = []
function walk(suite, project) {
  for (const spec of suite.specs ?? []) {
    let duration = 0
    let failed = false
    for (const test of spec.tests ?? []) {
      for (const result of test.results ?? []) {
        duration += result.duration ?? 0
        if (result.status !== 'passed' && result.status !== 'skipped') failed = true
      }
    }
    rows.push({ title: spec.title, project: project ?? '', duration, failed })
  }
  for (const child of suite.suites ?? []) walk(child, project ?? suite.title)
}
for (const suite of report.suites ?? []) walk(suite, suite.title)
rows.sort((a, b) => b.duration - a.duration)
for (const row of rows.slice(0, 10)) {
  console.log(`  ${(row.duration / 1000).toFixed(2)} s  ${row.project} / ${row.title}${row.failed ? ' (failed)' : ''}`)
}
JS
else
  printf 'flakereport: no browser JSON report (CI writes it on every e2e run)\n'
fi

printf 'flakereport: %s timing table(s); compare nightly artifacts for variance\n' "$shown"
