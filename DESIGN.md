# LVGL Dashboard — Architecture & Design

## Overview

A Home Assistant App that provides a touch-screen dashboard UI built with the LVGL graphics library. Runs on Raspberry Pi with HA OS and an attached RPi Touch Display 2 (1280x720 landscape).

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Browser (any device)                                │
│  ┌───────────────┐  ┌────────────────────────────┐  │
│  │  main.js       │  │  dashboard.wasm (LVGL)    │  │
│  │  - Canvas      │←→│  - Display driver → Canvas │  │
│  │  - Input       │  │  - Input driver ← JS      │  │
│  │  - WebSocket   │  │  - Dashboard UI            │  │
│  └───────┬───────┘  └────────────────────────────┘  │
│          │                                           │
└──────────│───────────────────────────────────────────┘
           │ HTTP / WebSocket
           ▼
┌─────────────────────────────────────────────────────┐
│  Zap Server (lvgl-server)                            │
│  ┌──────────┐ ┌──────────┐ ┌───────────────────┐   │
│  │ Static   │ │ REST API │ │ WebSocket Handler │   │
│  │ Files    │ │ /api/*   │ │ /ws               │   │
│  └──────────┘ └────┬─────┘ └────────┬──────────┘   │
│                     │                │               │
│                     ▼                ▼               │
│              ┌──────────────────────────┐           │
│              │  HA Supervisor API        │           │
│              │  http://supervisor/core   │           │
│              │  (via SUPERVISOR_TOKEN)   │           │
│              └──────────────────────────┘           │
│                                                      │
│  Optional: Native LVGL on /dev/fb0 + /dev/input/*   │
└─────────────────────────────────────────────────────┘
```

## Key Design Decisions

### WASM-first approach
Each browser client gets its own LVGL instance running in WASM. This means:
- Zero server-side rendering overhead
- Native LVGL performance in the browser
- Multiple simultaneous clients without resource contention
- The server only relays HA state data

### Pixel format conversion
LVGL with LV_COLOR_DEPTH=32 renders in XRGB8888 (little-endian: B,G,R,X in memory). HTML Canvas ImageData expects RGBA (R,G,B,A in memory). The display driver's flush callback swaps R↔B and sets A=0xFF.

### LVGL configuration
Minimal lv_conf.h with only the features needed:
- 32-bit color depth (XRGB8888)
- Built-in stdlib (no libc dependency for WASM)
- SW renderer only (no GPU acceleration)
- Montserrat 14 + 20 fonts
- Dark theme by default
- Flex + Grid layouts enabled

## Build Targets

| Target | Output | Description |
|--------|--------|-------------|
| `zig build wasm` | `dashboard.wasm` | WASM module for browser |
| `zig build server` | `lvgl-server` | Native web server |
| `zig build` | Both | Default builds both |
| `zig build run` | — | Build and run server |

## Future Plans

### Phase 1 (Complete): Static Dashboard
- Hardcoded card layout with sample HA entities
- Web-only rendering (no native framebuffer)
- REST API proxy to HA (basic)
- WebSocket state relay (scaffold)

### Phase 2 (Complete): HA Integration
- Full HA WebSocket API integration via `ha_client.zig`:
  - Raw TCP + manual WebSocket framing to HA WS API
  - Auth flow (auth_required → auth → auth_ok)
  - Subscribes to `state_changed` events for real-time updates
  - Initial `get_states` fetch with state caching
  - Reconnection with exponential backoff
- Real-time entity state relay to browser clients via facil.io pub/sub channels
- Service call forwarding (browser → server → HA REST API)
- HA REST API proxy (`/api/ha/*` → HA Supervisor API) using `std.http.Client`
- Server-side architecture: Browser ↔ WebSocket ↔ Zap Server ↔ HA WebSocket/REST API

### Phase 3: Native Display
- Framebuffer rendering on RPi Touch Display 2
- Touch input via evdev
- Dual-mode: native display + web access simultaneously
- Auto-detect hardware at startup

### Phase 4: Configurable Dashboards
- Dashboard layout configurable via HA app options (YAML)
- Multiple dashboard pages with swipe navigation
- Custom card types (gauge, graph, camera, etc.)

### Phase 5: WYSIWYG Editor
- In-browser drag-and-drop dashboard editor
- Live preview with actual LVGL rendering
- Export/import dashboard configurations

## Project Structure

```
/workspace/
├── build.zig                    # Two targets: WASM lib + native server
├── build.zig.zon                # Dependencies: LVGL v9.2.2, Zap v0.10.6
├── lv_conf.h                    # Minimal LVGL config for WASM
├── src/
│   ├── wasm/
│   │   ├── main.zig             # WASM exports: init, tick, set_input, get_framebuffer
│   │   ├── lv.zig               # LVGL C API bridge (@cImport + re-exports)
│   │   ├── display.zig          # LVGL flush callback → JS (XRGB→RGBA)
│   │   ├── input.zig            # LVGL indev ← JS mouse/touch
│   │   ├── libc.zig             # C stdlib stubs (memset, memcpy, etc.)
│   │   └── dashboard.zig        # UI layout (cards, header)
│   ├── server/
│   │   ├── main.zig             # Zap server: static files, routing, HA lifecycle
│   │   ├── routes.zig           # REST endpoints + HA API proxy
│   │   ├── websocket.zig        # WebSocket handler (facil.io pub/sub)
│   │   └── ha_client.zig        # HA WebSocket API client + REST proxy
│   └── native/
│       ├── probe.zig            # Hardware detection
│       ├── fbdev.zig            # Framebuffer driver (future)
│       └── evdev.zig            # Input event driver (future)
├── web/
│   ├── index.html               # Canvas shell
│   ├── main.js                  # WASM loader, rAF loop, input, WS
│   └── style.css                # Dark theme, centered canvas
├── lvgl_dashboard/
│   ├── config.yaml              # HA App manifest
│   ├── build.yaml               # Build config
│   ├── Dockerfile               # Multi-stage: Zig builder → Alpine
│   ├── apparmor.txt             # AppArmor security profile
│   ├── rootfs/etc/services.d/   # S6 service scripts
│   └── translations/en.yaml    # UI strings
├── deploy.sh                    # assembles app bundle and copies to HA host
└── DESIGN.md                    # This file
```
