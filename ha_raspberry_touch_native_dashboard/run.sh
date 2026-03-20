#!/usr/bin/env bash
set -e

# HA App entry point for Raspberry Pi Touchscreen native Dashboard for HAOS.
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
    LOG_LEVEL="$(jq -r '.log_level // "info"' "$OPTIONS_FILE")"
    SIGNALK_URL="$(jq -r '.signalk_url // ""' "$OPTIONS_FILE")"

    # Build entity config JSON from options (only include non-empty values)
    ENTITY_CONFIG="$(jq -c '{
        latitude:            .entity_latitude,
        longitude:           .entity_longitude,
        log:                 .entity_log,
        heading:             .entity_heading,
        stw:                 .entity_stw,
        sog:                 .entity_sog,
        cog:                 .entity_cog,
        aws:                 .entity_aws,
        awa:                 .entity_awa,
        tws:                 .entity_tws,
        twd:                 .entity_twd,
        barometric_pressure: .entity_barometric_pressure,
        distance_24h:        .entity_distance_24h,
        speed_24h:           .entity_speed_24h,
        datetime:            .entity_datetime,
        sail_main:           .entity_sail_main,
        sail_jib:            .entity_sail_jib,
        sail_code0:          .entity_sail_code0
    } | with_entries(select(.value != null and .value != ""))' "$OPTIONS_FILE")"
else
    log_warning "No options file found, using defaults"
    PORT="8765"
    LOG_LEVEL="info"
    SIGNALK_URL=""
    ENTITY_CONFIG="{}"
fi

log_info "Port: ${PORT}"
log_info "Log level: ${LOG_LEVEL}"
if [ -n "${SIGNALK_URL}" ]; then
    log_info "SignalK URL override: ${SIGNALK_URL}"
fi
log_info "Entity config: ${ENTITY_CONFIG}"

export PORT
export WEB_ROOT="/app/web"
export LOG_LEVEL
export ENTITY_CONFIG
if [ -n "${SIGNALK_URL}" ]; then
    export SIGNALK_URL
fi

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

log_info "Starting Raspberry Pi Touchscreen native Dashboard for HAOS server on port ${PORT}"
exec /usr/local/bin/lvgl-server
