#!/usr/bin/env bash
# Behavioural smoke test for a live API.
#
#   ./ops/scripts/smoke.sh [base_url] [expected_version]
#
# Called by cutover.sh and after a deploy. It checks what a user would notice
# rather than that a port is open: the version that answers is the version that
# was released, readiness is green, and the routes that must stay private are
# not reachable without credentials.
set -euo pipefail

BASE_URL="${1:-${MAJADU_HEALTH_URL:-http://127.0.0.1:8080}}"
EXPECTED_VERSION="${2:-${MAJADU_EXPECTED_VERSION:-}}"

if [ -z "$EXPECTED_VERSION" ]; then
  EXPECTED_VERSION=$(tr -d '[:space:]' <"$(dirname "$0")/../../VERSION" 2>/dev/null || true)
fi

failures=0

pass() { printf 'ok   %s\n' "$*"; }
fail_check() { printf 'FAIL %s\n' "$*"; failures=$((failures + 1)); }

status_of() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null) || code="000"
  printf '%s' "$code"
}

body_of() {
  curl -s --max-time 5 "$1" || true
}

body=$(body_of "$BASE_URL/version")
case "$body" in
  *"\"version\":\"$EXPECTED_VERSION\""*) pass "/version reports $EXPECTED_VERSION" ;;
  "") fail_check "/version did not answer (wanted $EXPECTED_VERSION)" ;;
  *) fail_check "/version does not report $EXPECTED_VERSION: $body" ;;
esac

case "$(body_of "$BASE_URL/healthz")" in
  *'"status":"ok"'*) pass "/healthz is ok" ;;
  *) fail_check "/healthz is not ok" ;;
esac

readiness=$(status_of "$BASE_URL/readyz")
if [ "$readiness" = "200" ]; then
  pass "/readyz is 200"
else
  fail_check "/readyz answered $readiness"
fi

metrics=$(status_of "$BASE_URL/metrics")
if [ "$metrics" = "404" ]; then
  pass "/metrics is not public"
else
  fail_check "/metrics answered $metrics, expected 404"
fi

unknown=$(status_of "$BASE_URL/s/0000notacode0000")
if [ "$unknown" = "404" ]; then
  pass "an unknown share code is 404"
else
  fail_check "an unknown share code answered $unknown, expected 404"
fi

me=$(status_of "$BASE_URL/auth/me")
if [ "$me" = "401" ]; then
  pass "/auth/me refuses anonymous callers"
else
  fail_check "/auth/me answered $me, expected 401"
fi

if [ "$failures" -gt 0 ]; then
  printf 'smoke: %d check(s) failed against %s\n' "$failures" "$BASE_URL" >&2
  exit 1
fi
printf 'smoke: all checks passed against %s\n' "$BASE_URL"
