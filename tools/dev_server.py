#!/usr/bin/env python3
import argparse
import os
import pathlib
import signal
import shutil
import subprocess
import sys
import time


ROOT = pathlib.Path(__file__).resolve().parent.parent
REQUIRED_ZIG_PREFIX = "0.14."

IGNORE_DIRS = {
    ".git",
    ".zig-cache",
    "zig-out",
    ".venv",
    ".opencode",
}


def run_checked(cmd, env=None):
    print(f"[dev] $ {' '.join(cmd)}")
    subprocess.run(cmd, cwd=ROOT, env=env, check=True)


def first_existing(paths):
    for p in paths:
        if p.exists():
            return p
    return None


def snapshot(paths):
    out = {}
    for rel in paths:
        p = ROOT / rel
        if not p.exists():
            continue
        if p.is_file():
            out[str(p)] = p.stat().st_mtime_ns
            continue

        for f in p.rglob("*"):
            if not f.is_file():
                continue
            skip = False
            for part in f.parts:
                if part in IGNORE_DIRS:
                    skip = True
                    break
            if skip:
                continue
            if f == ROOT / "web" / "dashboard.wasm":
                continue
            out[str(f)] = f.stat().st_mtime_ns
    return out


def changed_files(old, new):
    changed = set()
    old_keys = set(old.keys())
    new_keys = set(new.keys())
    for key in old_keys.union(new_keys):
        if old.get(key) != new.get(key):
            changed.add(key)
    return changed


def relpath(path):
    return str(pathlib.Path(path).resolve().relative_to(ROOT))


def steal_supervisor_token(ha_host):
    remote_script = r"""
set -eu
runtime=""
if command -v docker >/dev/null 2>&1; then
  runtime=docker
elif command -v podman >/dev/null 2>&1; then
  runtime=podman
else
  echo "No docker or podman on HA host" >&2
  exit 1
fi

addon_name="$($runtime ps --format '{{.Names}}' | awk '/addon_.*ha_raspberry_touch_native_dashboard/ { print; exit }')"
if [ -z "$addon_name" ]; then
  echo "Could not find running ha_raspberry_touch_native_dashboard app container" >&2
  exit 1
fi

$runtime inspect "$addon_name" --format '{{range .Config.Env}}{{println .}}{{end}}'
"""

    proc = subprocess.run(
        ["ssh", ha_host, remote_script],
        check=True,
        text=True,
        capture_output=True,
    )
    for line in proc.stdout.splitlines():
        if line.startswith("SUPERVISOR_TOKEN="):
            token = line.split("=", 1)[1].strip()
            if token:
                return token
    raise RuntimeError("SUPERVISOR_TOKEN not found in addon environment")


def get_supervisor_ip(ha_host):
    remote_script = r"""
set -eu
runtime=""
if command -v docker >/dev/null 2>&1; then
  runtime=docker
elif command -v podman >/dev/null 2>&1; then
  runtime=podman
else
  echo "172.30.32.2"
  exit 0
fi

# Print one IP per line and take the first non-empty one.
ip="$($runtime inspect hassio_supervisor --format '{{range .NetworkSettings.Networks}}{{println .IPAddress}}{{end}}' 2>/dev/null | awk 'NF{print; exit}' || true)"
if [ -n "$ip" ]; then
  echo "$ip"
else
  echo "172.30.32.2"
fi
"""

    proc = subprocess.run(
        ["ssh", ha_host, remote_script],
        check=True,
        text=True,
        capture_output=True,
    )
    return proc.stdout.strip() or "172.30.32.2"


def start_process(cmd, env=None):
    print(f"[dev] starting: {' '.join(cmd)}")
    return subprocess.Popen(cmd, cwd=ROOT, env=env)


