#!/bin/sh
# Line coverage for the Nim sources, with a per-file ratchet against a committed
# baseline.
#
#   ./task coverage
#       measure, then judge the report against coverage-baseline-<platform>.json.
#   ./task coverage --update
#       measure, then rewrite the baseline. Refuses any decrease.
#   ./task coverage --update --allow-decrease
#       same, but accepts each regression it prints.
#   ./task coverage --model task.d/fixtures/coverage/<name>
#       judge a checked-in model (baseline.json, files.tsv, an optional
#       changed.tsv) instead of measuring the tree. Costs seconds, so this is how
#       the gate's own rules, --update included, are exercised.
#
# What the gate fails on, never warns about:
#   floor   the total may not fall below the "floor" recorded in the baseline.
#           It replaces the old hardcoded 35, which was itself a C-line number.
#   total   the total may not fall below the baseline total.
#   domain  a domain may not fall. A domain absent from the baseline is a
#           failure: a new module needs tests, not a baseline rewrite.
#   file    a file may not fall. A file absent from the baseline must be at least
#           80% covered, and a new file at 0% is named as such. Per-file rows are
#           what stop a domain from hiding one regressed file behind another.
#   diff    90% of the changed executable lines must be covered (D-15). The
#           changed hunks come from `git diff --unified=0` against
#           COVERAGE_DIFF_BASE, the merge base with origin/$GITHUB_BASE_REF on a
#           pull request, or HEAD locally; the intersection is taken with the
#           per-line report. A repository with no base at all skips the check
#           with a message instead of failing it.
#
# The tolerance is 0.1 point. gcov attributes inlined code to whichever object it
# landed in, so the same source compiled twice differs by a few hundredths of a
# point on the smaller files (observed: modules/share 66.91 then 66.88 with no
# change in between). Without the tolerance the gate fails on that wobble alone,
# which teaches people to re-run --update instead of reading the number.
#
# The baseline stores line counts, not percentages: percentages are derived, and
# a stored percentage cannot tell honest growth from a regression. `--update`
# holds a decrease against every total, domain and file row until
# --allow-decrease is passed, and that flag prints each regression it accepts.
#
# The baseline is per platform. llvm-gcov on macOS and gcc's gcov on Linux
# attribute the same source to different line sets (inlining and template
# expansion differ), so a macOS measurement cannot judge a Linux one. Each
# platform records and ratchets against coverage-baseline-<platform>.json, and
# CI judges the Linux file.
#
# How the measurement works: every test binary is compiled with `--coverage`
# (gcov) and `--lineDir:on`, so gcov reports Nim source paths and Nim line
# numbers. A record whose SF is already a repository path is kept as is; a record
# that still points at generated C is mapped back through the mangled file name.
# The standard library and nimble packages are dropped. Every non-test source
# file under the included roots that has no row in the report is scored 0%, so an
# untested module cannot disappear from the denominator.
#
# Measurement can be sharded (`--shard I/N`). A shard only measures its slice,
# writes its parts and prints the report for that slice; it never runs the
# ratchet. `--parts DIR` merges every shard's parts and is the only mode that
# judges, so no partial report can stand in for the whole-tree verdict.
#
# gcov is read after every binary rather than once at the end: the nimcache is
# shared, so the next compile rewrites `.gcno` files whose old counters are still
# on disk. gcov refuses such a pair and reports the file as 0%, which used to
# wipe real coverage out of the report without a word.
#
# Generated routes and tests are excluded by explicit paths, never by a loose
# pattern, and the report is proved clean of both before it is judged: a report
# that silently included generated code would move whenever the contract
# generator ran.
. "$(dirname "$0")/lib.sh"

COV="$REPO_ROOT/.cache/$WORKTREE/coverage"

# Targets from the plan's scope table. The gate reports the gap to them; it does
# not fail on the gap while the ratchet is still climbing.
TARGET_TOTAL=92
TARGET_TOOLS=88
TARGET_DEFAULT=95
NEW_FILE_MIN=80
DIFF_MIN=90
TOLERANCE=0.1

usage() {
  cat <<'EOF'
usage: ./task coverage [--update [--allow-decrease]] [--model DIR]
                       [--shard I/N] [--parts DIR]

  --update          rewrite coverage-baseline-<platform>.json with this run's
                    measurement
  --allow-decrease  with --update, accept and print each total, domain or file
                    decrease instead of refusing it
  --model DIR       judge task.d/fixtures/coverage/DIR instead of measuring the
                    tree; no compilation, no database
  --shard I/N       measure only slice I of N of the sorted test list (1-based);
                    its parts land in a shard-specific directory and the ratchet
                    is deferred to --parts
  --parts DIR       skip measurement: merge every *.info under DIR, then build
                    and judge the report. Needs lcov and the source tree only.

  --update writes nothing to a model: it prints the accepted regressions and
  leaves the regenerated baseline in the worktree cache.

  --shard measures only and never runs the ratchet. --parts is the only mode
  that judges the merged report, and it is what the merge job runs.

  The baseline is per platform because llvm-gcov and gcc's gcov attribute lines
  differently. Record each one with --update on that platform; CI judges the
  Linux file.
EOF
}

