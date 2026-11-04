#!/bin/sh
# Line coverage for the Nim sources, with a ratchet against a committed baseline.
#
#   ./task coverage            # measure and compare with coverage-baseline.json
#   ./task coverage --update   # measure and rewrite the baseline
#
# How it works: every test binary is compiled with `--coverage` (gcov), the
# generated C in the nimcache is measured, and each generated file is attributed
# back to the Nim module that produced it. Nim does not emit #line directives, so
# the mapping comes from the `nimlf_("<line>", "<file>")` marker the compiler puts
# in every generated C file. The result is line counts per Nim module, not a
# line-by-line gcov view - which is enough for a module and total gate, and the
# script says so in the report header.
#
# Generated routes and tests are excluded by explicit paths, never by a loose
# pattern: a report that silently included generated code would move whenever the
# contract generator ran.
. "$(dirname "$0")/lib.sh"

require_cmd nim
require_cmd lcov
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
for file in $(list_test_files); do
  name=$(printf '%s' "$file" | sed "s|$REPO_ROOT/||" | tr '/.' '__')
  if ! nim c -r --hints:off --nimcache:"$NIMCACHE_COV" \
    --passC:--coverage --passL:--coverage \
    -o:"$COV/bin/$name" "$file" >"$COV/last-test.log" 2>&1; then
    tail -20 "$COV/last-test.log" >&2
    fail "test failed under coverage instrumentation: ${file#$REPO_ROOT/}"
  fi
done

if ! ls "$NIMCACHE_COV"/*.gcda >/dev/null 2>&1; then
  fail "no gcov data was produced; the compiler did not accept --coverage"
fi

printf 'coverage: capturing gcov data\n'
lcov --capture --directory "$NIMCACHE_COV" --gcov-tool "$gcov_tool" \
  --rc branch_coverage=0 \
  --ignore-errors mismatch,gcov,source,negative,unsupported,unused \
  --output-file "$COV/raw.info" >"$COV/lcov-capture.log" 2>&1 ||
  { tail -10 "$COV/lcov-capture.log" >&2; fail "lcov capture failed"; }

# generated C -> Nim source, keyed by cache file name
: >"$COV/map.tsv"
for c in "$NIMCACHE_COV"/*.c; do
  [ -f "$c" ] || continue
  src=$(grep -m1 -o '"/[^"]*\.nim"' "$c" | head -1 | tr -d '"')
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

awk -F'\t' '
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
    current[$1] = pct
    if ($1 in baseline) {
      if (pct + 0.005 < baseline[$1] + 0) {
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
