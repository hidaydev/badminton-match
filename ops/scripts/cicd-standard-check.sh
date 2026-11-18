#!/usr/bin/env bash
# contract-check.sh — check repos against the Qouver CI/CD golden contract.
#
# Read-only: it never writes to a repo and never touches a host. Run it from a
# repo's CI (`./ops/scripts/contract-check.sh .`) to fail the build on drift, or
# point it at ~/Projects to see every project side by side.
#
# Language detection drives the stack-specific rules, so the same file serves a
# Nim monorepo, a Go service, a pnpm workspace and a static book site:
#
#   universal (any repo, any stack)
#     W1  at least one workflow under .github/workflows
#     W2  every job declares timeout-minutes (15)
#     W3  no github.event*/inputs interpolation inside a run: block (shell injection)
#     W4  a secret scan runs (gitleaks or trufflehog)
#     W5  .github/dependabot.yml covers actions + the repo's own ecosystem
#     W9  no job waits on another workflow's run inside a CI workflow
#         (that poll owns the CI wall; it belongs in its own check)
#     W10 Dependabot PRs skip image/e2e/coverage work: a pull_request guard on
#         github.actor == 'dependabot[bot]', and never on push
#     W11 one gate command per workflow run: two jobs may not run the same
#         check/test command with the same env
#     D1  deploy script exists and is reachable from the documented path
#     D2  fail-closed ref guard, exact form: if [ "$REF" != "refs/heads/main" ]
#     D3  flock concurrency lock
#     D4  no commit-SHA image tag left behind (:local / :prev only)
#     D5  smoke check present
#     D6  rollback to :prev present
#
#   per stack (detected, not configured)
#     node  (pnpm-lock.yaml | package-lock.json)  dependency CVE scan: pnpm/npm
#                                                 audit, osv-scanner or trivy
#     go    (go.mod)                              govulncheck in CI
#     nim   (*.nimble | config.nims)              deps pinned by commit in
#                                                 *.nimble / nimble.paths; no CVE
#                                                 scanner exists, so the rule is
#                                                 "locked deps + gitleaks", not audit
#     static(quartz/_quarto.yml, no runtime deps) no dependency rule, gitleaks only
#
#   container / frontend (DEPLOY-FLOW.md §13.7)
#     C1  no paths:/paths-ignore: under on: (a filtered workflow creates no check-run)
#     C2  gate tolerates `skipped` only for image-api / image-web
#     C3  apps/web/ is shipped: an image-web job, or a static-host target in
#         apps/web/, plus a quadlet on 127.0.0.1:<port>
#     C4  a changes job ships its path-filter test table
#     C5  one Dockerfile name: apps/<part>/Dockerfile, never Containerfile*
#     C6  buildx uses context: . with file: apps/<part>/Dockerfile
#     C7  a ghcr pull in a deploy script fails closed: only manifest-unknown is
#         "this side did not change"
#
# Usage: ./ops/scripts/contract-check.sh [repo-dir ...]
#        (default: every git repo directly under ~/Projects)
# Exit:  0 = contract met, 1 = violation, 2 = usage error.
set -uo pipefail

TIMEOUT_MIN=${TIMEOUT_MIN:-15}
REF_GUARD='if [ "$REF" != "refs/heads/main" ]; then'
ROOT="${1:-}"

GREEN=$'\033[32m'; RED=$'\033[31m'; YEL=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
[ -t 1 ] || { GREEN=''; RED=''; YEL=''; DIM=''; RST=''; }

FAILS=0; WARNS=0; REPOS=0; REPO_FAILS=0

ok()   { printf '  %sOK%s   %s\n' "$GREEN" "$RST" "$1"; }
bad()  { printf '  %sFAIL%s %s\n' "$RED" "$RST" "$1"; FAILS=$((FAILS+1)); REPO_FAILS=$((REPO_FAILS+1)); }
warn() { printf '  %sWARN%s %s\n' "$YEL" "$RST" "$1"; WARNS=$((WARNS+1)); }
note() { printf '  %s--%s   %s\n' "$DIM" "$RST" "$1"; }

