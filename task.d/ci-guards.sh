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

# Golden contract: every job keeps the 15-minute cap. A job without one can run
# until GitHub's six-hour default and hold a runner that the next push needs.
missing_timeout=""
for workflow in "$workflows_dir"/*.yml "$workflows_dir"/*.yaml; do
  [ -f "$workflow" ] || continue
  name=${workflow#"$REPO_ROOT"/}
  found=$(awk -v name="$name" '
    /^jobs:/ { jobs = 1; next }
    jobs && /^[^ ]/ { jobs = 0 }
    jobs && /^  [A-Za-z0-9_-]+:/ {
      if (job != "" && !ok[job]) print name ":" job
      job = $0; sub(/^  /, "", job); sub(/:.*/, "", job)
      ok[job] = 0
      next
    }
    jobs && job != "" && /^    timeout-minutes: 15[[:space:]]*$/ { ok[job] = 1 }
    END { if (jobs && job != "" && !ok[job]) print name ":" job }
  ' "$workflow")
  [ -z "$found" ] || missing_timeout="$missing_timeout$found
"
done

if [ -n "$missing_timeout" ]; then
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    report "$entry has no 'timeout-minutes: 15'"
  done <<EOF
$missing_timeout
EOF
fi

# The RC branch points the SPA at the RC backend through apps/web/vercel.json.
# That line must be reverted before a tag: a tag built with it ships production
# against the RC API and the RC database. Only a release run enforces this; a
# normal pull request against the RC branch is expected to carry it.
#
# SEC-03: the tag signature needs a committed trust anchor. Without one the
# release workflow falls back to asking GitHub whether any key registered on the
# maintainer account signed the tag, which answers "whoever can add a signing
# key to that account". The file is the only thing that makes the signer a
# decision the repository reviewed, and it is key material the owner holds, so
# this guard names it instead of letting the release discover it at tag time.
if [ "$release" -eq 1 ]; then
  if grep -q 'majadu-rc' "$REPO_ROOT/apps/web/vercel.json" 2>/dev/null; then
    report "apps/web/vercel.json still rewrites /api to the RC backend; revert it to /majadu/* before tagging"
  fi
  signers="$REPO_ROOT/.github/allowed_signers"
  if [ ! -f "$signers" ]; then
    report "missing .github/allowed_signers; the tag signature has no committed trust anchor (SEC-03)"
  elif ! grep -qvE '^[[:space:]]*(#|$)' "$signers"; then
    report ".github/allowed_signers has no key line; the tag signature cannot be verified against it"
  fi
fi

if [ "$problems" -ne 0 ]; then
  printf 'ci-guards: %d problem(s)\n' "$problems" >&2
  exit 1
fi
printf 'ci-guards: ok\n'
