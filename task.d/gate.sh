#!/usr/bin/env sh
#
# Canonical local gate for every qouver repo. Vendored byte-identically; fix it
# in the server repo (docs/workflows/gate.sh) and copy it out again.
#
#   ./task gate               contract + shell syntax + secret scan + repo hook (no installs)
#   ./task gate --no-hook     the same without the repo hook (for a CI job that may not
#                             install a toolchain, and for a laptop without one)
#   ./task gate-full          gate, then the repo's test hook
#
# CI runs this file in the `preflight` job, so "green on my machine" and "green
# in CI" stop being two different claims. Repo-specific commands live in two
# optional hooks:
#
#   task.d/gate.local.sh       extra static checks; must not install anything
#   task.d/gate-full.local.sh  tests; may need a toolchain or a local Postgres
#
# A hook that is absent is reported as a fact, never silently skipped.
set -eu

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

MODE=gate
HOOK=1
for arg in "$@"; do
  case "$arg" in
    gate | gate-full) MODE="$arg" ;;
    --no-hook) HOOK=0 ;;
    -h | --help)
      printf 'usage: sh task.d/gate.sh [gate|gate-full] [--no-hook]\n'
      exit 0
      ;;
    *) printf 'gate: unknown argument %s\n' "$arg" >&2; exit 2 ;;
  esac
done

FAIL=0
log() { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
bad() { printf '   FAIL: %s\n' "$*" >&2; FAIL=1; }

log "gate: golden CI/CD contract"
if [ -x "$ROOT/ops/scripts/contract-check.sh" ]; then
  "$ROOT/ops/scripts/contract-check.sh" . || bad "contract check found violations"
elif [ -f "$ROOT/ops/scripts/contract-check.sh" ]; then
  sh "$ROOT/ops/scripts/contract-check.sh" . || bad "contract check found violations"
else
  bad "ops/scripts/contract-check.sh is missing"
fi

# A syntax error in a script this repo ships fails on the host at the worst
# possible moment; a parse costs nothing and catches it here. The interpreter
# comes from the shebang, so a bash-only script is parsed by bash.
log "gate: shell syntax"
N=0
for f in "$ROOT/task" "$ROOT"/task.d/*.sh "$ROOT"/ops/scripts/*.sh "$ROOT"/tools/*.sh; do
  [ -f "$f" ] || continue
  N=$((N + 1))
  case "$(head -1 "$f")" in
    *bash*) bash -n "$f" || bad "shell syntax (bash): ${f#"$ROOT"/}" ;;
    *) sh -n "$f" || bad "shell syntax (sh): ${f#"$ROOT"/}" ;;
  esac
done
info "$N script(s) parsed"

log "gate: secret scan"
if command -v gitleaks >/dev/null 2>&1; then
  # Scope: the commits this branch would publish, i.e. everything not already on origin/main.
  # A full-history scan belongs to the weekly scheduled job (it reports what cannot be fixed
  # without rewriting history); a local gate that reddens on a six-month-old commit teaches
  # people to ignore it. Fall back to HEAD outside a clone with a remote.
  scan_opts="-1 HEAD"
  if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    base=$(git -C "$ROOT" merge-base HEAD origin/main 2>/dev/null || true)
    if [ -n "$base" ] && [ "$base" != "$(git -C "$ROOT" rev-parse HEAD)" ]; then
      scan_opts="$base..HEAD"
    fi
  fi
  if gitleaks git "$ROOT" --log-opts="$scan_opts" --no-banner --redact -v >/dev/null 2>&1; then
    info "gitleaks clean ($scan_opts)"
  else
    bad "gitleaks reported a leak in $scan_opts"
  fi
else
  info "gitleaks not installed: skipped here (CI scans with the pinned action)"
fi

if [ "$HOOK" -eq 0 ]; then
  info "--no-hook: repo hook skipped"
elif [ -f "$ROOT/task.d/gate.local.sh" ]; then
  log "gate: repo static checks"
  sh "$ROOT/task.d/gate.local.sh" || bad "repo static checks failed (task.d/gate.local.sh)"
else
  info "no task.d/gate.local.sh: this repo declares no extra static checks"
fi

if [ "$MODE" = "gate-full" ]; then
  if [ -f "$ROOT/task.d/gate-full.local.sh" ]; then
    log "gate-full: repo tests"
    sh "$ROOT/task.d/gate-full.local.sh" || bad "repo tests failed (task.d/gate-full.local.sh)"
  else
    info "no task.d/gate-full.local.sh: this repo declares no test hook"
  fi
fi

if [ "$FAIL" -ne 0 ]; then
  printf '\n!! GATE FAILED\n' >&2
  exit 1
fi
printf '\n   gate ok\n'