update=0
allow_decrease=0
model=""
parts=""
shard_index=1
shard_total=1
timing_begin coverage
while [ "$#" -gt 0 ]; do
  case "$1" in
    --update) update=1 ;;
    --allow-decrease) allow_decrease=1 ;;
    --model)
      [ "$#" -ge 2 ] || fail "--model needs a directory"
      model=$2
      shift
      ;;
    --parts)
      [ "$#" -ge 2 ] || fail "--parts needs a directory"
      parts=$2
      shift
      ;;
    --shard)
      [ "$#" -ge 2 ] || { usage >&2; fail "--shard needs I/N"; }
      shard_index=${2%%/*}
      shard_total=${2##*/}
      case "$shard_index$shard_total" in
        *[!0-9]*|"") usage >&2; fail "--shard needs I/N, got '$2'" ;;
      esac
      [ "$shard_total" -ge 1 ] && [ "$shard_index" -ge 1 ] &&
        [ "$shard_index" -le "$shard_total" ] ||
        { usage >&2; fail "--shard out of range: $2"; }
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) fail "unknown argument: $1" ;;
  esac
  shift
done

if [ "$allow_decrease" -eq 1 ] && [ "$update" -ne 1 ]; then
  fail "--allow-decrease only means anything with --update"
fi

if [ -n "$model" ] && [ -n "$parts" ]; then
  fail "--model and --parts are mutually exclusive"
fi
if [ -n "$parts" ] && { [ "$shard_index" -ne 1 ] || [ "$shard_total" -ne 1 ]; }; then
  fail "--parts merges the whole set; drop --shard"
fi
if [ "$shard_total" -gt 1 ] && [ "$update" -eq 1 ]; then
  fail "--shard measures a slice only; --update needs a full run or merged --parts"
fi

# ---------------------------------------------------------------------------
# Shared helpers. Both the measured report and a fixture model are reduced to
# the same three tables before any rule looks at them:
#   files.tsv   path, executable lines, covered lines
#   total.tsv   executable lines, covered lines
#   domains.tsv domain, executable lines, covered lines
# ---------------------------------------------------------------------------

derive_totals() {
  awk -F'\t' -v total_out="$COV/total.tsv" -v domain_out="$COV/domains.tsv" '
    {
      n = split($1, part, "/")
      if (part[1] == "modules" || part[1] == "apps") domain = part[1] "/" part[2]
      else domain = part[1]
      lf[domain] += $2
      lh[domain] += $3
      tlf += $2
      tlh += $3
    }
    END {
      printf "%d\t%d\n", tlf, tlh > total_out
      for (domain in lf) printf "%s\t%d\t%d\n", domain, lf[domain], lh[domain] > domain_out
    }
  ' "$COV/files.tsv"
  sort -o "$COV/domains.tsv" "$COV/domains.tsv"
}

# The exclusions are a policy; these are the proofs they held. They run on every
# table the gate is about to judge, measured or modelled.
prove_report() {
  if grep -q '/tests/' "$COV/files.tsv"; then
    grep '/tests/' "$COV/files.tsv" | sed 's/\t.*//' >&2
    fail "a test file reached the coverage report"
  fi
  if grep -q '_gen\.nim' "$COV/files.tsv"; then
    grep '_gen\.nim' "$COV/files.tsv" | sed 's/\t.*//' >&2
    fail "a generated file reached the coverage report"
  fi
  # LF = 0 is a broken record, not "100% covered" or "not applicable".
  awk -F'\t' '
    $2 == 0 { print "coverage: " $1 " has LF = 0" > "/dev/stderr"; bad = 1 }
    END { exit bad ? 1 : 0 }
  ' "$COV/files.tsv" || fail "a file with LF = 0 appeared in the report"
}

print_report() {
  printf '%-28s %10s %10s %8s %9s\n' "domain" "lines" "cover" "target" "gap"
  awk -F'\t' -v tools="$TARGET_TOOLS" -v def="$TARGET_DEFAULT" '
    {
      pct = ($2 == 0) ? 0 : ($3 * 100 / $2)
      target = ($1 == "tools") ? tools : def
      gap = (pct < target) ? int(($2 * (target - pct) / 100) + 0.999) : 0
      printf "%-28s %10d %9.2f%% %7d%% %9d\n", $1, $2, pct, target, gap
    }
  ' "$COV/domains.tsv"
  awk -F'\t' -v total_target="$TARGET_TOTAL" -v files="$COV/files.tsv" '
    { lf = $1; lh = $2 }
    END {
      pct = (lf == 0) ? 0 : (lh * 100 / lf)
      gap = (pct < total_target) ? int((lf * (total_target - pct) / 100) + 0.999) : 0
      while ((getline row < files) > 0) count++
      printf "coverage: %d files, %d executable lines, %d covered (%.2f%%)\n", count, lf, lh, pct
      printf "coverage: total target %d%%, gap %d lines\n", total_target, gap
    }
  ' "$COV/total.tsv"
}

