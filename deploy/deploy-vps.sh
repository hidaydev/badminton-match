#!/bin/bash
# Deploy majadu-api ke VPS via webhook (pola sds-monorepo).
# Trigger: GitHub webhook (push @ main) -> webhook.service -> script ini.
# Deploy hanya jika apps/api/ berubah; build image lokal; restart unit quadlet.
# Lokasi server: /srv/qouver/apps/majadu/scripts/deploy-vps.sh (source of truth: repo deploy/deploy-vps.sh)
set -euo pipefail
REPO="${1:-badminton-match}"
REF="${2:-}"
LOG="/srv/qouver/apps/majadu/logs/deploy.log"
mkdir -p /srv/qouver/apps/majadu/logs
echo "[$(date '+%Y-%m-%d %H:%M:%S')] deploy trigger: $REPO ref=$REF" | tee -a "$LOG"

# Fail-closed: hanya deploy untuk push ke branch main
if [ -n "$REF" ] && [ "$REF" != "refs/heads/main" ]; then
  echo "==> skip: ref=$REF (bukan main)" | tee -a "$LOG"
  exit 0
fi

switch_local_image() {
  echo "==> switching quadlet ke image lokal + Pull=never + AutoUpdate=local" | tee -a "$LOG"
  sed -i 's|^Image=.*|Image=localhost/majadu-api:local|' ~/.config/containers/systemd/majadu-api.container
  if grep -q '^Pull=' ~/.config/containers/systemd/majadu-api.container; then
    sed -i 's|^Pull=.*|Pull=never|' ~/.config/containers/systemd/majadu-api.container
  else
    sed -i '/^Image=/a Pull=never' ~/.config/containers/systemd/majadu-api.container
  fi
  if grep -q '^AutoUpdate=' ~/.config/containers/systemd/majadu-api.container; then
    sed -i 's|^AutoUpdate=.*|AutoUpdate=local|' ~/.config/containers/systemd/majadu-api.container
  else
    sed -i '/^Pull=/a AutoUpdate=local' ~/.config/containers/systemd/majadu-api.container
  fi
  systemctl --user daemon-reload 2>&1 | tee -a "$LOG"
}

MONO_DIR="/srv/qouver/apps/majadu/monorepo"
if [ -d "$MONO_DIR/.git" ]; then
  cd "$MONO_DIR"
  OLD_REV=$(git rev-parse HEAD 2>/dev/null || echo "")
  git fetch origin main && git reset --hard origin/main 2>&1 | tee -a "$LOG"
  NEW_REV=$(git rev-parse HEAD 2>/dev/null || echo "")
  CHANGED=$(git diff --name-only "$OLD_REV" "$NEW_REV" 2>/dev/null || echo "")
else
  echo "==> first clone" | tee -a "$LOG"
  git clone https://github.com/hidaydev/badminton-match.git "$MONO_DIR" 2>&1 | tee -a "$LOG"
  cd "$MONO_DIR"
  git checkout -B main origin/main 2>&1 | tee -a "$LOG"
  if [ -d apps/api ]; then CHANGED="apps/api/"; else CHANGED=""; fi
fi

if echo "$CHANGED" | grep -q "^apps/api/"; then
  echo "==> deploying API (apps/api berubah)" | tee -a "$LOG"
  cd "$MONO_DIR/apps/api"
  podman build -t localhost/majadu-api:local . 2>&1 | tail -20 | tee -a "$LOG"
  switch_local_image
  systemctl --user restart majadu-api 2>&1 | tee -a "$LOG"
  sleep 3
  systemctl --user is-active majadu-api 2>&1 | tee -a "$LOG"
  curl -s https://api.qouver.com/majadu/healthz 2>&1 | tee -a "$LOG"
else
  echo "==> tidak ada perubahan apps/api — skip deploy" | tee -a "$LOG"
fi

echo "[$(date)] done $REPO" | tee -a "$LOG"