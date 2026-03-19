# Raspberry Pi Touchscreen Dashboard for Home Assistant OS

A Home Assistant App that provides a touch-screen dashboard on a Raspberry Pi
with an RPi Touch Display 2 (1280x720), built with the
[LVGL](https://lvgl.io/) embedded graphics library and written in
[Zig](https://ziglang.org/).

## Why This Exists

Home Assistant OS (HAOS) runs a minimal Linux system — busybox + Docker — with
**no graphical environment**. There is no X11, Wayland, or desktop compositor.
Everything runs in containers.

This app runs inside a standard HA App container but gets direct access to the
display hardware (`/dev/fb0`) and touch input (`/dev/input/event0`) via Docker
device passthrough. LVGL renders directly to the Linux framebuffer, bypassing
the need for any graphical stack.

## How It Works

```
┌────────────────────────────────────────────────────────┐
│  Home Assistant OS (Raspberry Pi)                       │
│                                                         │
│  ┌────────────────────────────────────────────────────┐ │
│  │  HA App Container                                  │ │
│  │                                                    │ │
│  │  ┌─────────────┐  ┌─────────────────────────────┐ │ │
│  │  │ Zap Server  │  │ LVGL Dashboard              │ │ │
│  │  │ (HTTP + WS) │  │  - Native: /dev/fb0 render  │ │ │
│  │  │             │  │  - WASM:   Canvas render     │ │ │
│  │  └──────┬──────┘  └─────────────────────────────┘ │ │
│  │         │                                          │ │
│  │         ├── /dev/fb0       (framebuffer output)    │ │
│  │         ├── /dev/input/*   (touch input)           │ │
│  │         └── HA Supervisor API (entity states)      │ │
│  └────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────┘
```

### Two Rendering Paths

1. **Native framebuffer** (primary goal): LVGL renders directly to `/dev/fb0`.
   Touch input is read from `/dev/input/event0` via evdev. This is what runs on
   the physical Raspberry Pi with the touch display attached.

2. **WASM in browser** (development + ingress): The same LVGL UI is compiled to
   WebAssembly and rendered on an HTML5 Canvas with JavaScript glue. This is
   served through the Zap HTTP server and accessible via Home Assistant's
   ingress proxy. Used for development without hardware, and also serves as a
   remote dashboard accessible from any browser.

Both paths share the same dashboard code (`src/dashboard.zig`) and LVGL
configuration.

## Current Status

**Work in progress.** Both rendering paths are implemented. The WASM browser path
is functional. The native framebuffer path is implemented but not yet tested on
hardware.

- [x] LVGL compiled to WASM, rendering in browser via Canvas
- [x] Zap HTTP server serving static files and proxying HA API
- [x] Home Assistant WebSocket integration (real-time entity states)
- [x] SignalK data source integration (auto-discovery)
- [x] Dev server with file watching and HA tunnel
- [x] HA App packaging (Dockerfile, config.yaml, CI/CD)
- [x] Native framebuffer rendering (integrated into server binary)
- [x] Touch input via evdev (background reader thread)
- [ ] Hardware testing on Raspberry Pi
- [ ] Configurable dashboard layout

## Installation

### From the HA App Store (once published)

Add this repository URL to your Home Assistant App Store:
```
https://github.com/eburi/ha_raspberry_touch_native_dashboard
```

Then install "Raspberry Pi Touchscreen Dashboard" from the local apps section.

### Manual / Local Deploy

See [DEVELOPMENT.md](DEVELOPMENT.md) for building from source and deploying
to a Home Assistant instance.

## App Options

Configurable in the Home Assistant UI under the app settings:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `port` | int | `8765` | HTTP port inside the container |
| `log_level` | enum | `info` | Log verbosity (`error`, `warning`, `info`, `debug`) |
| `signalk_url` | string | `""` | Explicit SignalK URL; auto-discovers if empty |

If `signalk_url` is left empty, the app auto-discovers a SignalK instance by
querying installed HA apps for a slug ending in `_signalk`.

## Architecture

| Component | Technology | Purpose |
|-----------|-----------|---------|
| Dashboard UI | LVGL 9.2.2 (Zig + C) | Widget rendering, layout, input handling |
| HTTP Server | Zap 0.10.6 (Zig) | Serves web frontend, REST proxy, WebSocket |
| WASM Runtime | wasm32-freestanding | Browser rendering path |
| Native Display | Linux fbdev | Direct framebuffer rendering |
| Touch Input | Linux evdev | Direct input device reading |
| Container | Docker on HAOS | App isolation, device passthrough |

## Development

See [DEVELOPMENT.md](DEVELOPMENT.md) for:
- Setting up a development environment
- Building and running tests
- Using the dev server with live HA data
- Deploying to a Home Assistant instance
- Managing icons

## License

See repository for license details.
