#!/bin/sh
# Function length (SQ-18). Sonar's S138 trips long before 100 lines, and the
# tree already has routines measured in hundreds, so this gate is a ratchet
# rather than a threshold: the count of procs over 100 lines may not grow.
#
#   ./task proc-length
#
# Only definitions are counted, from the declaration line to the line before
# the next top-level `proc`/`template`/`func`/`iterator`/`method`. Tests are
# excluded: a test case is one scenario, not a unit of production code. The
# baseline lives in task.d/proc-length-baseline.txt with the date it was
# recorded; lowering it is the point, raising it needs a line in the same file.
set -eu
. "$(dirname "$0")/lib.sh"

limit=100
baseline="$REPO_ROOT/task.d/proc-length-baseline.txt"
[ -f "$baseline" ] || fail "missing $baseline"

expected=$(sed -n 's/^[[:space:]]*max:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$baseline" | head -1)
[ -n "$expected" ] || fail "$baseline has no 'max: <count>' line"

tmp="$REPO_ROOT/.cache/$WORKTREE/proc-length.$$"
mkdir -p "$REPO_ROOT/.cache/$WORKTREE"
: >"$tmp"

# A single awk pass per file: a declaration starts at column 0, so a nested
# proc or a continuation line never opens a new range.
for area in apps modules shared tools; do
  [ -d "$REPO_ROOT/$area" ] || continue
  find "$REPO_ROOT/$area" -name '*.nim' -type f | sort | while IFS= read -r file; do
    rel=${file#"$REPO_ROOT/"}
    case "$rel" in
      */tests/*|*/test/*) continue ;;
    esac
    awk -v rel="$rel" -v out="$tmp" '
      /^(proc|template|func|iterator|method)[ *]/ {
        if (name != "") printf "%s\t%s\t%d\n", rel, name, (FNR - start) >> out
        name = $0
        sub(/[(:].*/, "", name)
        sub(/^(proc|template|func|iterator|method)[ ]*\**[ ]*/, "", name)
        start = FNR
      }
      END { if (name != "") printf "%s\t%s\t%d\n", rel, name, (FNR - start + 1) >> out }
    ' "$file"
  done
done

over=$(awk -F'\t' -v limit="$limit" '$3 > limit { print }' "$tmp" | sort -t"$(printf '\t')" -k3,3nr)
count=$(printf '%s' "$over" | grep -c . || true)
printf 'proc-length: %s proc(s) over %s lines (baseline max %s)\n' \
  "$count" "$limit" "$expected"

if [ "$count" -gt "$expected" ]; then
  printf '%s\n' "$over" | while IFS="$(printf '\t')" read -r path name lines; do
    [ -n "$path" ] || continue
    printf 'proc-length:   %s %s %s lines\n' "$path" "$name" "$lines" >&2
  done
  rm -f "$tmp"
  fail "$count procs over $limit lines, up from $expected; extract one or record the decision in task.d/proc-length-baseline.txt"
fi

rm -f "$tmp"
printf 'proc-length: ok\n'
