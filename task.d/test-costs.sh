#!/bin/sh
# BM-03 / W8: write task.d/test-costs.tsv from the timing tables of a CI run.
#
# The shard split has to be planned against runner numbers, not laptop numbers:
# the same shell-heavy suites take an order of magnitude longer on a laptop than
# on the runner, so a table measured here would unbalance the split it was meant
# to balance. `./task test --timing` writes one table per shard and CI uploads
# both as artifacts:
#
#   gh run download <run-id> -n api-test-timing-1 -D /tmp/ci-timing/1
#   gh run download <run-id> -n api-test-timing-2 -D /tmp/ci-timing/2
#   ./task test-costs /tmp/ci-timing/1/test.tsv /tmp/ci-timing/2/test.tsv
#
# A suite appears once, at its slowest recorded time. The projected split is
# printed before the table is written, so a table that would make the shards
# worse than positional is visible instead of committed.
set -eu
. "$(dirname "$0")/lib.sh"

usage() {
  cat <<'EOF'
usage: ./task test-costs [--shards N] <timing.tsv> [<timing.tsv> ...]

  Merge the timing tables of a CI run into task.d/test-costs.tsv, which is the
  table `./task test --shard` plans against, and print the split it projects
  for N shards (3 by default, the count ci.yml and release.yml run).
EOF
}

shards=3
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --shards)
    [ "$#" -ge 2 ] || { usage >&2; exit 2; }
    shards=$2
    shift 2
    ;;
esac
case "$shards" in
  ''|*[!0-9]*) usage >&2; fail "--shards needs a number, got '$shards'" ;;
esac
[ "$shards" -ge 1 ] || fail "--shards must be at least 1"
[ "$#" -ge 1 ] || { usage >&2; exit 2; }
for table in "$@"; do
  [ -f "$table" ] || fail "no such timing table: $table"
done

bad=$(awk -F'\t' 'NF < 2 || $2 !~ /^[0-9]+$/ { print FILENAME ": " $0 }' "$@" | head -1)
[ -z "$bad" ] || fail "not a <path>TAB<milliseconds> row: $bad"
tables=$#

merged=$(mktemp "${TMPDIR:-/tmp}/test-costs.XXXXXX")
trap 'rm -f "$merged"' EXIT
awk -F'\t' '
  { if (!($1 in ms) || $2 > ms[$1]) ms[$1] = $2 }
  END { for (p in ms) printf "%s\t%s\n", p, ms[p] }' "$@" | sort >"$merged"
rows=$(wc -l <"$merged" | tr -d ' ')
[ "$rows" -gt 0 ] || fail "no timing rows in $*"

# A suite the table does not know is not free: it costs the median.
default=$(awk -F'\t' '{ print $2 }' "$merged" | sort -n |
  awk '{ c[NR] = $1 } END { if (NR) print c[int((NR + 1) / 2)]; else print 0 }')

list=$(INTEGRATION=1 list_test_files | sed "s|$REPO_ROOT/||")
unknown=$(printf '%s\n' "$list" |
  awk -F'\t' 'NR == FNR { known[$1] = 1; next } $0 != "" && !($0 in known)' \
    "$merged" - | wc -l | tr -d ' ')

# The same greedy pass shard_plan runs, reported per shard.
projection=$(printf '%s\n' "$list" |
  awk -F'\t' -v default="$default" '
    NR == FNR { cost[$1] = $2; next }
    $0 != "" { printf "%s\t%s\n", ($0 in cost) ? cost[$0] : default, $0 }' \
    "$merged" - |
  sort -t"$(printf '\t')" -k1,1nr -k2,2 |
  awk -F'\t' -v total="$shards" '
    {
      best = 1
      for (s = 2; s <= total; s++) if (load[s] < load[best]) best = s
      load[best] += $1
      files[best]++
    }
    END {
      fast = 0
      slow = 0
      for (s = 1; s <= total; s++) {
        if (s == 1 || load[s] < fast) fast = load[s]
        if (load[s] > slow) slow = load[s]
      }
      printf "%d", (fast > 0) ? (slow - fast) * 100 / fast : 0
      for (s = 1; s <= total; s++) printf " %d %d", load[s], files[s] + 0
    }')

set -- $projection
gap=$1
shift
printf 'test-costs: %s suite(s) from %s table(s), median %s s\n' \
  "$rows" "$tables" "$(awk -v d="$default" 'BEGIN { printf "%.1f", d / 1000 }')"
s=1
while [ "$#" -ge 2 ]; do
  printf 'projected shard %s: %d s across %s suite(s)\n' "$s" "$(($1 / 1000))" "$2"
  shift 2
  s=$((s + 1))
done
printf 'projected gap: %s %% (W8 ceiling 25 %%)\n' \
  "$(awk -v g="$gap" 'BEGIN { printf "%.1f", g }')"
[ "$unknown" -eq 0 ] ||
  printf 'warning: %s suite(s) not in the table use the median cost\n' "$unknown"
awk -v g="$gap" 'BEGIN { exit (g <= 25) ? 0 : 1 }' ||
  printf 'warning: this table projects a gap above the W8 ceiling\n' >&2

cp "$merged" "$TEST_COST_FILE"
printf 'table written: %s\n' "${TEST_COST_FILE#"$REPO_ROOT"/}"
