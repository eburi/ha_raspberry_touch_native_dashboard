#!/usr/bin/env bash
set -e

# HA App entry point for LVGL Dashboard.
# Reads user configuration from /data/options.json and launches the Zig server.

# Source bashio for logging helpers (optional, graceful fallback)
if [ -f /usr/lib/bashio/bashio.sh ]; then
    # shellcheck source=/dev/null
    source /usr/lib/bashio/bashio.sh
    log_info()    { bashio::log.info "$@"; }
    log_warning() { bashio::log.warning "$@"; }
else
    log_info()    { echo "[INFO] $*"; }
    log_warning() { echo "[WARN] $*"; }
fi

log_info "Reading app configuration..."

# Read config directly from options.json (no Supervisor API dependency)
OPTIONS_FILE="/data/options.json"
if [ -f "$OPTIONS_FILE" ]; then
    PORT="$(jq -r '.port // 8765' "$OPTIONS_FILE")"
else
    log_warning "No options file found, using defaults"
    PORT="8765"
fi

log_info "Port: ${PORT}"

export PORT
export WEB_ROOT="/app/web"

# Check for display hardware
if [ -e /dev/fb0 ]; then
    log_info "Framebuffer /dev/fb0 detected"
else
    log_warning "No framebuffer — web-only mode"
fi

# SUPERVISOR_TOKEN is injected by HA when homeassistant_api: true
if [ -n "${SUPERVISOR_TOKEN:-}" ]; then
    log_info "Supervisor token present"
else
    log_warning "No SUPERVISOR_TOKEN"
fi

log_info "Starting LVGL Dashboard server on port ${PORT}"
exec /usr/local/bin/lvgl-server
