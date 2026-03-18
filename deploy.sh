#!/usr/bin/env bash
set -e

# Deploy lvgl_dashboard HA App to a Home Assistant device.
#
# Usage:
#   ./deploy.sh [user@host]
#
# Default target: root@192.168.46.222
#
# This script:
# 1. Assembles a self-contained app directory in /tmp/lvgl_dashboard_app/
# 2. Copies it to /addons/lvgl_dashboard/ on the HA device via scp
# 3. Prints instructions for installing/rebuilding in HA

TARGET="${1:-root@192.168.46.222}"
APP_NAME="lvgl_dashboard"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
BUILD_DIR="/tmp/${APP_NAME}_app"

echo "=== Deploying $APP_NAME to $TARGET ==="
echo "Project dir: $PROJECT_DIR"
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
echo "=== Deploy complete ==="
echo ""
echo "Next steps on Home Assistant:"
echo "  1. Go to Settings -> Apps -> App Store"
echo "  2. Click (top right) -> Check for updates / Reload"
echo "  3. Find 'LVGL Dashboard' in the Local apps section"
echo "  4. Click Install (first time) or Rebuild (update)"
echo "  5. Start the app and check logs"
echo ""
echo "Or via CLI on the HA device:"
echo "  ha store reload && ha apps install local_$APP_NAME   # first time"
echo "  ha apps rebuild local_$APP_NAME                      # update"
echo "  ha apps start local_$APP_NAME"
echo "  ha apps logs local_$APP_NAME"