baseline_rows() {
  awk '
    function emit(kind, line,   body, key, lf, lh) {
      body = line
      sub(/^[[:space:]]*"/, "", body)
      key = body
      sub(/".*/, "", key)
      lf = body
      if (!sub(/.*"lines": /, "", lf)) return
      sub(/[^0-9].*/, "", lf)
      lh = body
      sub(/.*"covered": /, "", lh)
      sub(/[^0-9].*/, "", lh)
      printf "%s\t%s\t%d\t%d\n", kind, key, lf, lh
    }
    /^  "total":/ { emit("total", $0); next }
    /^  "domains":/ { section = "domain"; next }
    /^  "files":/ { section = "file"; next }
    /^  \}/ { section = ""; next }
    section != "" && /^    "/ { emit(section, $0) }
  ' "$1"
}

baseline_floor() {
  [ -f "$1" ] || return 0
  sed -n 's/^[[:space:]]*"floor":[[:space:]]*\([0-9][0-9.]*\).*/\1/p' "$1" | head -1
}

current_rows() {
  awk -F'\t' '{ printf "total\ttotal\t%d\t%d\n", $1, $2 }' "$COV/total.tsv"
  awk -F'\t' '{ printf "domain\t%s\t%d\t%d\n", $1, $2, $3 }' "$COV/domains.tsv"
  awk -F'\t' '{ printf "file\t%s\t%d\t%d\n", $1, $2, $3 }' "$COV/files.tsv"
}

baseline_block() {
  awk -F'\t' '
    { if (n++) printf ",\n"; printf "    \"%s\": {\"lines\": %d, \"covered\": %d}", $1, $2, $3 }
    END { if (n) printf "\n" }
  ' "$1"
}

write_baseline() {
  _out=$1
  _floor=$2
  _lf=$(cut -f1 "$COV/total.tsv")
  _lh=$(cut -f2 "$COV/total.tsv")
  mkdir -p "$(dirname "$_out")"
  {
    printf '{\n'
    printf '  "measured": "%s",\n' "$(date -u '+%Y-%m-%d')"
    printf '  "floor": %s,\n' "$_floor"
    printf '  "total": {"lines": %s, "covered": %s},\n' "$_lf" "$_lh"
    printf '  "domains": {\n'
    baseline_block "$COV/domains.tsv"
    printf '  },\n'
    printf '  "files": {\n'
    baseline_block "$COV/files.tsv"
    printf '  }\n'
    printf '}\n'
  } >"$_out"
}

# ---------------------------------------------------------------------------
# Diff coverage: changed hunks intersected with the per-line report.
# ---------------------------------------------------------------------------

changed_hunks() {
  awk '
    /^\+\+\+ / {
      path = substr($0, 5)
      if (path == "/dev/null") { current = ""; next }
      sub(/^b\//, "", path)
      current = path
      next
    }
    /^@@ / && current != "" {
      line = $0
      sub(/^@@ [^+]*\+/, "", line)
      sub(/ .*/, "", line)
      n = split(line, part, ",")
      start = part[1] + 0
      count = (n > 1) ? part[2] + 0 : 1
      if (count > 0) printf "%s\t%d\t%d\n", current, start, start + count - 1
    }
  ' "$1"
}

build_changed() {
  : >"$COV/changed.tsv"
  _base=${COVERAGE_DIFF_BASE:-}
  if [ -z "$_base" ]; then
    if [ -n "${GITHUB_BASE_REF:-}" ]; then
      for _ref in "origin/$GITHUB_BASE_REF" "$GITHUB_BASE_REF"; do
        _base=$(git -C "$REPO_ROOT" merge-base HEAD "$_ref" 2>/dev/null || true)
        [ -n "$_base" ] && break
      done
      if [ -z "$_base" ]; then
        printf 'coverage: diff coverage skipped: no merge base with origin/%s (fetch it, or set COVERAGE_DIFF_BASE)\n' "$GITHUB_BASE_REF"
        return 0
      fi
      printf 'coverage: diff coverage against merge base %.7s with origin/%s\n' "$_base" "$GITHUB_BASE_REF"
    elif git -C "$REPO_ROOT" rev-parse --verify -q HEAD >/dev/null 2>&1; then
      _base=HEAD
      printf 'coverage: diff coverage against HEAD (uncommitted changes)\n'
    else
      printf 'coverage: diff coverage skipped: no merge base and no HEAD (fresh repository)\n'
      return 0
    fi
  fi
  if ! git -C "$REPO_ROOT" diff --unified=0 --no-color --no-ext-diff \
    "$_base" -- '*.nim' >"$COV/changed.diff" 2>"$COV/changed.err"; then
    printf 'coverage: diff coverage skipped: git diff failed (%s)\n' "$(head -1 "$COV/changed.err")"
    return 0
  fi
  if [ ! -s "$COV/changed.diff" ]; then
    return 0
  fi
  changed_hunks "$COV/changed.diff" >"$COV/hunks.tsv"
  awk -F'\t' -v linesf="$COV/lines.tsv" -v filesf="$COV/files.tsv" '
    FILENAME == linesf { hits[$1 SUBSEP $2] = $3 + 0; perline[$1] = 1; next }
    FILENAME == filesf { inreport[$1] = 1; next }
    {
      path = $1
      if (!(path in inreport)) next
      for (line = $2 + 0; line <= $3 + 0; line++) {
        if (perline[path]) {
          if ((path SUBSEP line) in hits) printf "%s\t%d\t%d\n", path, line, hits[path SUBSEP line]
        } else {
          # In the report but with no per-line rows: a file no test imports, so
          # every changed line in it is uncovered. Dropping these instead would
          # make an untested file invisible to the diff gate.
          printf "%s\t%d\t0\n", path, line
        }
      }
    }
  ' "$COV/lines.tsv" "$COV/files.tsv" "$COV/hunks.tsv" >"$COV/changed.tsv"
}

check_diff() {
  if [ ! -s "$COV/changed.tsv" ]; then
    printf 'coverage: diff coverage skipped: no changed executable Nim lines\n'
    return 0
  fi
  awk -F'\t' -v min="$DIFF_MIN" '
    { total++; if ($3 + 0 > 0) covered++ }
    END {
      if (!total) { print "coverage: diff coverage skipped: no changed executable Nim lines"; exit 0 }
      pct = covered * 100 / total
      if (covered * 100 < min * total) {
        printf "coverage: diff coverage %.2f%% of %d changed lines is below %d%% (%d covered)\n", pct, total, min, covered > "/dev/stderr"
        exit 1
      }
      printf "coverage: diff coverage %.2f%% of %d changed lines\n", pct, total
    }
  ' "$COV/changed.tsv" || fail "diff coverage is below ${DIFF_MIN}%"
}

# ---------------------------------------------------------------------------
# The gate.
# ---------------------------------------------------------------------------

run_gate() {
  [ -f "$BASELINE" ] ||
    fail "missing ${BASELINE#"$REPO_ROOT"/} for $COVERAGE_PLATFORM; run ./task coverage --update on $COVERAGE_PLATFORM to record it"
  if ! grep -q '^  "files": {' "$BASELINE"; then
    fail "${BASELINE#$REPO_ROOT/} has no per-file rows; run ./task coverage --update to seed the v2 baseline"
  fi
  _floor=$(baseline_floor "$BASELINE")
  [ -n "$_floor" ] ||
    fail "${BASELINE#$REPO_ROOT/} has no floor; run ./task coverage --update to seed the v2 baseline"

  baseline_rows "$BASELINE" >"$COV/baseline.tsv"
  current_rows >"$COV/current.tsv"
  [ -s "$COV/baseline.tsv" ] ||
    fail "${BASELINE#$REPO_ROOT/} has no rows; run ./task coverage --update to seed the v2 baseline"

  awk -F'\t' -v tolerance="$TOLERANCE" -v new_min="$NEW_FILE_MIN" -v floor="$_floor" '
    FNR == NR {
      old[$1 SUBSEP $2] = $3 "\t" $4
      next
    }
    {
      kind = $1
      path = $2
      lf = $3 + 0
      lh = $4 + 0
      pct = (lf == 0) ? 0 : (lh * 100 / lf)
      seen[kind SUBSEP path] = 1
      if (kind == "total" && pct + 0.0001 < floor) {
        printf "coverage: total %.2f%% is below the %.2f%% floor recorded in the baseline\n", pct, floor > "/dev/stderr"
        bad = 1
      }
      if ((kind SUBSEP path) in old) {
        split(old[kind SUBSEP path], o, "\t")
        opct = (o[1] == 0) ? 0 : (o[2] * 100 / o[1])
        if (pct + tolerance < opct) {
          printf "coverage: %s dropped from %.2f%% to %.2f%% (%d of %d lines, was %d of %d)\n", (kind == "total" ? "total" : path), opct, pct, lh, lf, o[2], o[1] > "/dev/stderr"
          bad = 1
        }
        next
      }
      if (kind == "file") {
        if (pct < new_min) {
          if (lh == 0)
            printf "coverage: new file %s has 0 of %d lines covered\n", path, lf > "/dev/stderr"
          else
            printf "coverage: new file %s is at %.2f%% of %d lines, below %d%%\n", path, pct, lf, new_min > "/dev/stderr"
          bad = 1
        }
      } else if (kind == "domain") {
        printf "coverage: new domain %s at %.2f%% is not in the baseline (add it with --update)\n", path, pct > "/dev/stderr"
        bad = 1
      }
    }
    END {
      for (key in old) {
        if (key in seen) continue
        split(key, part, SUBSEP)
        if (part[1] == "total") continue
        printf "coverage: %s %s disappeared from the report\n", part[1], part[2] > "/dev/stderr"
        bad = 1
      }
      exit bad ? 1 : 0
    }
  ' "$COV/baseline.tsv" "$COV/current.tsv" || fail "coverage fell below the baseline"

  check_diff
  printf 'coverage: ok (per-file ratchet held)\n'
}

run_update() {
  _out=$1
  if [ -f "$BASELINE" ]; then
    baseline_rows "$BASELINE" >"$COV/baseline.tsv"
  else
    : >"$COV/baseline.tsv"
  fi
  current_rows >"$COV/current.tsv"
  if [ -s "$COV/baseline.tsv" ]; then
    _added=$(awk -F'\t' '
      FNR == NR { seen[$1 SUBSEP $2] = 1; next }
      !(($1 SUBSEP $2) in seen) { n++ }
      END { print n + 0 }
    ' "$COV/baseline.tsv" "$COV/current.tsv")
    awk -F'\t' -v tolerance="$TOLERANCE" -v allow="$allow_decrease" -v added="$_added" '
      FNR == NR {
        old[$1 SUBSEP $2] = $3 "\t" $4
        next
      }
      {
        key = $1 SUBSEP $2
        if (!(key in old)) next
        split(old[key], o, "\t")
        opct = (o[1] == 0) ? 0 : (o[2] * 100 / o[1])
        pct = ($3 == 0) ? 0 : ($4 * 100 / $3)
        if (pct + tolerance < opct) {
          label = ($1 == "total") ? "total" : $2
          if (allow) {
            printf "coverage: accepting decrease: %s %.2f%% -> %.2f%% (%d of %d lines, was %d of %d)\n", label, opct, pct, $4, $3, o[2], o[1] > "/dev/stderr"
          } else {
            printf "coverage: refusing decrease: %s %.2f%% -> %.2f%% (%d of %d lines, was %d of %d)\n", label, opct, pct, $4, $3, o[2], o[1] > "/dev/stderr"
            bad = 1
          }
        }
      }
      END {
        if (added > 0) printf "coverage: %d row(s) added\n", added > "/dev/stderr"
        exit bad ? 1 : 0
      }
    ' "$COV/baseline.tsv" "$COV/current.tsv" ||
      fail "coverage fell below the baseline; pass --allow-decrease to accept the regression"
  fi

  _pct=$(awk -F'\t' '{ printf "%.2f", ($1 == 0) ? 0 : ($2 * 100 / $1) }' "$COV/total.tsv")
  _old_floor=$(baseline_floor "$BASELINE")
  if [ -n "$_old_floor" ]; then
    if awk -v n="$_pct" -v f="$_old_floor" 'BEGIN { exit !(n + 0.0001 >= f + 0) }'; then
      _floor=$_old_floor
    elif [ "$allow_decrease" -eq 1 ]; then
      printf 'coverage: accepting floor decrease: %s%% -> %s%%\n' "$_old_floor" "$_pct" >&2
      _floor=$_pct
    else
      fail "coverage ${_pct}% is below the baseline floor ${_old_floor}%; pass --allow-decrease to accept it"
    fi
  else
    _floor=$_pct
  fi

  write_baseline "$_out" "$_floor"
  printf 'coverage: baseline written to %s\n' "${_out#$REPO_ROOT/}"
}

# ---------------------------------------------------------------------------
# Fixture model: no compilation, no database, seconds instead of half an hour.
# ---------------------------------------------------------------------------

if [ -n "$model" ]; then
  require_cmd awk
  [ -d "$model" ] || fail "no such model directory: $model"
  [ -f "$model/baseline.json" ] || fail "$model has no baseline.json"
  [ -f "$model/files.tsv" ] || fail "$model has no files.tsv"
  COV="$REPO_ROOT/.cache/$WORKTREE/coverage/model"
  rm -rf "$COV"
  mkdir -p "$COV"
  cp "$model/files.tsv" "$COV/files.tsv"
  if [ -f "$model/changed.tsv" ]; then
    cp "$model/changed.tsv" "$COV/changed.tsv"
  else
    : >"$COV/changed.tsv"
  fi
  BASELINE="$model/baseline.json"
  printf 'coverage: model %s\n' "${model#"$REPO_ROOT"/}"
  prove_report
  derive_totals
  print_report
  if [ "$update" -eq 1 ]; then
    run_update "$COV/baseline.next.json"
    printf 'coverage: model baseline left at %s (fixtures are not rewritten)\n' "${COV#"$REPO_ROOT"/}/baseline.next.json"
    exit 0
  fi
  run_gate
  exit 0
fi

# ---------------------------------------------------------------------------
# Platform baseline.
# ---------------------------------------------------------------------------
# llvm-gcov on macOS and gcc's gcov on Linux attribute the same source to
# different line sets, so each platform judges against the baseline recorded on
# it. A model carries its own baseline.json and never reaches this block.
case "$(uname -s)" in
  Darwin) COVERAGE_PLATFORM=darwin ;;
  Linux) COVERAGE_PLATFORM=linux ;;
  *)
    fail "unsupported platform '$(uname -s)': coverage baselines exist for darwin and linux"
    ;;
