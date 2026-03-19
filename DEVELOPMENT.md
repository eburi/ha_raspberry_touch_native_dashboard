# Development Guide

This guide covers setting up a development environment and the day-to-day workflows
for working on the Raspberry Pi Touchscreen Dashboard for Home Assistant OS.

## Prerequisites

- **Zig 0.14.1** — exact version required (0.15 is incompatible)
- **Python 3** with a virtual environment (for icon generation and dev server)
- **SSH access** to a Home Assistant instance (optional, for live data during development)

### Installing Zig

The project includes a local Zig installation under `.local/` (gitignored).
If it is present, all project scripts pick it up automatically.

To install Zig manually or on a different machine:

```bash
# Linux aarch64 (Raspberry Pi, Apple Silicon VMs):
curl -L -o /tmp/zig.tar.xz \
  "https://ziglang.org/download/0.14.1/zig-aarch64-linux-0.14.1.tar.xz"
mkdir -p .local/zig
tar -xf /tmp/zig.tar.xz -C .local/zig
ln -sf "$PWD/.local/zig/zig-aarch64-linux-0.14.1/zig" .local/bin/zig

# Linux x86_64:
curl -L -o /tmp/zig.tar.xz \
  "https://ziglang.org/download/0.14.1/zig-x86_64-linux-0.14.1.tar.xz"
mkdir -p .local/zig
tar -xf /tmp/zig.tar.xz -C .local/zig
mkdir -p .local/bin
ln -sf "$PWD/.local/zig/zig-x86_64-linux-0.14.1/zig" .local/bin/zig

# macOS (Homebrew):
brew install zigup
zigup 0.14.1
zigup default 0.14.1
```

Then add Zig to your PATH for the session:

```bash
export PATH="$PWD/.local/bin:$PATH"
zig version   # should print 0.14.1
```

### Setting Up the Python Environment

The Python virtual environment is only needed for icon generation. Skip this if
you don't need to add or regenerate icons.

```bash
python3 -m venv .venv
.venv/bin/pip install cairosvg pillow
```

## Building

```bash
# Build everything (WASM dashboard + native server):
zig build

# Build only the WASM module (outputs to web/dashboard.wasm):
zig build wasm

# Build only the native HTTP server:
zig build server

# Optimized builds (as CI runs):
zig build wasm -Doptimize=ReleaseSmall
zig build server -Doptimize=ReleaseSafe
```

Build artifacts go to `zig-out/`. The WASM build also copies `dashboard.wasm`
to `web/` for easy serving during development.

## Formatting

Zig has a built-in formatter (`zig fmt`). CI enforces formatting — PRs with
unformatted code will fail the check.

```bash
# Format all source files:
zig fmt src/ tests/ build.zig

# Check only (no changes, non-zero exit if unformatted):
zig fmt --check src/ tests/ build.zig
```

## Running Tests

```bash
# Run all tests:
zig build test

# Run tests with optimizations (matches CI):
zig build test -Doptimize=ReleaseSafe
```

Expected output includes warnings about missing hardware and HA token — these are
normal in a development environment without a framebuffer or Home Assistant instance:

```
[default] (warn): No framebuffer found — running in web-only mode
[ha_client] (warn): No HA token configured — HA integration disabled
```

### Adding New Tests

1. Create a test file under `tests/native/` or `tests/server/`
2. Add a comptime import in `tests/test_main.zig`:
   ```zig
   comptime {
       _ = @import("native/your_new_test.zig");
   }
   ```
3. If the test needs a module from `src/`, add the import in `build.zig` under
   the test target section

## Dev Server (Local Development)

The dev server builds both targets, starts the HTTP server, watches for file
changes, and auto-rebuilds on save.

```bash
# Web-only mode (no Home Assistant data):
./dev.sh

# With live Home Assistant data via SSH tunnel:
./dev.sh --ha-host root@192.168.46.222
```

Then open http://127.0.0.1:8765/ in your browser to see the dashboard.

### How the HA Tunnel Works

When `--ha-host` is provided, the dev server:

1. SSHs into the HA host and reads the `SUPERVISOR_TOKEN` from the running
   app container's environment
