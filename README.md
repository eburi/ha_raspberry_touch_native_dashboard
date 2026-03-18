# Raspberry Pi Touchscreen native Dashboard for HAOS

Work in progress.

## Home Assistant add-on options

- `port` (int, default `8765`): HTTP port used by the app inside the container.
- `log_level` (`error|warning|info|debug`, default `info`): runtime log verbosity for the Zig server.
- `signalk_url` (string, optional): explicit SignalK base URL (for example `http://db21ed7f-signalk:3000`).

If `signalk_url` is empty, the app auto-discovers SignalK using internal HA container DNS names.