esac
BASELINE="$REPO_ROOT/coverage-baseline-$COVERAGE_PLATFORM.json"
printf 'coverage: platform %s, baseline %s\n' \
  "$COVERAGE_PLATFORM" "${BASELINE#"$REPO_ROOT"/}"

# ---------------------------------------------------------------------------
# Measurement.
# ---------------------------------------------------------------------------

require_cmd awk

NIMCACHE_COV="$COV/nim"
PARTS_DIR="$COV/parts"
if [ "$shard_total" -gt 1 ]; then
  # One directory per shard, so two measurements on the same machine (or two
  # downloaded artifacts) never overwrite each other's parts.
  PARTS_DIR="$COV/parts-${shard_index}-of-${shard_total}"
fi

if [ -n "$parts" ]; then
  # Parts mode. The shard jobs already compiled and ran the suites; this run
  # only merges their `.info` files. No Nim, no gcov, no database: the merge
  # reads the source tree for file sizes and the baseline, and `lcov` is the
  # only toolchain the ratchet job installs.
  require_cmd lcov
  require_cmd git
  [ -d "$parts" ] || fail "no such parts directory: $parts"
  _info_count=$(find "$parts" -type f -name '*.info' | wc -l | tr -d ' ')
  [ "$_info_count" -gt 0 ] ||
    fail "no *.info parts in ${parts#"$REPO_ROOT"/}: nothing to merge"

  # The same checks run_gate makes, made before the merge instead of after: a
  # baseline with no per-file rows cannot judge anything.
  if [ "$update" -eq 0 ]; then
    [ -f "$BASELINE" ] ||
      fail "missing ${BASELINE#"$REPO_ROOT"/} for $COVERAGE_PLATFORM; run ./task coverage --update on $COVERAGE_PLATFORM to record it"
    grep -q '^  "files": {' "$BASELINE" ||
      fail "${BASELINE#"$REPO_ROOT"/} has no per-file rows; run ./task coverage --update to seed the v2 baseline"
  fi

  # Stage outside $COV before clearing it: --parts may point at a directory a
  # previous shard run left inside the cache, and that directory must survive
  # the copy. Artifacts arrive one directory per shard, so flattening the
  # relative path into the part name keeps two shards from colliding.
  _stage="$REPO_ROOT/.cache/$WORKTREE/coverage-parts-stage.$$"
  rm -rf "$_stage"
  mkdir -p "$_stage"
  _copy_status=0
  ( cd "$parts" && find . -type f -name '*.info' -print ) |
    while IFS= read -r _rel; do
      _rel=${_rel#./}
      cp "$parts/$_rel" "$_stage/$(printf '%s' "$_rel" | tr '/' '_')" || exit 1
    done || _copy_status=$?
  [ "$_copy_status" -eq 0 ] ||
    fail "cannot copy parts from ${parts#"$REPO_ROOT"/}"

  rm -rf "$COV"
  mkdir -p "$PARTS_DIR"
  mv "$_stage"/*.info "$PARTS_DIR"/ ||
    fail "cannot stage parts from ${parts#"$REPO_ROOT"/}"
  rm -rf "$_stage"
  printf 'coverage: merging %s part(s) from %s\n' \
    "$_info_count" "${parts#"$REPO_ROOT"/}"
else
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

  # The same checks run_gate makes, made before half an hour of compiles instead of
  # after: a baseline with no per-file rows cannot judge anything. A shard never
  # judges, so it must not need the baseline: recording the first Linux baseline
  # starts from a tree where that file does not exist yet.
  if [ "$update" -eq 0 ] && [ "$shard_total" -eq 1 ]; then
    [ -f "$BASELINE" ] ||
      fail "missing ${BASELINE#"$REPO_ROOT"/} for $COVERAGE_PLATFORM; run ./task coverage --update on $COVERAGE_PLATFORM to record it"
    grep -q '^  "files": {' "$BASELINE" ||
      fail "${BASELINE#"$REPO_ROOT"/} has no per-file rows; run ./task coverage --update to seed the v2 baseline"
  fi

  require_cmd nim
  require_cmd lcov
  require_cmd geninfo
  require_cmd git

  # A fresh nimcache per run: stale .gcda from an earlier build would be merged
  # into this run and inflate the numbers.
  rm -rf "$COV"
  mkdir -p "$COV/bin" "$NIMCACHE_COV" "$PARTS_DIR"

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
  # QA-06: a suite that cleans up after itself still leans on its neighbours, so
  # every file gets a fresh database, exactly as `./task test` gives it one.
  if [ "$INTEGRATION" -eq 1 ]; then
    isolation_begin coverage
  fi
  index=0
  ran=0
  for file in $(list_test_files); do
    index=$((index + 1))
    shard_keeps "$index" "$shard_total" "$shard_index" || continue
    ran=$((ran + 1))
    name=$(printf '%s' "$file" | sed "s|$REPO_ROOT/||" | tr '/.' '__')
    if [ "$INTEGRATION" -eq 1 ]; then
      isolation_apply "${file#"$REPO_ROOT"/}"
    fi
    _suite_start=$(now_ms)
    # Each suite is measured alone, from an empty set of counters.
    #
    # Selecting this suite's files by age (`-newer` a marker) is not enough: when
    # a module was recompiled since its `.gcda` was written, the gcov runtime
    # refuses to merge the pair ("corrupt arc tag"), leaves the stale file where
    # it is, and every later suite decodes that module as zero. The nimcache is
    # kept between coverage runs, so one edited file poisoned a whole measurement:
    # `shared/platform-lib/db/db.nim` reported 17.8% while every integration suite
    # was using it.
    #
    # Deleting the counters first means the files present after the run are
    # exactly the instrumented objects this binary loaded, so the capture is the
    # suite's own coverage and no corrupt pair can outlive the suite that made it.
    find "$NIMCACHE_COV" -name '*.gcda' -delete 2>/dev/null || true
    if ! nim c --hints:off --nimcache:"$NIMCACHE_COV" \
      --passC:--coverage --passL:--coverage --lineDir:on \
      -o:"$COV/bin/$name" "$file" >"$COV/last-test.log" 2>&1; then
      tail -20 "$COV/last-test.log" >&2
      fail "test failed to compile under coverage: ${file#"$REPO_ROOT"/}"
    fi
    _status=0
    "$COV/bin/$name" >>"$COV/last-test.log" 2>&1 || _status=$?
    if [ "$_status" -eq 77 ]; then
      printf 'coverage: skipped %s (reserved status 77)\n' "${file#"$REPO_ROOT"/}"
      timing_add "${file#"$REPO_ROOT"/}" "$(( $(now_ms) - _suite_start ))" 77
      continue
    fi
    if [ "$_status" -ne 0 ]; then
      tail -20 "$COV/last-test.log" >&2
      fail "test failed under coverage instrumentation: ${file#"$REPO_ROOT"/}"
    fi
    timing_add "${file#"$REPO_ROOT"/}" "$(( $(now_ms) - _suite_start ))" 0
    # Capture before the next compile touches the cache. The set is small: the
    # counters were deleted before this binary ran, so only the objects it loaded
    # are here. A part that fails to decode is a bug in this script, not a reason
    # to record a zero, so `gcov` errors are fatal rather than ignored. `mismatch`
    # is the one exception: gcov 13 reports a different end line for the
    # compiler-generated `eqdestroy` of a module than the `.gcno` recorded, which
    # is a Nim/gcov artifact rather than a decoding failure.
    find "$NIMCACHE_COV" -name '*.gcda' >"$COV/captured.list"
    if [ -s "$COV/captured.list" ]; then
      geninfo --output-filename "$PARTS_DIR/$name.info" \
        --rc branch_coverage=0 \
        --ignore-errors source,unsupported,unused,mismatch \
        --gcov-tool "$gcov_tool" $(cat "$COV/captured.list") \
        >>"$COV/lcov-capture.log" 2>&1 ||
        { tail -10 "$COV/lcov-capture.log" >&2
          fail "gcov capture failed after ${file#"$REPO_ROOT"/}"; }
    fi
  done

  if [ "$shard_total" -gt 1 ]; then
    printf 'coverage: shard %s/%s measured %s of %s suite(s)\n' \
      "$shard_index" "$shard_total" "$ran" "$index"
  fi

  if [ -z "$(ls "$PARTS_DIR"/*.info 2>/dev/null)" ]; then
    if [ "$ran" -eq 0 ]; then
      fail "shard $shard_index/$shard_total kept no suite; check --shard"
    fi
    fail "no gcov data was produced; the compiler did not accept --coverage"
  fi

  printf 'coverage: capturing gcov data\n'
fi

cat "$PARTS_DIR"/*.info >"$COV/raw.info"

# generated C -> Nim source, keyed by cache file name.
#
# With `--lineDir:on`, gcov reports the Nim source path directly, so a record
# whose SF is already an absolute path inside the repository is kept as is. The
# C-name mapping below stays for any record that still points at generated C.
# Paths outside the repository (the standard library and nimble packages) are
# dropped either way.
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
    if (index(file, root) == 1 && file ~ /\.nim$/) {
      print "SF:" file
      skip = 0
      next
    }
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

# How many lines each file actually has. A `DA:` record on a line past the end
# of the file is not coverage of that file: Nim emits `#line` directives for the
# template body an instantiation came from, so gcov reports arcs at line numbers
# the source does not have (`shared/platform-lib/clock.nim` is 26 lines and
# carried 44). Those phantom rows were also the source of the run to run wobble,
# because whichever binary inlined the template decided whether the phantom line
# counted as covered.
: >"$COV/sizes.tsv"
awk -F: -v root="$REPO_ROOT/" '
  function included(rel) {
    return substr(rel, 1, 5) == "apps/" || substr(rel, 1, 8) == "modules/" ||
           substr(rel, 1, 7) == "shared/" || substr(rel, 1, 6) == "tools/"
  }
  /^SF:/ {
    file = $2
    if (index(file, root) != 1) next
    rel = substr(file, length(root) + 1)
    if (included(rel)) print rel
  }
' "$COV/remapped.info" | sort -u | while IFS= read -r rel; do
  [ -f "$REPO_ROOT/$rel" ] || continue
  printf '%s\t%s\n' "$rel" "$(awk 'END { print NR }' "$REPO_ROOT/$rel")"
done >>"$COV/sizes.tsv"

# One row per (module, line) with the highest count seen. Merging here instead of
# with `lcov -a` avoids function-record collisions when two generated files
# belong to the same Nim module. Paths are repository-relative from here on: the
# baseline, the diff and the report all speak the same names.
awk -F: -v root="$REPO_ROOT/" -v sizesfile="$COV/sizes.tsv" \
    -v dropfile="$COV/phantom.txt" '
  BEGIN {
    while ((getline line < sizesfile) > 0) {
      split(line, sized, "\t")
      size[sized[1]] = sized[2] + 0
    }
  }
  function included(rel) {
    return substr(rel, 1, 5) == "apps/" || substr(rel, 1, 8) == "modules/" ||
           substr(rel, 1, 7) == "shared/" || substr(rel, 1, 6) == "tools/"
  }
  /^SF:/ {
    file = $2
    rel = ""
    # Only the included roots count. On CI the Nim toolchain lives inside the
    # checkout under .nim_runtime, and its 17k lines would otherwise enter the
    # denominator as if they were project code.
    if (index(file, root) == 1) rel = substr(file, length(root) + 1)
    if (!included(rel)) rel = ""
    next
  }
  /^DA:/ {
    if (rel == "") next
    split($2, part, ",")
    if ((rel in size) && part[1] + 0 > size[rel]) {
      ghost = rel SUBSEP part[1]
      if (!(ghost in phantoms)) { phantoms[ghost] = 1; dropped++ }
      next
    }
    key = rel SUBSEP part[1]
    if (!(key in hits) || part[2] + 0 > hits[key]) hits[key] = part[2] + 0
  }
  END {
    print dropped + 0 > dropfile
    for (key in hits) {
      split(key, part, SUBSEP)
      print part[1] "\t" part[2] "\t" hits[key]
    }
  }
' "$COV/remapped.info" >"$COV/lines.tsv"

phantom=$(cat "$COV/phantom.txt" 2>/dev/null || echo 0)
if [ "$phantom" -gt 0 ]; then
  printf 'coverage: ignored %s line number(s) past the end of their file (template inlining)\n' \
    "$phantom"
fi

# Per-file totals with the reviewed exclusions. Tests are structural, not
# product code; everything else is a literal path from the manifest (R-12), so a
# file stops being excluded the moment its entry is reviewed away.
manifest="$REPO_ROOT/docs/handbook/coverage-exclusions.json"
[ -f "$manifest" ] ||
  fail "missing $manifest: coverage exclusions are enumerated there, never pattern-matched"
: >"$COV/excluded.list"
grep -o '"path"[[:space:]]*:[[:space:]]*"[^"]*"' "$manifest" |
  sed -e 's/.*"\([^"]*\)"$/\1/' >>"$COV/excluded.list"
[ -s "$COV/excluded.list" ] ||
  fail "$manifest lists no path: the generated routes would enter the denominator"

awk -F'\t' -v out="$COV/files.tsv" -v excfile="$COV/excluded.list" '
  BEGIN {
    while ((getline line < excfile) > 0) {
      if (line != "") exempt[line] = 1
    }
  }
  function excluded(path) {
    return (path ~ /\/tests\// || (path in exempt))
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
' "$COV/lines.tsv"

# A file that no test imports produces no gcov record at all. Scored 0% rather
# than omitted: an untested module must not disappear from the report, which is
# how `tools/import/main.nim` stayed invisible while its suite "passed".
: >"$COV/unmeasured.tsv"
cut -f1 "$COV/files.tsv" | sort >"$COV/measured.list"
for area in apps/api/src modules shared/platform-lib tools; do
  [ -d "$REPO_ROOT/$area" ] || continue
  find "$REPO_ROOT/$area" -name '*.nim' -type f | while IFS= read -r src; do
    rel=${src#"$REPO_ROOT/"}
    case "$rel" in
      */tests/*|*/test/*) continue ;;
    esac
    grep -Fxq "$rel" "$COV/excluded.list" && continue
    grep -Fxq "$rel" "$COV/measured.list" && continue
    lines=$(grep -cvE '^[[:space:]]*(#|$)' "$src" || true)
    [ "${lines:-0}" -gt 0 ] || lines=1
    printf '%s\t%d\t0\n' "$rel" "$lines"
  done
done >>"$COV/unmeasured.tsv"
if [ -s "$COV/unmeasured.tsv" ]; then
  cat "$COV/unmeasured.tsv" >>"$COV/files.tsv"
  printf 'coverage: %d file(s) imported by no test scored 0%%\n' "$(wc -l <"$COV/unmeasured.tsv" | tr -d ' ')"
fi

if [ ! -s "$COV/files.tsv" ]; then
  fail "no covered module was attributed to the repository"
fi

sort -o "$COV/files.tsv" "$COV/files.tsv"

prove_report
derive_totals
printf '\n'
print_report
printf '\n'
timing_summary coverage
printf '\n'

# A shard measures and reports, but never judges: its report covers a slice, so
# a ratchet verdict on it would be wrong in both directions. `--parts` is the
# only mode that judges, and the merge job runs it over every shard's parts.
if [ -z "$parts" ] && [ "$shard_total" -gt 1 ]; then
  printf 'coverage: shard %s/%s measured only; the merged ratchet runs in the merge job (--parts)\n' \
    "$shard_index" "$shard_total"
  exit 0
fi

if [ "$update" -eq 1 ]; then
  run_update "$BASELINE"
  exit 0
fi

build_changed
run_gate