usage() { sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 2; }
[ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && usage

# ---------------------------------------------------------------- detection ---
stacks_of() {
  local d="$1" s=''
  { [ -f "$d/pnpm-lock.yaml" ] || [ -f "$d/package-lock.json" ] || [ -f "$d/yarn.lock" ]; } && s="$s node"
  { [ -f "$d/go.mod" ] || [ -n "$(find "$d" -maxdepth 4 -name go.mod -not -path '*/node_modules/*' -print -quit 2>/dev/null)" ]; } && s="$s go"
  { ls "$d"/*.nimble >/dev/null 2>&1 || [ -f "$d/config.nims" ] || [ -n "$(find "$d" -maxdepth 3 -name '*.nimble' -not -path '*/node_modules/*' -print -quit 2>/dev/null)" ]; } && s="$s nim"
  { [ -f "$d/_quarto.yml" ] || [ -d "$d/quartz" ]; } && s="$s static"
  printf '%s\n' "${s:-unknown}"
}

deploy_script() {
  local d="$1" c
  for c in ops/scripts/deploy-vps.sh ops/scripts/deploy-static.sh deploy/deploy-vps.sh \
           scripts/deploy-vps.sh ops/scripts/deploy.sh; do
    [ -f "$d/$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

# --------------------------------------------------------------- workflows ---
# Every job under `jobs:` must carry timeout-minutes. Job keys are the only
# 2-space-indented keys in that block; anything left at EOF is reported too.
check_timeouts() {
  local f="$1" missing
  missing=$(awk -v want="timeout-minutes" '
    /^jobs:[[:space:]]*$/ { injobs=1; next }
    injobs && /^[^[:space:]#]/ { if (job != "" && !seen) print job; injobs=0; job=""; seen=0 }
    injobs && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
      if (job != "" && !seen) print job
      job=$0; sub(/^  /,"",job); sub(/:.*/,"",job); seen=0; next
    }
    injobs && /^    timeout-minutes:[[:space:]]*[0-9]+/ { seen=1 }
    END { if (injobs && job != "" && !seen) print job }
  ' "$f")
  if [ -n "$missing" ]; then
    bad "$(basename "$f"): job tanpa timeout-minutes -> $(echo $missing | tr '\n' ' ')"
  elif grep -q "^    timeout-minutes: $TIMEOUT_MIN" "$f"; then
    ok "$(basename "$f"): timeout-minutes $TIMEOUT_MIN"
  else
    warn "$(basename "$f"): timeout ada tapi bukan $TIMEOUT_MIN menit"
  fi
}

