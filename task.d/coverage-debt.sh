#!/bin/sh
# Low-coverage debt manifest (QA-13).
#
# The ratchet fails a file that drops, but it cannot ask an old file to rise.
# Eleven files sit below 80 percent, nine of them at zero. Without a written
# exception those files are frozen silently, which is how a "92 percent suite"
# keeps a quarter of its tool sources untested.
#
# docs/handbook/coverage-debt.json names every file below the new-file minimum
# with an owner and an expiry. This gate fails when a baseline has a low file
# with no entry, when an entry has expired, and when an entry names a file that
# is no longer below the minimum (a stale excuse is a dead line in a review).
. "$(dirname "$0")/lib.sh"

minimum=${COVERAGE_DEBT_MIN:-80}
manifest="$REPO_ROOT/docs/handbook/coverage-debt.json"
[ -f "$manifest" ] || fail "missing docs/handbook/coverage-debt.json"

today=$(date -u +%Y-%m-%d)

status=0
tmp="$REPO_ROOT/.cache/$WORKTREE/coverage-debt.$$"
mkdir -p "$REPO_ROOT/.cache/$WORKTREE"
: >"$tmp.low"
: >"$tmp.entries"

# The manifest is one flat object per line, like the quarantine register, so it
# is read with awk instead of a JSON library.
awk -v out="$tmp.entries" '
  function stringField(line, key,   pattern, start, rest) {
    pattern = "\"" key "\"[[:space:]]*:[[:space:]]*\""
    if (!match(line, pattern)) return ""
    start = RSTART + RLENGTH
    rest = substr(line, start)
    if (!match(rest, /"/)) return ""
    return substr(rest, 1, RSTART - 1)
  }
  /\{[[:space:]]*"path"[[:space:]]*:/ {
    path = stringField($0, "path")
    owner = stringField($0, "owner")
    expires = stringField($0, "expires")
    if (path == "" || owner == "" || expires == "") {
      printf "coverage-debt: malformed entry at line %d (path, owner and expires are required)\n", NR > "/dev/stderr"
      bad = 1
      next
    }
    printf "%s\t%s\t%s\n", path, owner, expires > out
  }
  END { exit bad ? 1 : 0 }
' "$manifest" || status=1

for baseline in "$REPO_ROOT"/coverage-baseline-*.json; do
  [ -f "$baseline" ] || continue
  awk -v min="$minimum" -v out="$tmp.low" '
    /^    ".*": \{"lines": / {
      line = $0
      sub(/^[[:space:]]*"/, "", line)
      path = line
      sub(/".*/, "", path)
      lines = $0
      sub(/.*"lines": /, "", lines)
      sub(/[^0-9].*/, "", lines)
      covered = $0
      sub(/.*"covered": /, "", covered)
      sub(/[^0-9].*/, "", covered)
      if (lines + 0 > 0 && covered * 100 < min * lines) printf "%s\n", path >> out
    }
  ' "$baseline"
done

while IFS= read -r path; do
  [ -n "$path" ] || continue
  entry=$(awk -F'\t' -v p="$path" '$1 == p { print; exit }' "$tmp.entries")
  if [ -z "$entry" ]; then
    printf 'coverage-debt: %s is below %s%% and has no entry in docs/handbook/coverage-debt.json (owner and expiry)\n' \
      "$path" "$minimum" >&2
    status=1
    continue
  fi
  expires=$(printf '%s\n' "$entry" | cut -f3)
  if [ "$expires" \< "$today" ]; then
    printf 'coverage-debt: exception for %s expired on %s; raise the file or renew the entry\n' \
      "$path" "$expires" >&2
    status=1
  fi
done <"$tmp.low"

while IFS="$(printf '\t')" read -r path owner expires; do
  [ -n "$path" ] || continue
  if ! grep -Fxq "$path" "$tmp.low"; then
    printf 'coverage-debt: entry for %s is stale; the file is no longer below %s%% (owner %s, expires %s)\n' \
      "$path" "$minimum" "$owner" "$expires" >&2
    status=1
  fi
done <"$tmp.entries"

rm -f "$tmp.low" "$tmp.entries"

if [ "$status" -ne 0 ]; then
  printf 'coverage-debt: failed\n' >&2
  exit 1
fi
printf 'coverage-debt: ok (every file below %s%% has a dated exception)\n' "$minimum"
