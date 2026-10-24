#!/bin/bash
# Deploy majadu-api ke VPS via webhook (pola sds-monorepo).
# Trigger: GitHub webhook (push @ main) -> webhook.service -> script ini.
# Deploy hanya jika apps/api/ berubah; build image lokal; restart unit quadlet.
# Lokasi server: /srv/qouver/apps/majadu/scripts/deploy-vps.sh (source of truth: repo ops/scripts/deploy-vps.sh)
set -euo pipefail
REPO="${1:-badminton-match}"
REF="${2:-}"
APP_DIR="/srv/qouver/apps/majadu"
LOG="$APP_DIR/logs/deploy.log"
mkdir -p "$APP_DIR/logs"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] deploy trigger: $REPO ref=$REF" | tee -a "$LOG"

# Fail-closed: hanya deploy untuk push ke branch main
if [ "$REF" != "refs/heads/main" ]; then
  echo "==> skip: ref=${REF:-<kosong>} (bukan refs/heads/main)" | tee -a "$LOG"
  exit 0
fi

# Concurrency lock
exec 9>"$APP_DIR/.deploy.lock"
if ! flock -n 9; then
  echo "==> deploy lain sedang berjalan; keluar tanpa menunggu" | tee -a "$LOG"
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

MONO_DIR="$APP_DIR/monorepo"
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

# Self-update deploy script
REPO_SCRIPT="$MONO_DIR/ops/scripts/deploy-vps.sh"
SELF_SCRIPT="$APP_DIR/scripts/deploy-vps.sh"
if [ -f "$REPO_SCRIPT" ] && ! cmp -s "$REPO_SCRIPT" "$SELF_SCRIPT"; then
  TMP_SCRIPT="$SELF_SCRIPT.new.$$"
  if cp -f "$REPO_SCRIPT" "$TMP_SCRIPT" && chmod +x "$TMP_SCRIPT"; then
    mv -f "$TMP_SCRIPT" "$SELF_SCRIPT" \
      && echo "==> scripts/deploy-vps.sh diperbarui dari repo (berlaku deploy berikutnya)" | tee -a "$LOG"
  fi
fi

if echo "$CHANGED" | grep -q "^apps/api/"; then
  echo "==> deploying API (apps/api berubah)" | tee -a "$LOG"
  cd "$MONO_DIR/apps/api"
  if podman image exists localhost/majadu-api:local; then
    podman tag localhost/majadu-api:local localhost/majadu-api:prev 2>/dev/null || true
  fi
  podman build -t localhost/majadu-api:local . 2>&1 | tail -20 | tee -a "$LOG"
  switch_local_image
  systemctl --user restart majadu-api 2>&1 | tee -a "$LOG"

  HEALTH_URL="http://127.0.0.1:8080/healthz"
  HEALTHY=0
  for i in $(seq 1 15); do
    if curl -fsS "$HEALTH_URL" >/dev/null 2>&1; then
      HEALTHY=1
      break
    fi
    sleep 2
  done

  if [ "$HEALTHY" -eq 1 ]; then
    echo "==> [badminton-match] health gate passed (200 OK)" | tee -a "$LOG"
  else
    echo "ERROR: [badminton-match] health gate failed ($HEALTH_URL not responding). Rolling back..." | tee -a "$LOG"
    if podman image exists localhost/majadu-api:prev; then
      podman tag localhost/majadu-api:prev localhost/majadu-api:local
      systemctl --user restart majadu-api 2>&1 | tee -a "$LOG" || true
    fi
    exit 1
  fi
else
  echo "==> tidak ada perubahan apps/api — skip deploy" | tee -a "$LOG"
fi

echo "[$(date)] done $REPO" | tee -a "$LOG"
