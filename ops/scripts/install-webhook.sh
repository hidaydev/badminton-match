#!/usr/bin/env bash
# Install the repository's webhook definition on the host without destroying the
# secret it already holds.
#
#   ./ops/scripts/install-webhook.sh            # merge the routing into the host file
#   ./ops/scripts/install-webhook.sh --check    # report drift, change nothing
#
# The live file is /srv/qouver/config/webhook.json (mode 600). It carries the
# HMAC secret, which must never enter the repository, so this script replaces
# only `execute-command` and `command-working-directory`. The repository copy is
# the template used when the file does not exist yet.
#
# Env: MAJADU_APP_DIR, MAJADU_WEBHOOK_CONFIG.
set -Eeuo pipefail

APP_DIR="${MAJADU_APP_DIR:-/srv/qouver/apps/majadu}"
TARGET="${MAJADU_WEBHOOK_CONFIG:-/srv/qouver/config/webhook.json}"
SOURCE="$APP_DIR/monorepo/ops/webhook/webhook.json"
DISPATCH="$APP_DIR/scripts/deploy-dispatch.sh"
EXPECT_DIR="$APP_DIR"
MODE="install"

case "${1:-}" in
  "") ;;
  --check) MODE="check" ;;
  -h|--help)
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *) printf 'install-webhook: unknown argument %s\n' "$1" >&2; exit 2 ;;
esac

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

if [ ! -f "$TARGET" ]; then
  if [ "$MODE" = "check" ]; then
    log "webhook: $TARGET is missing"
    exit 1
  fi
  [ -f "$SOURCE" ] || { printf 'install-webhook: %s is missing\n' "$SOURCE" >&2; exit 1; }
  mkdir -p "$(dirname "$TARGET")"
  install -m 600 "$SOURCE" "$TARGET"
  log "webhook: installed the template at $TARGET; set the HMAC secret before enabling it"
  exit 0
fi

grep -q '"execute-command"' "$TARGET" ||
  { printf 'install-webhook: %s has no execute-command; refusing to replace it\n' "$TARGET" >&2; exit 1; }

current=$(sed -n 's/.*"execute-command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$TARGET" | head -1)
if [ "$MODE" = "check" ]; then
  if [ "$current" = "$DISPATCH" ]; then
    log "webhook: $TARGET already routes to $DISPATCH"
    exit 0
  fi
  log "webhook: $TARGET routes to '${current:-<none>}', expected $DISPATCH"
  exit 1
fi

escaped_dispatch=$(printf '%s' "$DISPATCH" | sed 's/[&|\\]/\\&/g')
escaped_dir=$(printf '%s' "$EXPECT_DIR" | sed 's/[&|\\]/\\&/g')
tmp=$(mktemp "${TMPDIR:-/tmp}/majadu-webhook.XXXXXX")
trap 'rm -f "$tmp"' EXIT

sed -e "s|\"execute-command\":[[:space:]]*\"[^\"]*\"|\"execute-command\": \"$escaped_dispatch\"|" \
    -e "s|\"command-working-directory\":[[:space:]]*\"[^\"]*\"|\"command-working-directory\": \"$escaped_dir\"|" \
    "$TARGET" >"$tmp"

if cmp -s "$tmp" "$TARGET"; then
  log "webhook: $TARGET already routes to $DISPATCH"
  exit 0
fi

install -m 600 "$tmp" "$TARGET"
log "webhook: $TARGET now routes to $DISPATCH"
log "webhook: restart the daemon for the change to take effect: systemctl --user restart webhook"
