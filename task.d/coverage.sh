#!/bin/sh
# Line coverage for the Nim sources, with a ratchet against a committed baseline.
#
#   ./task coverage            # measure and compare with coverage-baseline.json
#   ./task coverage --update   # measure and rewrite the baseline
#
# How it works: every test binary is compiled with `--coverage` (gcov), the
# generated C in the nimcache is measured, and each generated file is attributed
# back to the Nim module that produced it. The module name comes from the mangled
# C file name (`@m`, `@p`, `@d`, `@s`), not from the `nimlf_` markers inside it:
# those markers also cover the standard-library and generic code the compiler
# inlined, and crediting the first one reported a tested module as 0% while
# silently hiding untested ones. The result is line counts per Nim module, not a
# line-by-line gcov view - which is enough for a module and total gate, and the
# script says so in the report header.
#
# gcov is read after every binary rather than once at the end: the nimcache is
# shared, so the next compile rewrites `.gcno` files whose old counters are
# still on disk. gcov refuses such a pair and reports the file as 0%, which used
# to wipe real coverage out of the report without a word.
#
# Generated routes and tests are excluded by explicit paths, never by a loose
# pattern: a report that silently included generated code would move whenever the
# contract generator ran.
. "$(dirname "$0")/lib.sh"

require_cmd nim
require_cmd lcov
require_cmd geninfo
require_cmd awk

BASELINE="$REPO_ROOT/coverage-baseline.json"
COV="$REPO_ROOT/.cache/$WORKTREE/coverage"
NIMCACHE_COV="$COV/nim"

update=0
for argument in "$@"; do
  case "$argument" in
    --update) update=1 ;;
    -h|--help)
      sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) fail "unknown argument: $argument" ;;
  esac
done

if [ -n "${MAJADU_PG_DSN:-}" ]; then
  INTEGRATION=1
else
  INTEGRATION=0
fi
export INTEGRATION

# A baseline measured without integration is not the same measurement as the one
# the gate compares against: it is lower, and writing it would silently lower
# every floor. Refuse before spending the run instead of recording a number that
# means something else.
if [ "$update" -eq 1 ] && [ "$INTEGRATION" -ne 1 ]; then
  fail "refusing --update without MAJADU_PG_DSN: the baseline is an integration measurement"
fi

# A fresh nimcache per run: stale .gcda from an earlier build would be merged
# into this run and inflate the numbers.
rm -rf "$COV"
mkdir -p "$COV/bin" "$NIMCACHE_COV"

case "$(uname -s)" in
  Darwin)
    gcov_tool="$COV/llvm-gcov"
    printf '#!/bin/sh\nexec xcrun llvm-cov gcov "$@"\n' >"$gcov_tool"
    chmod +x "$gcov_tool"
    ;;
  *)
    gcov_tool=gcov
    ;;
esac

printf 'coverage: building and running tests (integration=%s)\n' "$INTEGRATION"
mkdir -p "$COV/parts"
for file in $(list_test_files); do
  name=$(printf '%s' "$file" | sed "s|$REPO_ROOT/||" | tr '/.' '__')
  : >"$COV/binary-start"
  if ! nim c -r --hints:off --nimcache:"$NIMCACHE_COV" \
    --passC:--coverage --passL:--coverage \
    -o:"$COV/bin/$name" "$file" >"$COV/last-test.log" 2>&1; then
    tail -20 "$COV/last-test.log" >&2
    fail "test failed under coverage instrumentation: ${file#$REPO_ROOT/}"
  fi
  # Capture after every binary, before the next compile rewrites the `.gcno`
  # files. One nimcache is shared by all of them, and a module recompiled by a
  # later binary but not run by it keeps counters that no longer match its line
  # table; gcov then rejects the pair and wrote the whole file down as 0%, so a
  # tested module silently lost all of its coverage. Capturing here means every
  # pair is read while it is still consistent.
  #
  # Only the data files this run touched are decoded: a module the binary did
  # not execute keeps the counters that its own part already recorded, and
  # reaching into the nimcache for all of them every time made the gate the
  # slowest job in CI.
  find "$NIMCACHE_COV" -name '*.gcda' -newer "$COV/binary-start" \
    >"$COV/changed.list"
  if [ -s "$COV/changed.list" ]; then
    geninfo --output-filename "$COV/parts/$name.info" \
      --rc branch_coverage=0 \
      --ignore-errors gcov,source,unsupported,unused \
      --gcov-tool "$gcov_tool" $(cat "$COV/changed.list") \
      >>"$COV/lcov-capture.log" 2>&1 ||
      { tail -10 "$COV/lcov-capture.log" >&2
        fail "gcov capture failed after ${file#$REPO_ROOT/}"; }
  fi
