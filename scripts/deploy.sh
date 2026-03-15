#!/usr/bin/env bash
# Deploy LVGL Dashboard to Home Assistant OS
# Usage: ./scripts/deploy.sh [host]

set -euo pipefail

HOST="${1:-root@192.168.46.222}"
REMOTE_PATH="/addons/ha_app_lvgl_dashboard"

echo "==> Deploying to ${HOST}:${REMOTE_PATH}"

# Sync files (excluding build artifacts and .git)
rsync -avz --delete \
    --exclude='.git/' \
    --exclude='zig-out/' \
    --exclude='zig-cache/' \
    --exclude='.zig-cache/' \
    --exclude='web/dashboard.wasm' \
    /workspace/ \
    "${HOST}:${REMOTE_PATH}/"

echo "==> Reloading add-ons"
ssh "${HOST}" "ha addons reload"

echo "==> Done. Check HA UI for the add-on."
echo "    Install/restart from: Settings → Add-ons → LVGL Dashboard"
