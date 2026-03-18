#!/usr/bin/env python3
"""Download Tabler SVG icons, rasterize them, and generate LVGL-ready C assets.

Reads icon names (one per line) from an icon list file, downloads matching
Tabler SVG icons, normalizes stroke width, rasterizes them, and generates
LVGL C assets with four variants per icon:
    _S = standard (24 px)
    _P = primary  (32 px)
    _L = large    (48 px)
    _N = nav      (64 px)

Usage:
    # Using the project venv (recommended):
    .venv/bin/python tools/install_icons.py icons_list.txt

    # Or activate venv first:
    source .venv/bin/activate
    python tools/install_icons.py icons_list.txt

Environment overrides:
    STROKE_WIDTH       Stroke width applied to SVGs         (default: 1.5)
    SIZE_STANDARD_PX   Standard size in pixels              (default: 24)
    SIZE_PRIMARY_PX    Primary size in pixels               (default: 32)
    SIZE_LARGE_PX      Large size in pixels                 (default: 48)
    SIZE_NAV_PX        Nav size in pixels                   (default: 64)
    OUT_DIR            Output folder                        (default: src/wasm/generated_icons)
    OUT_BASENAME       Output base name                     (default: tabler_icons)
    TABLER_BASE_URL    Tabler icons base URL

Example:
    .venv/bin/python tools/install_icons.py icons_list.txt
    STROKE_WIDTH=1.75 SIZE_PRIMARY_PX=36 .venv/bin/python tools/install_icons.py icons_list.txt
"""

import io
import os
import re
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

try:
    import cairosvg
except ImportError:
    print(
        "Error: python module 'cairosvg' is required.\n"
        "Install with: .venv/bin/pip install cairosvg",
        file=sys.stderr,
    )
    sys.exit(1)

try:
    from PIL import Image
except ImportError:
    print(
        "Error: python module 'Pillow' is required.\n"
        "Install with: .venv/bin/pip install pillow",
        file=sys.stderr,
    )
    sys.exit(1)

# ---------------------------------------------------------------------------
# Configuration (from env or defaults)
# ---------------------------------------------------------------------------
STROKE_WIDTH = os.environ.get("STROKE_WIDTH", "1.5")
SIZE_STANDARD_PX = int(os.environ.get("SIZE_STANDARD_PX", "24"))
SIZE_PRIMARY_PX = int(os.environ.get("SIZE_PRIMARY_PX", "32"))
SIZE_LARGE_PX = int(os.environ.get("SIZE_LARGE_PX", "48"))
SIZE_NAV_PX = int(os.environ.get("SIZE_NAV_PX", "64"))
TABLER_BASE_URL = os.environ.get(
    "TABLER_BASE_URL",
    "https://raw.githubusercontent.com/tabler/tabler-icons/master/icons/outline",
)
OUT_DIR = os.environ.get("OUT_DIR", "src/wasm/generated_icons")
OUT_BASENAME = os.environ.get("OUT_BASENAME", "tabler_icons")

VARIANTS = [
    ("S", SIZE_STANDARD_PX),
    ("P", SIZE_PRIMARY_PX),
    ("L", SIZE_LARGE_PX),
    ("N", SIZE_NAV_PX),
]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def sanitize_c_ident(name: str) -> str:
    ident = re.sub(r"[^A-Za-z0-9_]", "_", name)
    if not ident:
        ident = "icon"
    if ident[0].isdigit():
        ident = "_" + ident
    return ident


def parse_icon_names(path: str) -> list[str]:
    names: list[str] = []
    seen: set[str] = set()
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line in seen:
                continue
            names.append(line)
            seen.add(line)
    return names


def force_stroke_width(svg_text: str, stroke: str) -> bytes:
    root = ET.fromstring(svg_text)
    for elem in root.iter():
        if "stroke-width" in elem.attrib:
            elem.attrib["stroke-width"] = stroke
    # Keep canonical sizing/viewbox for Tabler icons.
    root.attrib["width"] = "24"
    root.attrib["height"] = "24"
    if "viewBox" not in root.attrib:
        root.attrib["viewBox"] = "0 0 24 24"
    return ET.tostring(root, encoding="utf-8", xml_declaration=False)


def rgba_to_bgra_bytes(img: Image.Image) -> bytes:
    rgba = img.convert("RGBA").tobytes()
    out = bytearray()
    for i in range(0, len(rgba), 4):
        r, g, b, a = rgba[i : i + 4]
        # LVGL's LV_COLOR_FORMAT_ARGB8888 expects 32-bit ARGB values, which are
        # stored in little-endian byte order in memory (B, G, R, A).
        out.extend((b, g, r, a))
    return bytes(out)