def main():
    parser = argparse.ArgumentParser(
        description="Run LVGL local dev server with auto rebuild and optional HA tunnel"
    )
    parser.add_argument(
        "--ha-host",
        help="SSH target for HA host, e.g. root@192.168.1.20 (enables token stealing + tunnel)",
    )
    parser.add_argument(
        "--ha-tunnel-port",
        type=int,
        default=18123,
        help="Local port for SSH tunnel to hassio supervisor (default: 18123)",
    )
    parser.add_argument(
        "--server-port",
        type=int,
        default=8765,
        help="Local web server port (default: 8765)",
    )
    parser.add_argument(
        "--poll",
        type=float,
        default=0.75,
        help="Watch polling interval in seconds (default: 0.75)",
    )
    args = parser.parse_args()

    env = os.environ.copy()

    original_path = env.get("PATH", "")

    # Prefer project-local Zig if present (same behavior as local_deploy.sh).
    local_zig_dir = ROOT / ".local" / "bin"
    local_zig = local_zig_dir / "zig"
    if local_zig.exists():
        env["PATH"] = f"{local_zig_dir}:{env.get('PATH', '')}"

    zig_bin = shutil.which("zig", path=env.get("PATH"))

    # If project-local zig is present but not runnable on this host (for example
    # linux binary on macOS), fall back to the original PATH.
    if zig_bin is not None:
        try:
            subprocess.run(
                [zig_bin, "version"],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
        except OSError:
            if local_zig.exists() and pathlib.Path(zig_bin).resolve() == local_zig.resolve():
                env["PATH"] = original_path
                zig_bin = shutil.which("zig", path=env.get("PATH"))

    if zig_bin is None:
        print("[dev] error: 'zig' not found in PATH")
        print("[dev] install Zig or add it to PATH, for example:")
        print("[dev]   brew install zig")
        print("[dev] or if using project-local Zig:")
        print("[dev]   export PATH=\"$PWD/.local/bin:$PATH\"")
        return 1

    version_proc = subprocess.run(
        [zig_bin, "version"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    zig_version = version_proc.stdout.strip()
    if not zig_version.startswith(REQUIRED_ZIG_PREFIX):
        print(
            f"[dev] error: this project requires Zig {REQUIRED_ZIG_PREFIX}x, but found {zig_version}"
        )
        print("[dev] zig 0.15 changed the build API and breaks dependencies (zap/facil.io).")
        print("[dev] on macOS, easiest fix:")
        print("[dev]   brew install zigup")
        print("[dev]   zigup 0.14.1")
        print("[dev]   zigup default 0.14.1")
        print("[dev]   hash -r")
        return 1

    env["PORT"] = str(args.server_port)
    env["WEB_ROOT"] = str(ROOT / "web")

    # Use a local gitignored directory for dev state files (not /data)
    data_dir = ROOT / ".data"
    data_dir.mkdir(exist_ok=True)
    env["SIGNALK_STATE_FILE"] = str(data_dir / "signalk_auth.json")

    tunnel_proc = None
    if args.ha_host:
        print(f"[dev] stealing SUPERVISOR_TOKEN from {args.ha_host} ...")
        token = steal_supervisor_token(args.ha_host)
        supervisor_ip = get_supervisor_ip(args.ha_host)

        tunnel_cmd = [
            "ssh",
            "-N",
            "-o",
            "ExitOnForwardFailure=yes",
            "-L",
            f"{args.ha_tunnel_port}:{supervisor_ip}:80",
            args.ha_host,
        ]
        tunnel_proc = start_process(tunnel_cmd)
        time.sleep(0.8)
        if tunnel_proc.poll() is not None:
            raise RuntimeError("SSH tunnel process exited immediately")

        env["SUPERVISOR_TOKEN"] = token
        env["HA_URL"] = f"http://127.0.0.1:{args.ha_tunnel_port}/core/api"
        print("[dev] HA bridge ready")
        print(f"[dev]   HA_URL={env['HA_URL']}")

    run_checked(["zig", "build", "wasm", "-Doptimize=Debug"], env=env)
    run_checked(["zig", "build", "server", "-Doptimize=Debug"], env=env)

    server_bin = first_existing([
        ROOT / "zig-out" / "bin" / "lvgl-server",
        ROOT / "zig-out" / "bin" / "lvgl-server.exe",
    ])
    if server_bin is None:
        raise RuntimeError("Could not find built server binary in zig-out/bin")

    server_proc = start_process([str(server_bin)], env=env)

    stop = False

    def handle_signal(_sig, _frame):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    watch_paths = ["src", "web", "build.zig", "build.zig.zon", "lv_conf.h"]
    prev = snapshot(watch_paths)

    print("[dev] watching for changes...")
    print(f"[dev] open http://127.0.0.1:{args.server_port}/")

    try:
        while not stop:
            if server_proc.poll() is not None:
                print("[dev] server process exited; restarting")
                run_checked(["zig", "build", "server", "-Doptimize=Debug"], env=env)
                server_proc = start_process([str(server_bin)], env=env)

            time.sleep(args.poll)
            current = snapshot(watch_paths)
            changed = changed_files(prev, current)
            if not changed:
                continue

            prev = current
            rel_changed = sorted(relpath(p) for p in changed)
            interesting = ", ".join(rel_changed[:8])
            if len(rel_changed) > 8:
                interesting += ", ..."
            print(f"[dev] change detected: {interesting}")

            need_wasm = False
            need_server = False
            for path in changed:
                rel = relpath(path)
                if rel.startswith("src/wasm/"):
                    need_wasm = True
                elif rel.startswith("src/server/") or rel.startswith("src/native/"):
                    need_server = True
                elif rel.startswith("src/") and not rel.startswith("src/wasm/"):
                    # Shared code (lv.zig, input.zig, dashboard.zig, generated_icons/)
                    need_wasm = True
                    need_server = True
                if rel == "lv_conf.h":
                    need_wasm = True
                    need_server = True
                if rel == "build.zig" or rel == "build.zig.zon":
                    need_wasm = True
                    need_server = True

            if need_wasm:
                run_checked(["zig", "build", "wasm", "-Doptimize=Debug"], env=env)

            if need_server:
                run_checked(["zig", "build", "server", "-Doptimize=Debug"], env=env)
                server_proc.terminate()
                server_proc.wait(timeout=5)
                server_proc = start_process([str(server_bin)], env=env)

    finally:
        if server_proc.poll() is None:
            server_proc.terminate()
            try:
                server_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server_proc.kill()

        if tunnel_proc and tunnel_proc.poll() is None:
            tunnel_proc.terminate()
            try:
                tunnel_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                tunnel_proc.kill()

    return 0


if __name__ == "__main__":
    sys.exit(main())
