#!/usr/bin/env bash
# Deploy LVGL Dashboard to Home Assistant OS
# Usage: ./scripts/deploy.sh [host]
#
# Creates a tar archive of the addon directory structure and extracts
# it on the remote host. This flattens ha_app/ contents to the addon root
# alongside the build/source files.

set -euo pipefail

HOST="${1:-root@192.168.46.222}"
REMOTE_PATH="/addons/ha_app_lvgl_dashboard"
TMPTAR="/tmp/lvgl_dashboard_deploy.tar.gz"

echo "==> Deploying to ${HOST}:${REMOTE_PATH}"

# Build the tar archive with the flattened structure
echo "--- Building deployment archive..."
(
    cd /workspace

    # Create tar with the correct addon directory layout:
    # - ha_app/* gets flattened to root (config.yaml, Dockerfile, rootfs/, etc.)
    # - build files, src/, and web/ go to root as-is
    # Uses whole directories so new files are automatically included.
    tar czf "${TMPTAR}" \
        --transform='s|^ha_app/||' \
        --exclude='.zig-cache' \
        --exclude='zig-out' \
        --exclude='.git' \
        --exclude='scripts' \
        --exclude='web/dashboard.wasm' \
        ha_app \
        build.zig \
        build.zig.zon \
        lv_conf.h \
        src \
        web
)

ARCHIVE_SIZE=$(du -h "${TMPTAR}" | cut -f1)
echo "--- Archive: ${ARCHIVE_SIZE}"

# Ensure remote directory exists and is clean
echo "--- Preparing remote directory..."
ssh "${HOST}" "rm -rf ${REMOTE_PATH} && mkdir -p ${REMOTE_PATH}"

# Transfer and extract
echo "--- Transferring..."
scp -q "${TMPTAR}" "${HOST}:/tmp/lvgl_dashboard_deploy.tar.gz"

echo "--- Extracting on remote..."
ssh "${HOST}" "cd ${REMOTE_PATH} && tar xzf /tmp/lvgl_dashboard_deploy.tar.gz && rm /tmp/lvgl_dashboard_deploy.tar.gz"

# Clean up local temp
rm -f "${TMPTAR}"

# Verify remote structure
echo "--- Remote directory contents:"
ssh "${HOST}" "ls -la ${REMOTE_PATH}/"

echo ""
echo "==> Reloading addon store..."
ssh "${HOST}" "docker exec addon_a0d7b954_ssh ha store reload" 2>&1 || true

echo ""
echo "==> Deploy complete."
echo "    If this is the first deploy, install the addon via:"
echo "      ssh ${HOST} docker exec addon_a0d7b954_ssh ha addons install local_ha_app_lvgl_dashboard"
echo "    Then start it:"
echo "      ssh ${HOST} docker exec addon_a0d7b954_ssh ha addons start local_ha_app_lvgl_dashboard"
echo "    Monitor build logs:"
echo "      ssh ${HOST} docker exec addon_a0d7b954_ssh ha addons logs local_ha_app_lvgl_dashboard"