2. Opens an SSH tunnel to the HA Supervisor API (port 80 on the supervisor
   container, forwarded to local port 18123)
3. Passes `SUPERVISOR_TOKEN` and `HA_URL=http://127.0.0.1:18123/core/api`
   to the local server process

This gives the local dev server full access to Home Assistant entity states,
service calls, and WebSocket events — identical to running inside the HA container.

**Prerequisite**: SSH key-based authentication must be set up beforehand
(`ssh-copy-id root@<ha-host>`).

### Dev Server Options

```
--ha-host HOST       SSH target (e.g. root@192.168.46.222)
--ha-tunnel-port N   Local port for HA tunnel (default: 18123)
--server-port N      Local web server port (default: 8765)
--poll N             File watch interval in seconds (default: 0.75)
```

## Deploying to a Home Assistant Instance

```bash
tools/deploy.sh [user@host]        # default: root@192.168.46.222
```

This script:

1. Builds the WASM module locally (quick sanity check)
2. Assembles a self-contained app directory in `/tmp/`
3. Copies it to `/addons/ha_raspberry_touch_native_dashboard/` on the HA device
4. Installs the app if it's the first time, otherwise rebuilds and restarts it

**Prerequisite**: SSH key-based authentication to the HA host.

## Managing Icons

Icons are [Tabler Icons](https://tabler.io/icons) or local SVG files, rasterized
into LVGL C image assets at four sizes (24, 32, 48, 64 px).

### Adding a New Icon

1. Add the icon name to `icons_list.txt` (one per line):
   ```
   # Tabler icon (fetched from GitHub):
   home
   
   # Local SVG asset:
   assets/my-custom-icon.svg
   ```
2. Regenerate the C assets:
   ```bash
   .venv/bin/python tools/install_icons.py icons_list.txt
   ```
3. This updates `src/generated_icons/tabler_icons.{c,h}` — commit these files

### Icon Variants

Each icon is generated in four size variants:

| Suffix | Size | Usage |
|--------|------|-------|
| `_S`   | 24px | Standard UI elements |
| `_P`   | 32px | Primary/prominent icons |
| `_L`   | 48px | Large display |
| `_N`   | 64px | Navigation |

Access in Zig via the C bridge:
```zig
const icon = lv.c.tabler_icon_by_name_variant("anchor", 'P');
```

## Project Configuration

### Environment Variables (Server)

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `8765` | HTTP server port |
| `WEB_ROOT` | `web` | Path to static web files |
| `LOG_LEVEL` | `info` | `error`, `warning`, `info`, or `debug` |
| `SUPERVISOR_TOKEN` | — | HA Supervisor API token (injected by HA) |
| `HA_URL` | `http://supervisor/core/api` | HA REST API base URL |
| `SIGNALK_URL` | — | SignalK server URL (auto-discovered if empty) |

### HA App Options (config.yaml)

User-configurable in the HA UI:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `port` | int | `8765` | Container HTTP port |
| `log_level` | enum | `info` | Runtime log verbosity |
| `signalk_url` | string | `""` | Explicit SignalK URL (auto-discovers if empty) |

## CI/CD

- **tests.yml**: Checks `zig fmt --check` formatting, then runs
  `zig build test -Doptimize=ReleaseSafe` on every push/PR to main
- **docker.yml**: Builds an aarch64 Docker image via `home-assistant/builder` and
  pushes to `ghcr.io/eburi/ha_raspberry_touch_native_dashboard`

## Troubleshooting

### "zig: command not found"
```bash
export PATH="$PWD/.local/bin:$PATH"
```

### "expected type 'std.Options', found 'type'"
You declared `std_options` as a struct type instead of a value. See the pattern in
`src/server/main.zig` — it must be `pub const std_options: std.Options = .{ ... };`

### WASM build succeeds but browser shows nothing
Rebuild WASM and refresh:
```bash
zig build wasm
# Hard-refresh browser (Ctrl+Shift+R)
```
`web/dashboard.wasm` is gitignored and must be rebuilt locally.

### Tests pass but server won't start
Check that the required environment variables are set. For local development,
use `./dev.sh` which handles this automatically.