done

if [ -z "$(ls "$COV"/parts/*.info 2>/dev/null)" ]; then
  fail "no gcov data was produced; the compiler did not accept --coverage"
fi

printf 'coverage: capturing gcov data\n'
cat "$COV"/parts/*.info >"$COV/raw.info"

# generated C -> Nim source, keyed by cache file name.
#
# The C file name is Nim's mangled module path: `@m` marks the module root, `@p`
# a parent directory, `@d` a search-path directory and `@s` the separator. That
# name identifies the module exactly.
#
# The paths written inside the file do not: `nimlf_` markers also cover the
# generic and standard-library code the compiler inlined, and taking the first
# one credited `share/crypto.nim` to the system's `arc.nim`, which is why a
# tested module could report 0%. Instead, turn the C name into a relative path
# and keep the repository marker that ends with it. A file with no such marker
# stays unmapped rather than being credited to a module it may not own.
: >"$COV/map.tsv"
for c in "$NIMCACHE_COV"/*.c; do
  [ -f "$c" ] || continue
  rel=$(printf '%s' "${c##*/}" |
    sed -e 's/\.c$//' -e 's/@s/\//g' -e 's/@[mdp]//g' -e 's|//*|/|g' -e 's|^/||')
  [ -n "$rel" ] || continue
  src=$(grep -o '"[^"]*\.nim"' "$c" | tr -d '"' |
    awk -v suffix="/$rel" \
      'substr($0, length($0) - length(suffix) + 1) == suffix { print; exit }')
  [ -n "$src" ] && printf '%s\t%s\n' "${c##*/}" "$src" >>"$COV/map.tsv"
done

# Rewrite each SF to its Nim module; drop anything outside the repository (the
# standard library and nimble packages would otherwise dominate the total).
awk -v mapfile="$COV/map.tsv" -v root="$REPO_ROOT/" '
  BEGIN {
    while ((getline line < mapfile) > 0) {
      split(line, part, "\t")
      mapping[part[1]] = part[2]
    }
    skip = 0
  }
  /^SF:/ {
    file = substr($0, 4)
    count = split(file, pieces, "/")
    mapped = mapping[pieces[count]]
    if (mapped != "" && index(mapped, root) == 1) {
      print "SF:" mapped
      skip = 0
    } else {
      skip = 1
    }
    next
  }
  /^end_of_record/ { skip = 0; next }
  { if (!skip) print }
' "$COV/raw.info" >"$COV/remapped.info"

# One line per (module, line) with the highest count seen, then per-file totals.
# Merging here instead of with `lcov -a` avoids function-record collisions when
# two generated files belong to the same Nim module.
awk -F: '
  /^SF:/ { file = $2; next }
  /^DA:/ {
    split($2, part, ",")
    key = file SUBSEP part[1]
    if (!(key in hits) || part[2] + 0 > hits[key]) hits[key] = part[2] + 0
  }
  END {
    for (key in hits) {
      split(key, part, SUBSEP)
      print part[1] "\t" part[2] "\t" hits[key]
    }
  }
' "$COV/remapped.info" |
  awk -F'\t' -v root="$REPO_ROOT/" -v out="$COV/files.tsv" '
    # Explicit exclusions. Generated routes and tests are not product code.
    function excluded(path) {
      return (path ~ /\/tests\// ||
              path == root "apps/api/src/routes_gen.nim" ||
              path ~ /_gen\.nim$/)
    }
    {
      path = $1
      if (excluded(path)) next
      if (!(path in lines)) { order[++count] = path; lines[path] = 0; covered[path] = 0 }
      lines[path]++
      if ($3 + 0 > 0) covered[path]++
    }
    END {
      for (i = 1; i <= count; i++) {
        path = order[i]
        printf "%s\t%d\t%d\n", path, lines[path], covered[path] > out
      }
    }
  '

if [ ! -s "$COV/files.tsv" ]; then
  fail "no covered module was attributed to the repository"
fi

# The exclusion above is a policy; this is the proof it held. A generated file in
# the report would move whenever the contract generator ran.
if grep -q '_gen\.nim' "$COV/files.tsv"; then
  grep '_gen\.nim' "$COV/files.tsv" | sed 's/\t.*//' >&2
  fail "a generated file reached the coverage report"
fi

