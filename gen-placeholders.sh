#!/usr/bin/env bash
# Generate placeholder PNGs for every asset declared in a theme's theme.json.
# Stdlib only - no Pillow, no pip install.
#
#   ./gen-placeholders.sh                 # all themes
#   ./gen-placeholders.sh khmer-new-year  # one theme
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

python3 - "${1:-}" <<'PY'
import json, pathlib, struct, sys, zlib

only = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else None

# Dimensions by asset key; anything unlisted falls back to 512x512.
SIZES = {
    "splash_logo":    (512, 512),
    "home_header_bg": (1125, 600),
    "login_bg":       (1125, 2436),
    "nav_icon_home":  (96, 96),
    "nav_icon_qr":    (96, 96),
    "card_pattern":   (1024, 640),
}
PREVIEW = (750, 1334)


def hex_rgb(c):
    c = c.lstrip("#")
    return tuple(int(c[i:i + 2], 16) for i in (0, 2, 4))


def write_png(path, w, h, top, bottom):
    """Vertical gradient PNG, written byte by byte with zlib."""
    raw = bytearray()
    for y in range(h):
        t = y / max(h - 1, 1)
        row = bytes(int(top[k] + (bottom[k] - top[k]) * t) for k in range(3))
        raw.append(0)              # filter type 0 (None) per scanline
        raw += row * w

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c))

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
           + chunk(b"IEND", b""))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)
    return len(png)


total = 0
for src in sorted(pathlib.Path("src").iterdir()):
    if not (src / "theme.json").is_file():
        continue
    if only and src.name != only:
        continue

    cfg = json.loads((src / "theme.json").read_text(encoding="utf-8"))
    stops = cfg.get("gradients", {}).get("header", {}).get("stops")
    top, bottom = (hex_rgb(stops[0]), hex_rgb(stops[1])) if stops else \
                  (hex_rgb(cfg["colors"]["primary"]), hex_rgb(cfg["colors"]["secondary"]))

    print(f"\n{src.name}/")
    for key, rel in cfg["assets"].items():
        target = src / rel
        if target.is_file():
            print(f"  skip   {rel} (already present)")
            continue
        w, h = SIZES.get(key, (512, 512))
        n = write_png(target, w, h, top, bottom)
        total += 1
        print(f"  create {rel}  {w}x{h}  {n:,}B")

    prev = src / "preview.png"
    if prev.is_file():
        print(f"  skip   preview.png (already present)")
    else:
        n = write_png(prev, *PREVIEW, top, bottom)
        total += 1
        print(f"  create preview.png  {PREVIEW[0]}x{PREVIEW[1]}  {n:,}B")

    # Lottie stubs for any declared animation
    for key, rel in cfg.get("animations", {}).items():
        t = src / rel
        if t.is_file():
            continue
        t.parent.mkdir(parents=True, exist_ok=True)
        t.write_text(json.dumps({"v": "5.7.4", "fr": 30, "ip": 0, "op": 60,
                                 "w": 512, "h": 512, "nm": key,
                                 "ddd": 0, "assets": [], "layers": []}))
        total += 1
        print(f"  create {rel}")

print(f"\n{total} placeholder file(s) written."
      "\nExisting files are never overwritten - safe to re-run as real art lands.")
PY
