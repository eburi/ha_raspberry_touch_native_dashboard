# Project Instructions

## Home Assistant App Development

- Use https://developers.home-assistant.io/docs/apps as the primary reference for how to build Home Assistant Apps. Always consult this documentation when making decisions about app structure, configuration, packaging, or deployment.

## Terminology

- This project is a **Home Assistant App**, not an "add-on". Always use `ha apps` commands instead of `ha addons`. For example:
  - `ha apps install` (not `ha addons install`)
  - `ha apps start` (not `ha addons start`)
  - `ha apps logs` (not `ha addons logs`)
  - `ha apps reload` (not `ha addons reload`)
- In documentation, comments, and code, refer to this as an "app" not an "addon" or "add-on".

## Deployment & Testing

- The local Home Assistant instance runs on a Raspberry Pi. Use SSH to connect for deployment, testing, and debugging:
  - Default host: `root@192.168.46.222`
  - App path on device: `/addons/lvgl_dashboard`
  - SSH into HA to run commands, check logs, restart the app, etc.
  - Use `docker exec addon_a0d7b954_ssh ha apps ...` to interact with the HA CLI from SSH.

## Reference Implementation

- Use https://github.com/eburi/sea_state_analyzer/ as a reference for a Home Assistant App that is already published. It demonstrates:
  - GitHub Actions workflows for automated publishing
  - Proper HA App repository structure
  - CI/CD pipeline for building and releasing HA Apps
  - When setting up workflows or publishing automation, refer to this repo's patterns.