# LF = 0 is a broken record, not "100% covered" or "not applicable".
awk -F'\t' -v root="$REPO_ROOT/" '
  $2 == 0 { print "coverage: " substr($1, length(root) + 1) " has LF = 0" > "/dev/stderr"; bad = 1 }
  END { exit bad ? 1 : 0 }
' "$COV/files.tsv" || fail "a file with LF = 0 appeared in the report"

# Domain = first two path components for apps/modules, single component otherwise.
awk -F'\t' -v root="$REPO_ROOT/" -v out="$COV/domains.tsv" '
  {
    rel = substr($1, length(root) + 1)
    n = split(rel, part, "/")
    if (part[1] == "modules" || part[1] == "apps") domain = part[1] "/" part[2]
    else domain = part[1]
    lf[domain] += $2
    lh[domain] += $3
    tlf += $2
    tlh += $3
  }
  END {
    printf "total\t%d\t%d\n", tlf, tlh > out
    for (domain in lf) printf "%s\t%d\t%d\n", domain, lf[domain], lh[domain] >> out
  }
' "$COV/files.tsv"

printf '\n%-28s %10s %10s\n' "domain" "lines" "cover"
awk -F'\t' '{
  pct = ($2 == 0) ? 0 : ($3 * 100 / $2)
  printf "%-28s %10d %9.2f%%\n", $1, $2, pct
}' "$COV/domains.tsv" | sort
printf '\n'

# ---------------------------------------------------------------------------
# Baseline: total plus every domain. Missing domains are reported as new, not
# ignored: a new module with no coverage must be visible.
# ---------------------------------------------------------------------------
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

write_baseline() {
  {
    printf '{\n'
    printf '  "measured": "%s",\n' "$(date -u '+%Y-%m-%d')"
    awk -F'\t' '{
      pct = ($2 == 0) ? 0 : ($3 * 100 / $2)
      printf "%s  \"%s\": %.2f", (n++ ? ",\n" : ""), $1, pct
    }
    END { printf "\n" }' "$COV/domains.tsv"
    printf '}\n'
  } >"$BASELINE"
  printf 'coverage: baseline written to %s\n' "${BASELINE#$REPO_ROOT/}"
}

if [ "$update" -eq 1 ]; then
  write_baseline
  exit 0
fi

[ -f "$BASELINE" ] || fail "missing coverage-baseline.json; run ./task coverage --update first"

# The ratchet only says "not less than last time", so a baseline rewritten low
# passes forever. This absolute floor is the second lock: a `--update` that
# records a collapse still fails here instead of becoming the new normal.
FLOOR_TOTAL=35

# gcov attributes inlined code to whichever object it landed in, so the same
# source compiled twice can differ by a few hundredths of a point on the smaller
# domains (observed: modules/share 66.91 then 66.88 with no change in between).
# Without a tolerance the gate fails on that wobble alone, which teaches people
# to re-run `--update` instead of reading the number. A tenth of a point is far
# below any real regression worth catching, and the total keeps its own floor.
TOLERANCE=0.1

awk -F'\t' -v floor="$FLOOR_TOTAL" -v tolerance="$TOLERANCE" '
  FNR == NR {
    if ($0 ~ /^[[:space:]]*"[^"]+"/) {
      line = $0
      key = line
      sub(/^[[:space:]]*"/, "", key)
      sub(/".*/, "", key)
      value = line
      sub(/^[^:]*:[[:space:]]*/, "", value)
      sub(/[,[:space:]]*$/, "", value)
      baseline[key] = value
    }
    next
  }
  {
    pct = ($2 == 0) ? 0 : ($3 * 100 / $2)
    if ($1 == "total" && pct < floor) {
      printf "coverage: total %.2f%% is below the %.0f%% floor\n", pct, floor > "/dev/stderr"
      bad = 1
    }
    current[$1] = pct
    if ($1 in baseline) {
      if (pct + tolerance < baseline[$1] + 0) {
        printf "coverage: %s dropped from %.2f%% to %.2f%%\n", $1, baseline[$1], pct > "/dev/stderr"
        bad = 1
      }
    } else if ($1 != "total") {
      printf "coverage: new domain %s at %.2f%% (add it with --update)\n", $1, pct > "/dev/stderr"
    }
  }
  END {
    for (key in baseline) {
      if (key != "measured" && key != "total" && !(key in current)) {
        printf "coverage: %s disappeared from the report\n", key > "/dev/stderr"
        bad = 1
      }
    }
    exit bad ? 1 : 0
  }
' "$BASELINE" "$COV/domains.tsv" || fail "coverage fell below the baseline"

printf 'coverage: ok (ratchet held)\n'