def bytes_to_c_array(data: bytes, indent: int = 4, per_line: int = 12) -> str:
    chunks: list[str] = []
    for i in range(0, len(data), per_line):
        row = ", ".join(f"0x{b:02x}" for b in data[i : i + per_line])
        chunks.append(" " * indent + row)
    return ",\n".join(chunks)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> None:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        sys.exit(1)

    icon_list_file = sys.argv[1]
    if not os.path.isfile(icon_list_file):
        print(f"Error: icon list file not found: {icon_list_file}", file=sys.stderr)
        sys.exit(1)

    icons = parse_icon_names(icon_list_file)
    if not icons:
        print("Error: no icons found in list file", file=sys.stderr)
        sys.exit(1)

    os.makedirs(OUT_DIR, exist_ok=True)

    header_path = os.path.join(OUT_DIR, f"{OUT_BASENAME}.h")
    source_path = os.path.join(OUT_DIR, f"{OUT_BASENAME}.c")

    entries: list[dict] = []
    for icon_name in icons:
        url = f"{TABLER_BASE_URL.rstrip('/')}/{icon_name}.svg"
        try:
            with urllib.request.urlopen(url) as resp:
                svg_raw = resp.read().decode("utf-8")
        except urllib.error.HTTPError as e:
            print(
                f"Error: failed to download '{icon_name}' ({url}): HTTP {e.code}",
                file=sys.stderr,
            )
            sys.exit(2)
        except Exception as e:
            print(
                f"Error: failed to download '{icon_name}' ({url}): {e}",
                file=sys.stderr,
            )
            sys.exit(2)

        svg_adjusted = force_stroke_width(svg_raw, STROKE_WIDTH)
        c_ident = sanitize_c_ident(icon_name)

        for variant_suffix, size_px in VARIANTS:
            png_data: bytes = cairosvg.svg2png(  # type: ignore[assignment]
                bytestring=svg_adjusted,
                output_width=size_px,
                output_height=size_px,
            )
            image = Image.open(io.BytesIO(png_data)).convert("RGBA")
            raw_argb = rgba_to_bgra_bytes(image)

            dsc_symbol = f"tabler_icon_{c_ident}_{variant_suffix}"
            map_symbol = f"{dsc_symbol}_map"
            entries.append(
                {
                    "name": icon_name,
                    "ident": c_ident,
                    "variant": variant_suffix,
                    "size_px": size_px,
                    "dsc_symbol": dsc_symbol,
                    "map_symbol": map_symbol,
                    "w": image.width,
                    "h": image.height,
                    "stride": image.width * 4,
                    "data_size": len(raw_argb),
                    "bytes": raw_argb,
                }
            )

    # -----------------------------------------------------------------------
    # Generate header
    # -----------------------------------------------------------------------
    header_lines: list[str] = []
    header_lines.append("/* Auto-generated by tools/install_icons.py. Do not edit manually. */")
    header_lines.append("#pragma once")
    header_lines.append('#include "lvgl.h"')
    header_lines.append("")
    header_lines.append("#ifdef __cplusplus")
    header_lines.append('extern "C" {')
    header_lines.append("#endif")
    header_lines.append("")
    header_lines.append("#if LVGL_VERSION_MAJOR >= 9")
    header_lines.append("typedef lv_image_dsc_t tabler_icon_dsc_t;")
    header_lines.append("#else")
    header_lines.append("typedef lv_img_dsc_t tabler_icon_dsc_t;")
    header_lines.append("#endif")
    header_lines.append("")
    for e in entries:
        header_lines.append(f"extern const tabler_icon_dsc_t {e['dsc_symbol']};")
    header_lines.append("")
    header_lines.append("typedef struct {")
    header_lines.append("    const char *name;")
    header_lines.append("    char variant;")
    header_lines.append("    uint16_t size_px;")
    header_lines.append("    const tabler_icon_dsc_t *icon;")
    header_lines.append("} tabler_icon_registry_entry_t;")
    header_lines.append("")
    header_lines.append("extern const tabler_icon_registry_entry_t tabler_icon_registry[];")
    header_lines.append("extern const uint32_t tabler_icon_registry_count;")
    header_lines.append("")
    header_lines.append(
        "const tabler_icon_dsc_t *tabler_icon_by_name_variant(const char *name, char variant);"
    )
    header_lines.append(
        "const tabler_icon_dsc_t *tabler_icon_by_name_size(const char *name, uint16_t size_px);"
    )
    header_lines.append("")
    header_lines.append("#ifdef __cplusplus")
    header_lines.append("}")
    header_lines.append("#endif")

    # -----------------------------------------------------------------------
    # Generate source
    # -----------------------------------------------------------------------
    source_lines: list[str] = []
    source_lines.append("/* Auto-generated by tools/install_icons.py. Do not edit manually. */")
    source_lines.append(f'#include "{OUT_BASENAME}.h"')
    source_lines.append("")
    source_lines.append("#include <stddef.h>")
    source_lines.append("")
    source_lines.append("static int icon_name_equals(const char *a, const char *b) {")
    source_lines.append("    if(a == NULL || b == NULL) return 0;")
    source_lines.append("    while(*a != '\\0' && *b != '\\0') {")
    source_lines.append("        if(*a != *b) return 0;")
    source_lines.append("        a++;")
    source_lines.append("        b++;")
    source_lines.append("    }")
    source_lines.append("    return *a == *b;")
    source_lines.append("}")
    source_lines.append("")

    for e in entries:
        source_lines.append(f"static const uint8_t {e['map_symbol']}[] = {{")
        source_lines.append(bytes_to_c_array(e["bytes"]))
        source_lines.append("};")
        source_lines.append("")

    for e in entries:
        source_lines.append("#if LVGL_VERSION_MAJOR >= 9")
        source_lines.append(f"const tabler_icon_dsc_t {e['dsc_symbol']} = {{")
        source_lines.append("    .header = {")
        source_lines.append("        .magic = LV_IMAGE_HEADER_MAGIC,")
        source_lines.append("        .cf = LV_COLOR_FORMAT_ARGB8888,")
        source_lines.append("        .flags = 0,")
        source_lines.append(f"        .w = {e['w']},")
        source_lines.append(f"        .h = {e['h']},")
        source_lines.append(f"        .stride = {e['stride']},")
        source_lines.append("    },")
        source_lines.append(f"    .data_size = {e['data_size']},")
        source_lines.append(f"    .data = {e['map_symbol']},")
        source_lines.append("};")
        source_lines.append("#else")
        source_lines.append(f"const tabler_icon_dsc_t {e['dsc_symbol']} = {{")
        source_lines.append("    .header = {")
        source_lines.append("        .always_zero = 0,")
        source_lines.append(f"        .w = {e['w']},")
        source_lines.append(f"        .h = {e['h']},")
        source_lines.append("        .cf = LV_IMG_CF_TRUE_COLOR_ALPHA,")
        source_lines.append("    },")
        source_lines.append(f"    .data_size = {e['data_size']},")
        source_lines.append(f"    .data = {e['map_symbol']},")
        source_lines.append("};")
        source_lines.append("#endif")
        source_lines.append("")

    source_lines.append("const tabler_icon_registry_entry_t tabler_icon_registry[] = {")
    for e in entries:
        source_lines.append(
            f"    {{ \"{e['name']}\", '{e['variant']}', {e['size_px']}, &{e['dsc_symbol']} }},"
        )
    source_lines.append("};")
    source_lines.append("")
    source_lines.append(
        "const uint32_t tabler_icon_registry_count = "
        "(uint32_t)(sizeof(tabler_icon_registry) / sizeof(tabler_icon_registry[0]));"
    )
    source_lines.append("")
    source_lines.append(
        "const tabler_icon_dsc_t *tabler_icon_by_name_variant(const char *name, char variant) {"
    )
    source_lines.append("    if(name == NULL) return NULL;")
    source_lines.append("    for(uint32_t i = 0; i < tabler_icon_registry_count; i++) {")
    source_lines.append(
        "        if(icon_name_equals(name, tabler_icon_registry[i].name) "
        "&& variant == tabler_icon_registry[i].variant) {"
    )
    source_lines.append("            return tabler_icon_registry[i].icon;")
    source_lines.append("        }")
    source_lines.append("    }")
    source_lines.append("    return NULL;")
    source_lines.append("}")
    source_lines.append("")
    source_lines.append(
        "const tabler_icon_dsc_t *tabler_icon_by_name_size(const char *name, uint16_t size_px) {"
    )
    source_lines.append("    if(name == NULL) return NULL;")
    source_lines.append("    for(uint32_t i = 0; i < tabler_icon_registry_count; i++) {")
    source_lines.append(
        "        if(icon_name_equals(name, tabler_icon_registry[i].name) "
        "&& size_px == tabler_icon_registry[i].size_px) {"
    )
    source_lines.append("            return tabler_icon_registry[i].icon;")
    source_lines.append("        }")
    source_lines.append("    }")
    source_lines.append("    return NULL;")
    source_lines.append("}")

    # -----------------------------------------------------------------------
    # Write output files
    # -----------------------------------------------------------------------
    with open(header_path, "w", encoding="utf-8") as hf:
        hf.write("\n".join(header_lines) + "\n")

    with open(source_path, "w", encoding="utf-8") as sf:
        sf.write("\n".join(source_lines) + "\n")

    print("Generated LVGL icon assets:")
    print(f"  - {header_path}")
    print(f"  - {source_path}")
    print(
        f"Icons: {len(icons)} names -> {len(entries)} assets "
        f"(S={VARIANTS[0][1]}px, P={VARIANTS[1][1]}px, L={VARIANTS[2][1]}px, N={VARIANTS[3][1]}px) "
        f"| Stroke: {STROKE_WIDTH}"
    )


if __name__ == "__main__":
    main()
