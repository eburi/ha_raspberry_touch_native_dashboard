#!/usr/bin/env bash
set -euo pipefail

# Deploy ha_raspberry_touch_native_dashboard HA App to a Home Assistant device.
#
# Usage:
#   tools/deploy.sh [user@host]
#
# Default target: root@192.168.46.222
#
# This script:
# 1. Builds the WASM module locally (sanity check)
# 2. Assembles a self-contained app directory in /tmp/
# 3. Copies it to /addons/ha_raspberry_touch_native_dashboard/ on the HA device
# 4. Installs (first time) or rebuilds the app on the HA device
# 5. Starts the app and tails logs

TARGET="${1:-root@192.168.46.222}"
APP_NAME="ha_raspberry_touch_native_dashboard"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="/tmp/${APP_NAME}_app"

# Add project-local zig to PATH (installed under .local/bin)
export PATH="$PROJECT_DIR/.local/bin:$PATH"

echo "=== Deploying $APP_NAME to $TARGET ==="
echo "Project dir: $PROJECT_DIR"
echo ""

# 0. Build locally first; abort deployment on build errors.
if ! command -v zig >/dev/null 2>&1; then
    echo "Error: zig is required for local pre-deploy build verification." >&2
    echo "Install zig locally or run deploy from an environment with zig available." >&2
    exit 1
fi

echo "Running local build check (zig build wasm)..."
(cd "$PROJECT_DIR" && zig build wasm -Doptimize=ReleaseSmall)
echo "Local build check passed."
echo ""

# 1. Assemble the app directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Copy HA app files
cp "$PROJECT_DIR/$APP_NAME/config.yaml"  "$BUILD_DIR/"
cp "$PROJECT_DIR/$APP_NAME/Dockerfile"   "$BUILD_DIR/"
cp "$PROJECT_DIR/$APP_NAME/run.sh"       "$BUILD_DIR/"
cp "$PROJECT_DIR/$APP_NAME/build.yaml"   "$BUILD_DIR/" 2>/dev/null || true

# Copy build system and source (needed by Dockerfile)
cp "$PROJECT_DIR/build.zig"     "$BUILD_DIR/"
cp "$PROJECT_DIR/build.zig.zon" "$BUILD_DIR/"
cp "$PROJECT_DIR/lv_conf.h"     "$BUILD_DIR/"
cp -r "$PROJECT_DIR/src"        "$BUILD_DIR/src"
cp -r "$PROJECT_DIR/web"        "$BUILD_DIR/web"

echo "Assembled app in $BUILD_DIR:"
ls -la "$BUILD_DIR/"
echo ""

# 2. Copy to HA device (clean target first to remove stale files)
echo "Copying to $TARGET:/addons/$APP_NAME/ ..."
ssh "$TARGET" "rm -rf /addons/$APP_NAME && mkdir -p /addons/$APP_NAME"
scp -r "$BUILD_DIR/"* "$TARGET:/addons/$APP_NAME/"
echo ""

# 3. Reload the app store so HA picks up the new/updated files
echo "Reloading HA app store..."
ssh "$TARGET" "ha store reload" || true
sleep 2

# 4. Check if the app is already installed, install or rebuild accordingly
echo "Checking app status..."
APP_SLUG="local_$APP_NAME"

if ssh "$TARGET" "ha apps info $APP_SLUG" >/dev/null 2>&1; then
    echo "App already installed. Rebuilding..."
    ssh "$TARGET" "ha apps rebuild $APP_SLUG"
else
    echo "App not installed. Installing..."
    ssh "$TARGET" "ha apps install $APP_SLUG"
fi

# 5. Start the app
echo "Starting app..."
ssh "$TARGET" "ha apps start $APP_SLUG" || true
sleep 2

# 6. Tail logs
echo ""
echo "=== Deploy complete ==="
echo ""
echo "Tailing logs (Ctrl+C to stop):"
echo ""
ssh "$TARGET" "ha apps logs $APP_SLUG --follow" || \
    echo "(Could not tail logs — check manually with: ha apps logs $APP_SLUG)"
