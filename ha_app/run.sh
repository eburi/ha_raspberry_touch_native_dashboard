#!/usr/bin/env bash
# Run script for LVGL Dashboard HA addon
# Reads configuration from /data/options.json (set by HA from config schema)

set -e

# Read port from HA options (jq is installed in runtime image)
if [ -f /data/options.json ]; then
    PORT=$(jq -r '.port // 8765' /data/options.json)
else
    PORT="${PORT:-8765}"
fi

export PORT
export WEB_ROOT="/usr/local/share/lvgl-dashboard/web"

echo "[LVGL Dashboard] Starting server on port ${PORT}"
echo "[LVGL Dashboard] Web root: ${WEB_ROOT}"

# Check for display hardware
if [ -e /dev/fb0 ]; then
    echo "[LVGL Dashboard] Framebuffer /dev/fb0 detected"
else
    echo "[LVGL Dashboard] No framebuffer — web-only mode"
fi

# SUPERVISOR_TOKEN is injected by HA when homeassistant_api: true
if [ -n "${SUPERVISOR_TOKEN}" ]; then
    echo "[LVGL Dashboard] Supervisor token present"
else
    echo "[LVGL Dashboard] WARNING: No SUPERVISOR_TOKEN"
fi

exec /usr/local/bin/lvgl-server
