#!/usr/bin/env bash
# Deploy majadu-api ke VPS — pull image ghcr.io + restart systemd user unit.
#
# Prasyarat sekali (belum otomatis di script ini):
#   - DNS api.qouver.com → A → <vps-ip>
#   - Caddy site (deploy/Caddyfile.api.qouver.com) sudah di-apply (butuh sudo)
#   - Env file ada di VPS: /srv/qouver/majadu/env/majadu-{dev,prod}.env (chmod 600)
#
# Usage:
#   ./scripts/deploy.sh setup dev   # sekali: install quadlet unit + enable service
#   ./scripts/deploy.sh dev         # update: pull image terbaru + restart
#   ./scripts/deploy.sh prod        # update instance prod
set -euo pipefail

VPS="${VPS:-user@198.51.100.10}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")/deploy"

MODE="${1:-}"
INSTANCE="${2:-}"
if [ -z "$INSTANCE" ]; then
  INSTANCE="$MODE"
  MODE="update"
fi

case "$INSTANCE" in
  dev)  UNIT="majadu-api-dev" ;;
  prod) UNIT="majadu-api" ;;
  *) echo "usage: deploy.sh [setup] dev|prod" >&2; exit 1 ;;
esac

echo "==> instance: $INSTANCE (unit: $UNIT)"

if [ "$MODE" = "setup" ]; then
  echo "==> [setup] install quadlet unit + enable service"
  ssh "$VPS" "mkdir -p ~/.config/containers/systemd"
  scp -q "$DEPLOY_DIR/$UNIT.container" "$VPS:~/.config/containers/systemd/"
  ssh "$VPS" "loginctl enable-linger \$(whoami) 2>/dev/null || true; systemctl --user daemon-reload; systemctl --user enable --now $UNIT"
  echo "==> setup selesai. Env file harus ada di VPS:"
  echo "    /srv/qouver/majadu/env/majadu-${INSTANCE}.env (chmod 600)"
else
  echo "==> [update] restart unit (AutoUpdate=registry menarik image terbaru saat start)"
  ssh "$VPS" "systemctl --user restart $UNIT; sleep 2; systemctl --user --no-pager status $UNIT | head -8"
fi