# A run: block (inline or scalar) must not interpolate a context expression.
check_injection() {
  local f="$1" hits
  hits=$(awk '
    { line=$0
      if (line ~ /^[[:space:]]*(-[[:space:]]*)?run:[[:space:]]*[^|>]/) {
        if (line ~ /\$\{\{[[:space:]]*(github\.event|github\.head_ref|inputs\.)/) print NR": "$0
        next
      }
      if (line ~ /^[[:space:]]*(-[[:space:]]*)?run:[[:space:]]*[|>]/) { inrun=1; ind=match(line,/[^ ]/)-1+2; next }
      if (inrun) {
        if (line ~ /^[[:space:]]*$/ ) next
        if (match(line,/[^ ]/)-1 < ind) { inrun=0; next }
        if (line ~ /\$\{\{[[:space:]]*(github\.event|github\.head_ref|inputs\.)/) print NR": "$0
      }
    }' "$f")
  [ -n "$hits" ] && bad "$(basename "$f"): context expression di dalam run -> $hits" ||
    note "$(basename "$f"): tidak ada interpolasi konteks di run"
}

# Repos that are deliberately out of the migration scope in DEPLOY-FLOW.md, with
# the rule ids they are exempt from. Everything else must satisfy the contract.
repo_exempt() {
  case "$(basename "$1")" in
    majadu)          echo "C3 C5" ;;  # §4: repo is 404 on GitHub, the container is being retired
    badminton-match) echo "C3" ;;     # §13.6: owner excluded its frontend from the container migration
  esac
}

# Tag retention across every deploy script, not only the one D1 resolved. A
# `podman tag` whose target is neither :local nor :prev leaves a third tag in the
# store; §7 lists the documented exceptions and anything else is drift. The
# production script's tags are the contract (D4 already reads it); the other
# scripts only warn, because cutover/RC keep a pinned rollback image on purpose.
check_retention_tags() {
  local d="$1" f extra all="" seen=0
  for f in "$d"/ops/scripts/*deploy*.sh "$d"/ops/scripts/cutover.sh \
           "$d"/ops/scripts/rollback.sh; do
    [ -f "$f" ] || continue
    seen=$((seen + 1))
    extra=$(grep -E 'podman tag ' "$f" 2>/dev/null | awk '
      { for (i=1;i<=NF;i++) if ($i=="tag") { tgt=$(NF); break }
        gsub(/["\x27]/,"",tgt)
        if (tgt !~ /:/) next
        tag=tgt; sub(/.*:/,"",tag)
        if (tag != "local" && tag != "prev" && tag !~ /\$/) print tag }' | sort -u | tr '\n' ' ')
    [ -n "$extra" ] && all="$all $(basename "$f"):$extra"
  done
  if [ -z "$all" ]; then
    [ "$seen" -gt 1 ] &&
      note "tag retention bersih di $seen script deploy"
    return 0
  fi
  warn "tag di luar :local/:prev ->$all (pastikan ini pengecualian yang tercatat di §7)"
}

badid() {
  local id="$1" exempt; shift
  exempt=" $(repo_exempt "$CUR_REPO") "
  case "$exempt" in
    *" $id "*) note "$id exempt for $(basename "$CUR_REPO"): $*" ;;
    *) bad "$*" ;;
  esac
}

# ------------------------------------------------- §13.7 additional rules ---
# 9  frontend shape: apps/web/ ships via an image-web job or a static-host
#    target, plus a quadlet
#    publishing a loopback port
# 10 no `paths:` / `paths-ignore:` under `on:` (a filtered workflow creates no
#    check-run, and a deploy gate waiting for one hangs)
# 11 `skipped` tolerated only for the image jobs inside `gate`
# 12 a repo with a `changes` job ships the path-filter table that proves it
# 13 one Dockerfile name: apps/<part>/Dockerfile, never Containerfile*
# 14 buildx call uses context `.` and file apps/<part>/Dockerfile
# 15 a deploy script pulling from ghcr treats only manifest-unknown as "not built"
check_paths_filter() {
  local f="$1" hits
  hits=$(awk '
    /^on:[[:space:]]*$/ { inon=1; next }
    inon && /^[^[:space:]#]/ { inon=0 }
    inon && /^[[:space:]]*(paths|paths-ignore):/ { print NR": "$0 }
  ' "$f")
  [ -n "$hits" ] && bad "$(basename "$f"): paths filter under on: -> $hits" ||
    note "$(basename "$f"): no paths filter under on:"
}

check_gate_skips() {
  local f="$1" lines bad_lines
  lines=$(awk '
    /^  gate:[[:space:]]*$/ { ingate=1; next }
    ingate && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ { ingate=0 }
    ingate && /skipped/ { print NR": "$0 }
  ' "$f")
  [ -n "$lines" ] || return 0
  # only a `skipped` tied to a required job is a defect; a skipped image job or a
  # job that is itself PR-only (badminton's mutation) is legitimate
  bad_lines=$(printf '%s\n' "$lines" | sed 's/^[0-9]*:[[:space:]]*//' | grep -vE '^#' |
    grep -E 'R_(CHECK|TEST|CONTRACT|SECURITY|VERIFY)|needs\.(check|test|contract|security|verify)|"(check|test|contract|security|verify)"' || true)
  [ -n "$bad_lines" ] &&
    bad "$(basename "$f"): gate tolerates skipped for a required job -> $bad_lines"
}

check_dockerfile() {
  local d="$1" stray inapps tracked has
  # A build cache carries generated Dockerfiles (nimble ships
  # dist/nimble/tests/Dockerfile.debug inside .nim_runtime) and those are not the
  # repository's own content: on 2026-11-18 that file reddened the contract job
  # after `./task deps-install`. Scan tracked files when the directory is a work
  # tree, and a pruned find otherwise.
  if tracked=$(git -C "$d" ls-files 2>/dev/null) && [ -n "$tracked" ]; then
    stray=$(printf '%s\n' "$tracked" |
      grep -E '(^|/)(Containerfile[^/]*|[^/]*\.containerfile)$' || true)
    inapps=$(printf '%s\n' "$tracked" |
      grep -E '(^|/)Dockerfile' | grep -vE '^apps/[A-Za-z0-9_.-]+/Dockerfile$' || true)
    has=$(printf '%s\n' "$tracked" | grep -E '(^|/)Dockerfile' || true)
  else
    stray=$(find "$d" \( -name node_modules -o -name .git -o -name .nim_runtime -o -name .cache -o -name .nimble \) -prune -o \
      -type f \( -name 'Containerfile*' -o -name '*.containerfile' \) -print 2>/dev/null | sed "s|^$d/||")
    inapps=$(find "$d" \( -name node_modules -o -name .git -o -name .nim_runtime -o -name .cache -o -name .nimble \) -prune -o \
      -type f -name 'Dockerfile*' -print 2>/dev/null | sed "s|^$d/||" | grep -vE '^apps/[A-Za-z0-9_.-]+/Dockerfile$' || true)
    has=$(find "$d" \( -name node_modules -o -name .git -o -name .nim_runtime -o -name .cache -o -name .nimble \) -prune -o \
      -type f -name Dockerfile -print -quit 2>/dev/null)
  fi
  [ -n "$stray" ] && badid C5 "container file naming: -> $(echo $stray | tr '\n' ' ')"
  [ -n "$inapps" ] && badid C5 "Dockerfile outside apps/<part>/ -> $(echo $inapps | tr '\n' ' ')"
  if [ -z "$stray" ] && [ -z "$inapps" ] && [ -n "$has" ]; then
    ok "container file naming: apps/<part>/Dockerfile only"
  fi
}

check_build_call() {
  local f="$1"
  grep -q 'docker/build-push-action' "$f" || return 0
  grep -qE '^[[:space:]]*context:[[:space:]]*\.$' "$f" ||
    bad "$(basename "$f"): buildx tanpa context: ."
  grep -qE '^[[:space:]]*file:[[:space:]]*apps/[A-Za-z0-9_.-]+/Dockerfile$' "$f" ||
    bad "$(basename "$f"): buildx tanpa file: apps/<part>/Dockerfile"
}

check_web_container() {
  local d="$1" wf="$2" quad
  [ -d "$d/apps/web" ] || return 0
  # A container is one way to ship the SPA, not the only one. A static host
  # target in apps/web/ is just as concrete, so name the file that proves it
  # instead of failing a repo that never had a web image to begin with.
  if grep -lqE 'image-web:' $wf 2>/dev/null; then
    ok "frontend: image-web job ada"
  elif [ -f "$d/apps/web/vercel.json" ] || [ -f "$d/apps/web/netlify.toml" ] ||
       [ -f "$d/apps/web/wrangler.toml" ] || [ -f "$d/apps/web/firebase.json" ]; then
    ok "frontend: web dikirim ke static host, bukan image"
  else
    badid C3 "frontend: apps/web/ ada tapi tanpa job image-web dan tanpa target static host"
  fi
  quad=$(find "$d" \( -name node_modules -o -name .git \) -prune -o \
    -type f \( -name '*.container' -o -name '*.quadlet' \) -print 2>/dev/null)
  if [ -n "$quad" ] && grep -qE '^PublishPort=127\.0\.0\.1:[0-9]+:8080$' $quad 2>/dev/null; then
    ok "frontend: quadlet mem-publish port loopback"
  else
    warn "frontend: belum ada quadlet web dengan PublishPort 127.0.0.1:<port>:8080"
  fi
}

check_pull_fails_closed() {
  local d="$1" script="$2"
  grep -q 'ghcr.io' "$d/$script" 2>/dev/null || return 0
  grep -qE 'podman pull' "$d/$script" 2>/dev/null || return 0
  # a pull whose failure stops the deploy is already fail-closed
  if grep -qE '(if ! podman pull|podman pull.*\|\|[[:space:]]*(fail|die|exit))' "$d/$script"; then
    ok "pull: gagal pull = deploy gagal"
  elif grep -qE 'if podman pull' "$d/$script"; then
    grep -qiE 'manifest unknown|no such manifest|manifest for .* not found' "$d/$script" &&
      ok "pull: hanya manifest-unknown yang dianggap 'tidak berubah'" ||
      bad "pull: 'if podman pull' tanpa pembeda manifest-unknown (registry mati = deploy sukses)"
  else
    warn "pull: tidak ada guard eksplisit di sekitar podman pull"
  fi
}

check_path_filter_table() {
  local d="$1" wf="$2" test
  grep -lqE '^[[:space:]]+changes:' $wf 2>/dev/null || return 0
  test=$(find "$d" \( -name node_modules -o -name .git \) -prune -o \
    -type f \( -name 'path-filter-test.sh' -o -name '*path-filter*test*' \) -print -quit 2>/dev/null)
  [ -n "$test" ] && ok "changes: tabel path filter ada (${test#$d/})" ||
    bad "changes: job changes tanpa tabel uji path filter"
}

# ------------------------------------------------- workflow budget (W9-W11) ---
# 9  a job that waits on another workflow's run must not live inside a Class A
#    workflow: the poll owns the CI wall and hides a green CI behind a red Coverage
# 10 Dependabot PRs run quality + contract + security only; the guard is a
#    pull_request condition on `dependabot[bot]` and never applies to push
# 11 one gate command per workflow run: two jobs may not run the same check/test
#    command, and a composite gate may not sit next to the steps it already runs
job_lines() { # emit "<job>\t<line>" for every line under jobs:
  awk '
    /^jobs:[[:space:]]*$/ { injobs=1; next }
    injobs && /^[^[:space:]#]/ { injobs=0 }
    injobs && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
      j=$0; sub(/^  /,"",j); sub(/:.*/,"",j); print "JOB\t" j; next }
    injobs { print j "\t" $0 }
  ' "$1"
}

check_cross_workflow_poll() {
  local f="$1" hits
  # Class A only: pull_request, or push to a branch. A tag-driven release or a
  # schedule may legitimately wait on another run; a CI workflow may not, because
  # that wait owns the CI wall.
  awk '
    /^on:[[:space:]]*$/ { inon=1; next }
    inon && /^[^[:space:]#]/ { inon=0 }
    inon && /^[[:space:]]*pull_request:/ { found=1 }
    inon && /^[[:space:]]*push:/ { inpush=1; next }
    inon && inpush && /^[[:space:]]*(tags|tags-ignore):/ { inpush=0; next }
    inon && inpush && /^[[:space:]]*(branches|branches-ignore):/ { found=1; inpush=0; next }
    END { exit(found ? 0 : 1) }' "$f" || { note "$(basename "$f"): W9 bukan workflow Class A, dilewati"; return 0; }
  # a runner that queries another workflow's runs and sleeps between attempts
  hits=$(job_lines "$f" | awk -F'\t' '
    /^JOB\t/ { j=substr($0,5); next }
    $2 ~ /actions\/workflows\/[A-Za-z0-9_.-]+\.ya?ml\/runs/ { print j }
  ' | sort -u)
  if [ -z "$hits" ]; then
    note "$(basename "$f"): tidak ada job yang polling workflow lain"
    return 0
  fi
  # a single lookup is not a poll; only a retry loop owns the wall
  if grep -qE '^[[:space:]]+sleep [0-9]+' "$f"; then
    bad "$(basename "$f"): W9 job polling workflow lain di dalam CI -> $(echo $hits | tr '\n' ' ')"
  else
    warn "$(basename "$f"): W9 query workflow lain tanpa loop ($(echo $hits | tr '\n' ' '))"
  fi
}

check_dependabot_guard() {
  local d="$1" wf badjobs
  wf=$(ls "$d"/.github/workflows/*.y*ml 2>/dev/null)
  if grep -lqE 'dependabot\[bot\]' $wf 2>/dev/null; then
    # every place that names the bot must also gate on the event, or it would run on push
    badjobs=$(for f in $wf; do job_lines "$f" | awk -F'\t' -v file="$(basename "$f")" '
      /^JOB\t/ { j=substr($0,5); guard[j]=0; seen[j]=0; next }
      /dependabot\[bot\]/ { seen[j]=1 }
      /event_name/ { if ($0 ~ /pull_request/ || $0 ~ /!=[[:space:]]*.push/) guard[j]=1 }
      END { for (k in seen) if (seen[k] && !guard[k]) print file": "k }
    '; done)
    [ -n "$badjobs" ] &&
      bad "W10 guard dependabot tanpa syarat pull_request -> $(echo $badjobs | tr '\n' ' ')" ||
      ok "W10 guard dependabot dibatasi pull_request"
  else
    # a policy choice with a real cost (a Dependabot PR proves less), so it warns and
    # names the lever instead of reddening every repo at once; the owning team decides
    warn "W10 tidak ada guard Dependabot: PR dependabot menjalankan graf penuh (image/e2e/coverage)"
  fi
}

# Commands that mean "run the project gate", and the composite gates that already
# run them. A composite next to its own parts is the duplication W11 forbids.
GATE_PRIM='(^|[^A-Za-z0-9_.-])\./task[[:space:]]+(check|test|ci-fast|fmt-check|lint)([[:space:]]|$)|(^|[^A-Za-z0-9_.-])nimble[[:space:]]+test([[:space:]]|$)|(^|[^A-Za-z0-9_.-])pnpm[[:space:]]+(test|run[[:space:]]+test|audit)([[:space:]]|$)|(^|[^A-Za-z0-9_.-])go[[:space:]]+test([[:space:]]|$)|(^|[^A-Za-z0-9_.-])npm[[:space:]]+test([[:space:]]|$)'
GATE_COMPOSITE='(^|[^A-Za-z0-9_.-])\./task[[:space:]]+(ci|ci-fast|ci-repeat|release)([[:space:]]|$)'

check_duplicate_gates() {
  local f="$1" cmds dups comp prim scoped_jobs
  # job -> each `run:` one-liner that matches a gate command
  cmds=$(job_lines "$f" | awk -F'\t' -v prim="$GATE_PRIM" '
    /^JOB\t/ { j=substr($0,5); next }
    $2 ~ /^[[:space:]]*-?[[:space:]]*run:[[:space:]]*/ && $2 ~ prim {
      c=$2; sub(/^[[:space:]]*-?[[:space:]]*run:[[:space:]]*/,"",c); sub(/[[:space:]]+$/,"",c)
      print j "\t" c }
  ')
  if [ -z "$cmds" ]; then
    note "$(basename "$f"): tidak ada perintah gate di CI"
    return 0
  fi
  # a job that sets its own test scope runs a different thing, not a duplicate
  # Space-joined on purpose: `awk -v` cannot carry a newline. BSD awk (macOS)
  # dies with "newline in string" where gawk accepts it, and a failed awk prints
  # nothing, which reads exactly like "no duplicates" — the check passed silently.
  scoped_jobs=$(job_lines "$f" | awk -F'\t' '
    /^JOB\t/ { j=substr($0,5); next }
    $2 ~ /[A-Z_]*SCOPE[A-Z_]*:/ { print j }' | sort -u | tr '\n' ' ')
  dups=$(printf '%s\n' "$cmds" | awk -F'\t' -v skip="$scoped_jobs" '
    BEGIN { n=split(skip, a, " "); for (i=1;i<=n;i++) if (a[i]!="") s[a[i]]=1 }
    !s[$1] { print $2 }' | sed 's/[[:space:]]\+/ /g' | sort | uniq -d)
  [ -n "$dups" ] && while IFS= read -r c; do
    [ -n "$c" ] && bad "$(basename "$f"): W11 perintah gate dijalankan dua job -> $c"
  done <<EOF
$dups
EOF
  # a composite gate next to the parts it already runs
  comp=$(printf '%s\n' "$cmds" | awk -F'\t' -v c="$GATE_COMPOSITE" '$2 ~ c {print $1": "$2}')
  prim=$(printf '%s\n' "$cmds" | awk -F'\t' -v p="$GATE_PRIM" -v c="$GATE_COMPOSITE" '$2 ~ p && $2 !~ c {print $2}' |
    sed 's/[[:space:]]\+/ /g' | sort -u | tr '\n' ' ')
  if [ -n "$comp" ]; then
    case "$prim" in
      *"./task check"*|*"./task test"*)
        bad "$(basename "$f"): W11 composite gate berdampingan dengan bagiannya -> $comp| bagian: $prim" ;;
      *) note "$(basename "$f"): W11 composite gate tanpa duplikasi" ;;
    esac
  elif [ -z "$dups" ]; then
    note "$(basename "$f"): W11 tidak ada perintah gate ganda"
  fi
}

# -------------------------------------------------------------- per project ---
check_repo() {
  local d="$1" name stacks wf deploy
  CUR_REPO="$d"
  name=$(basename "$d")
  REPO_FAILS=0
  stacks=$(stacks_of "$d")
  printf '\n%s\n' "$name ($(echo $stacks | tr ' ' ','))"

  # W1 workflows
  wf=$(ls "$d"/.github/workflows/*.y*ml 2>/dev/null)
  if [ -z "$wf" ]; then
    bad "tidak ada .github/workflows/*.yml"
  else
    ok "$(echo "$wf" | wc -l | tr -d ' ') workflow"
    local f
    for f in $wf; do
      check_timeouts "$f"; check_injection "$f"; check_paths_filter "$f"
      check_gate_skips "$f"; check_build_call "$f"
      check_cross_workflow_poll "$f"; check_duplicate_gates "$f"
    done
    check_dependabot_guard "$d"
    check_web_container "$d" "$wf"
    check_path_filter_table "$d" "$wf"
  fi

  # container file naming is a repo-wide rule, independent of CI
  check_dockerfile "$d"

  # W4 secret scan
  if [ -n "$wf" ] && grep -liE 'gitleaks|trufflehog|secret-scan' $wf 2>/dev/null | grep -q .; then
    ok "secret scan ada di CI"
  else
    bad "tidak ada secret scan (gitleaks/trufflehog) di CI"
  fi

  # W5 dependabot
  local db="$d/.github/dependabot.yml"
  if [ ! -f "$db" ]; then
    bad "tidak ada .github/dependabot.yml"
  else
    grep -qE 'package-ecosystem:[[:space:]]*"?github-actions' "$db" &&
      ok "dependabot: github-actions" || bad "dependabot tanpa ekosistem github-actions"
    case "$stacks" in
      *node*) grep -qE 'package-ecosystem:[[:space:]]*"?npm' "$db" && ok "dependabot: npm" || bad "dependabot tanpa npm";;
      *go*)   grep -qE 'package-ecosystem:[[:space:]]*"?gomod' "$db" && ok "dependabot: gomod" || bad "dependabot tanpa gomod";;
    esac
  fi

  # dependency CVE scan, per stack (rules are independent: a monorepo can be
  # node and go at once, and each gets its own gate)
  case "$stacks" in
    *node*)
      if [ -n "$wf" ] && grep -liE 'pnpm audit|npm audit|osv-scanner|aquasecurity/trivy|snyk' $wf 2>/dev/null | grep -q .; then
        ok "node: dependency CVE scan (audit/osv/trivy) ada"
      else
        bad "node: tidak ada dependency CVE scan (pnpm audit / osv-scanner / trivy)"
      fi;;
  esac
  case "$stacks" in
    *go*)
      grep -rq 'govulncheck' "$d"/.github/workflows 2>/dev/null &&
        ok "go: govulncheck ada" || bad "go: tidak ada govulncheck (go.mod terdeteksi)"
      ;;
  esac
  case "$stacks" in
    *nim*)
      if grep -rqE '[0-9a-f]{7,40}' "$d"/*.nimble "$d"/config.nims 2>/dev/null; then
        ok "nim: dependency dipin (commit ref di .nimble/config.nims)"
      else
        warn "nim: tidak ada pin commit di .nimble/config.nims (pin manual)"
      fi
      note "nim: tidak ada scanner CVE untuk paket Nim; gitleaks + review pin yang berlaku";;
    *unknown*)
      warn "stack tidak dikenali, aturan dependency di-skip (tambah deteksi di stacks_of)";;
  esac

  # deploy contract
  if ! deploy=$(deploy_script "$d"); then
    note "tanpa deploy script (project statis / tidak di-deploy lewat VPS)"
  else
    printf '  %sdeploy: %s%s\n' "$DIM" "$deploy" "$RST"
    grep -qF -- "$REF_GUARD" "$d/$deploy" &&
      ok "ref guard fail-closed, bentuk persis" ||
      bad "ref guard tidak sesuai (harus: $REF_GUARD)"
    grep -qE 'flock[[:space:]]' "$d/$deploy" &&
      ok "flock lock ada" || bad "tidak ada flock"
    if grep -qE 'podman (tag|build)[^\n]*\$\{?(REVID|COMMIT_SHA|GITHUB_SHA|SHA|REV)\}?' "$d/$deploy"; then
      bad "ada tag image pakai commit SHA (harus :local / :prev saja)"
    else
      ok "tidak ada tag commit SHA"
    fi
    grep -qE ':local' "$d/$deploy" && grep -qE ':prev' "$d/$deploy" &&
      ok ":local dan :prev dipakai" || bad ":local/:prev tidak lengkap"
    # retention: a podman tag whose target is neither :local nor :prev leaves a third
    # tag in the store. §7 lists the documented exceptions; anything else is drift.
    # Every deploy script in the repo is read, not just the one D1 resolved: the
    # RC/rollback/cutover scripts rotate tags too, and a `:release` written in
    # cutover.sh was invisible while only deploy-vps.sh was inspected.
    check_retention_tags "$d"
    grep -qiE 'smoke|health|readyz|wait_healthy' "$d/$deploy" && ok "smoke/health check ada" ||
      { case "$deploy" in *static*) warn "tanpa smoke eksplisit (deploy static)";; *) bad "tidak ada smoke/health check";; esac; }
    grep -qiE 'rollback|:prev' "$d/$deploy" && ok "jalur rollback ada" || bad "tidak ada rollback"
    check_pull_fails_closed "$d" "$deploy"
  fi

  REPOS=$((REPOS+1))
  [ "$REPO_FAILS" -eq 0 ] && printf '  %s=> PASS%s\n' "$GREEN" "$RST"
}

# -------------------------------------------------------------------- main ---
if [ -n "$ROOT" ]; then
  for r in "$@"; do
    [ -d "$r" ] || { echo "error: not a directory: $r" >&2; exit 2; }
    check_repo "$(cd "$r" && pwd)"
  done
else
  for r in "$HOME"/Projects/*/; do
    r=${r%/}
    [ -d "$r/.git" ] || continue
    check_repo "$r"
  done
fi

printf '\n%s repos, %s violasi, %s warning\n' "$REPOS" "$FAILS" "$WARNS"
[ "$FAILS" -eq 0 ]
