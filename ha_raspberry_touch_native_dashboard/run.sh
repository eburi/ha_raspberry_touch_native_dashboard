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
    DISPLAY_ROTATION="$(jq -r '.display_rotation // 270' "$OPTIONS_FILE")"
    SIGNALK_URL="$(jq -r '.signalk_url // ""' "$OPTIONS_FILE")"
    BACKLIGHT_SYSFS="$(jq -r '.backlight_sysfs // ""' "$OPTIONS_FILE")"
    BACKLIGHT_MAX_RAW="$(jq -r '.backlight_max_raw // 0' "$OPTIONS_FILE")"
    MQTT_HOST="$(jq -r '.mqtt_host // ""' "$OPTIONS_FILE")"
    MQTT_PORT="$(jq -r '.mqtt_port // 1883' "$OPTIONS_FILE")"
    MQTT_USERNAME="$(jq -r '.mqtt_username // ""' "$OPTIONS_FILE")"
    MQTT_PASSWORD="$(jq -r '.mqtt_password // ""' "$OPTIONS_FILE")"

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
        sail_code0:          .entity_sail_code0,
        brightness:          .entity_brightness,
        tank_fuel:           .entity_tank_fuel,
        tank_water_port:     .entity_tank_water_port,
        tank_water_stbd:     .entity_tank_water_stbd,
        tank_water_stbd_aft: .entity_tank_water_stbd_aft
    } | with_entries(select(.value != null and .value != ""))' "$OPTIONS_FILE")"
else
    log_warning "No options file found, using defaults"
    PORT="8765"
    LOG_LEVEL="info"
    DISPLAY_ROTATION="270"
    SIGNALK_URL=""
    BACKLIGHT_SYSFS=""
    BACKLIGHT_MAX_RAW="0"
    MQTT_HOST=""
    MQTT_PORT="1883"
    MQTT_USERNAME=""
    MQTT_PASSWORD=""
    ENTITY_CONFIG="{}"
fi

log_info "Port: ${PORT}"
log_info "Log level: ${LOG_LEVEL}"
log_info "Display rotation: ${DISPLAY_ROTATION}"
if [ -n "${SIGNALK_URL}" ]; then
    log_info "SignalK URL override: ${SIGNALK_URL}"
fi
if [ -n "${BACKLIGHT_SYSFS}" ]; then
    log_info "Backlight sysfs override: ${BACKLIGHT_SYSFS}"
fi
if [ "${BACKLIGHT_MAX_RAW}" -gt 0 ] 2>/dev/null; then
    log_info "Backlight max_raw override: ${BACKLIGHT_MAX_RAW}"
fi
if [ -n "${MQTT_HOST}" ]; then
    log_info "MQTT host: ${MQTT_HOST}:${MQTT_PORT}"
fi
log_info "Entity config: ${ENTITY_CONFIG}"

export PORT
export WEB_ROOT="/app/web"
export LOG_LEVEL
export DISPLAY_ROTATION
export ENTITY_CONFIG
export BACKLIGHT_MAX_RAW
export MQTT_HOST
export MQTT_PORT
export MQTT_USERNAME
export MQTT_PASSWORD

if [ -z "${BACKLIGHT_SYSFS}" ] && [ -d /sys/class/backlight ]; then
    for candidate in /sys/class/backlight/*; do
        if [ -d "${candidate}" ] && [ -w "${candidate}/brightness" ] && [ -r "${candidate}/max_brightness" ]; then
            BACKLIGHT_SYSFS="${candidate}"
            break
        fi
    done
fi

if [ -n "${BACKLIGHT_SYSFS}" ]; then
    export BACKLIGHT_SYSFS
fi

if [ -n "${SIGNALK_URL}" ]; then
    export SIGNALK_URL
fi

# Check for display hardware
if [ -e /dev/fb0 ]; then
    log_info "Framebuffer /dev/fb0 detected"
else
    log_warning "No framebuffer — web-only mode"
fi

if [ -n "${BACKLIGHT_SYSFS}" ]; then
    if [ -w "${BACKLIGHT_SYSFS}/brightness" ]; then
        log_info "Backlight control enabled via ${BACKLIGHT_SYSFS}/brightness"
    else
        log_warning "Backlight path ${BACKLIGHT_SYSFS}/brightness is not writable"
    fi
else
    log_warning "No writable backlight sysfs path found"
fi

# SUPERVISOR_TOKEN is injected by HA when homeassistant_api: true
if [ -n "${SUPERVISOR_TOKEN:-}" ]; then
    log_info "Supervisor token present"
else
    log_warning "No SUPERVISOR_TOKEN"
fi

log_info "Starting Raspberry Pi Touchscreen native Dashboard for HAOS server on port ${PORT}"
exec /usr/local/bin/lvgl-server
