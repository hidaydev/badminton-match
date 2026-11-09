#!/bin/sh
# Supply-chain guards that need nothing but the checkout.
#
#   ./task ci-guards
#
# Every `uses:` in .github/workflows must name a 40-character commit SHA. A tag
# such as `@v1` is mutable: the action can change under the same ref, and a
# 41-character transcription slip is a different ref that GitHub also accepts.
# actionlint is not installed on the runner, so this check is deliberately
# narrow: it catches the one class of pin error that has already shipped here
# (commit 359373a3) without pretending to parse the whole workflow grammar.
set -eu
. "$(dirname "$0")/lib.sh"

release=0
case "${1:-}" in
  "") ;;
  --release) release=1 ;;
  *) fail "usage: ./task ci-guards [--release]" ;;
esac

problems=0
report() {
  printf 'ci-guards: %s\n' "$*" >&2
  problems=$((problems + 1))
}

workflows_dir="$REPO_ROOT/.github/workflows"
[ -d "$workflows_dir" ] || fail "missing $workflows_dir"

for workflow in "$workflows_dir"/*.yml "$workflows_dir"/*.yaml; do
  [ -f "$workflow" ] || continue
  name=${workflow#"$REPO_ROOT"/}
  line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    case "$line" in
      *uses:*) ;;
      *) continue ;;
    esac
    ref=$(printf '%s' "${line#*uses:}" | sed 's/[[:space:]]*#.*$//;s/^[[:space:]]*//;s/[[:space:]]*$//')
    case "$ref" in
      ./*|docker://*|'') continue ;;
    esac
    case "$ref" in
      *@*) pin=${ref##*@} ;;
      *)
        report "$name:$line_no: uses '$ref' has no @ref; pin a 40-hex commit SHA"
        continue
        ;;
    esac
    if ! printf '%s\n' "$pin" | grep -Eq '^[0-9a-f]{40}$'; then
      report "$name:$line_no: uses '$ref' is not pinned to a 40-hex commit SHA"
    fi
  done <"$workflow"
done

# The RC branch points the SPA at the RC backend through apps/web/vercel.json.
# That line must be reverted before a tag: a tag built with it ships production
# against the RC API and the RC database. Only a release run enforces this; a
# normal pull request against the RC branch is expected to carry it.
if [ "$release" -eq 1 ]; then
  if grep -q 'majadu-rc' "$REPO_ROOT/apps/web/vercel.json" 2>/dev/null; then
    report "apps/web/vercel.json still rewrites /api to the RC backend; revert it to /majadu/* before tagging"
  fi
fi

if [ "$problems" -ne 0 ]; then
  printf 'ci-guards: %d problem(s)\n' "$problems" >&2
  exit 1
fi
printf 'ci-guards: ok\n'
