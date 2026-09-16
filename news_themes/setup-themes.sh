#!/usr/bin/env bash
# Creates the cdn.sothy.site theme-hosting repo (schema 2, light + dark).
#   bash setup-themes.sh && cd themes
set -euo pipefail
mkdir -p themes/nginx themes/dist
for t in default khmer-new-year pchum-ben; do
  mkdir -p "themes/src/$t/images/light" "themes/src/$t/images/dark" \
           "themes/src/$t/lottie/light" "themes/src/$t/lottie/dark"
done
cd themes
touch dist/.gitkeep

cat > build-bundle.sh <<'SCAFFOLD_EOF'
#!/usr/bin/env bash
# Package a theme source directory into a versioned, immutable bundle.
#
#   ./build-bundle.sh khmer-new-year 2027.1
#
# Both light and dark palettes ship in ONE bundle, so switching mode on the
# device is instant and never triggers a download.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$ROOT/src"
DIST_DIR="$ROOT/dist"

THEME="${1:?usage: build-bundle.sh <theme-name> <version>}"
VERSION="${2:?usage: build-bundle.sh <theme-name> <version>}"

SRC="$SRC_DIR/$THEME"
BUNDLE_ID="${THEME}-${VERSION}"
OUT="$DIST_DIR/bundles/$BUNDLE_ID"

[[ -d "$SRC" ]]            || { echo "ERROR: no such theme source: $SRC" >&2; exit 1; }
[[ -f "$SRC/theme.json" ]] || { echo "ERROR: missing $SRC/theme.json" >&2; exit 1; }

# Bundles are immutable once published. Never overwrite - cut a new version.
if [[ -d "$OUT" ]]; then
  echo "ERROR: $BUNDLE_ID already exists. Bundles are immutable - bump the version." >&2
  exit 1
fi

echo "==> Validating $THEME"
python3 - "$SRC" <<'PY'
import json, sys, pathlib

src = pathlib.Path(sys.argv[1])
t = json.loads((src / "theme.json").read_text(encoding="utf-8"))

if t.get("schema") != 2:
    sys.exit(f"  theme.json schema must be 2 (got {t.get('schema')!r})")
for k in ("id", "name", "modes"):
    if k not in t:
        sys.exit(f"  theme.json missing required key: {k}")

modes = t["modes"]
for required in ("light", "dark"):
    if required not in modes:
        sys.exit(f"  modes.{required} is required - every theme must define both")

dm = t.get("defaultMode", "system")
if dm not in ("system", "light", "dark"):
    sys.exit(f"  defaultMode must be system|light|dark (got {dm!r})")

# Colors every mode must define, so the client never hits a missing key.
REQUIRED_COLORS = {
    "primary", "primaryVariant", "secondary", "background", "surface",
    "onPrimary", "onBackground", "onSurface", "success", "warning",
    "error", "divider",
}

shared = t.get("assets", {})
problems, files = [], set()

for mode, cfg in sorted(modes.items()):
    colors = cfg.get("colors", {})
    gap = REQUIRED_COLORS - set(colors)
    if gap:
        problems.append(f"modes.{mode}.colors missing: {sorted(gap)}")
    bad = [f"{k}={v}" for k, v in colors.items()
           if not (isinstance(v, str) and len(v) == 7 and v.startswith("#"))]
    if bad:
        problems.append(f"modes.{mode}.colors not #RRGGBB: {bad}")

    # Effective asset map = shared, overridden per mode.
    eff = dict(shared)
    eff.update(cfg.get("assets", {}))
    eff.update(cfg.get("animations", {}))
    for key, rel in eff.items():
        files.add(rel)
        if not (src / rel).is_file():
            problems.append(f"modes.{mode}: {key} -> {rel} not found")

# Both modes must expose the same asset keys, or one renders incomplete.
keysets = {m: frozenset(set(shared) | set(c.get("assets", {})))
           for m, c in modes.items()}
if len(set(keysets.values())) > 1:
    only = {m: sorted(set(k) ^ set.union(*[set(x) for x in keysets.values()]))
            for m, k in keysets.items()}
    problems.append(f"modes expose different asset keys; missing per mode: {only}")

for p in ("preview.png", "preview-dark.png"):
    if not (src / p).is_file():
        problems.append(f"missing {p}")

if problems:
    sys.exit("\n".join("  " + p for p in problems))

print(f"    ok - modes={sorted(modes)}  shared assets={len(shared)}  "
      f"files={len(files)}  default={dm}")
PY

mkdir -p "$OUT"

echo "==> Packing theme.zip"
# -X drops timestamps and extended attrs so identical input yields an identical
# hash. Previews stay outside the zip - the picker needs them before committing
# to a download, one per mode.
( cd "$SRC" && zip -q -r -X "$OUT/theme.zip" . \
    -x 'preview.png' 'preview-dark.png' '.*' '*/.*' )

cp "$SRC/preview.png"      "$OUT/preview.png"
cp "$SRC/preview-dark.png" "$OUT/preview-dark.png"

SHA="$(sha256sum "$OUT/theme.zip" | awk '{print $1}')"
SIZE="$(stat -c%s "$OUT/theme.zip")"

python3 - "$OUT" "$BUNDLE_ID" "$THEME" "$VERSION" "$SHA" "$SIZE" "$SRC" <<'PY'
import json, sys, pathlib, datetime, os
out, bid, theme, version, sha, size, src = sys.argv[1:8]
t = json.loads((pathlib.Path(src) / "theme.json").read_text(encoding="utf-8"))
meta = {
    "id": bid, "theme": theme, "version": version,
    "sha256": sha, "size": int(size),
    "modes": sorted(t["modes"]),
    "default_mode": t.get("defaultMode", "system"),
    "built_at": datetime.datetime.now(datetime.timezone.utc)
                    .strftime("%Y-%m-%dT%H:%M:%SZ"),
    "built_by": os.environ.get("USER", "ci"),
}
(pathlib.Path(out) / "bundle.meta.json").write_text(
    json.dumps(meta, indent=2) + "\n", encoding="utf-8")
PY

echo "==> Built $BUNDLE_ID"
echo "    sha256 : $SHA"
echo "    size   : $(numfmt --to=iec-i --suffix=B "$SIZE" 2>/dev/null || echo "${SIZE}B")"
echo "    path   : $OUT"
SCAFFOLD_EOF

cat > update-manifest.sh <<'SCAFFOLD_EOF'
#!/usr/bin/env bash
# Regenerate manifest.json from the bundles present in dist/bundles/.
# The manifest is the ONLY mutable file - written atomically via mv.
#
#   ./update-manifest.sh --active khmer-new-year-2026.1 --rollout 25
#   ./update-manifest.sh --active default-1.0                  # rollback
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$ROOT/dist"

# Bundles are served from the domain root, so no /themes/ prefix.
BASE_URL="${THEME_BASE_URL:-https://cdn.sothy.site}"

ACTIVE=""
FALLBACK="default-1.0"
ROLLOUT=100

while [[ $# -gt 0 ]]; do
  case "$1" in
    --active)   ACTIVE="$2";   shift 2 ;;
    --fallback) FALLBACK="$2"; shift 2 ;;
    --rollout)  ROLLOUT="$2";  shift 2 ;;
    -h|--help)
      sed -n '2,8p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$ACTIVE" ]] || { echo "ERROR: --active <bundle-id> is required" >&2; exit 1; }
[[ -f "$DIST/bundles/$ACTIVE/theme.zip" ]] || {
  echo "ERROR: active bundle not built: $ACTIVE" >&2
  echo "       run: ./build-bundle.sh <theme> <version>" >&2
  exit 1; }

TMP="$DIST/.manifest.json.$$"

python3 - "$DIST" "$BASE_URL" "$ACTIVE" "$FALLBACK" "$ROLLOUT" "$TMP" <<'PY'
import json, sys, pathlib, datetime

dist, base_url, active, fallback, rollout, tmp = sys.argv[1:7]
dist = pathlib.Path(dist)
base_url = base_url.rstrip("/")

# Activation windows in ICT (UTC+7). Outside the window the client falls back.
WINDOWS = {
    "khmer-new-year": ("2027-04-13T00:00:00+07:00", "2027-04-17T23:59:59+07:00"),
    "pchum-ben":      ("2026-10-08T00:00:00+07:00", "2026-10-12T23:59:59+07:00"),
}
MIN_APP = {"ios": "5.2.0", "android": "5.2.0"}

themes = []
for meta_path in sorted(dist.glob("bundles/*/bundle.meta.json")):
    m = json.loads(meta_path.read_text())
    bid = m["id"]
    entry = {
        "id": bid,
        "url": f"{base_url}/bundles/{bid}/theme.zip",
        "preview_url": f"{base_url}/bundles/{bid}/preview.png",
        "preview_url_dark": f"{base_url}/bundles/{bid}/preview-dark.png",
        # Both palettes are inside the one zip - the client switches mode
        # locally with no second download.
        "modes": m.get("modes", ["light", "dark"]),
        "default_mode": m.get("default_mode", "system"),
        "sha256": m["sha256"],
        "size": m["size"],
        "min_app_version": MIN_APP,
        "rollout_percent": int(rollout) if bid == active else 100,
    }
    win = WINDOWS.get(m["theme"])
    if win:
        entry["active_from"], entry["active_to"] = win
    themes.append(entry)

if not any(t["id"] == fallback for t in themes):
    sys.exit(f"ERROR: fallback bundle '{fallback}' is not built")

manifest = {
    "schema": 1,
    "active": active,
    "fallback": fallback,
    "generated_at": datetime.datetime.now(datetime.timezone.utc)
                        .strftime("%Y-%m-%dT%H:%M:%SZ"),
    "poll_interval_seconds": 21600,
    "themes": themes,
}
pathlib.Path(tmp).write_text(
    json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print(f"    active={active}  fallback={fallback}  rollout={rollout}%  "
      f"bundles={len(themes)}")
print(f"    base={base_url}")
PY

chmod 0644 "$TMP"
mv -f "$TMP" "$DIST/manifest.json"
echo "==> dist/manifest.json updated"
SCAFFOLD_EOF

cat > publish.sh <<'SCAFFOLD_EOF'
#!/usr/bin/env bash
# Publish dist/ to the nginx docroot on THIS machine (cdn.sothy.site).
#
#   DRY_RUN=1 ./publish.sh        # preview, writes nothing
#   sudo ./publish.sh             # deploy
#
#   THEME_ROOT=/srv/themes sudo ./publish.sh
#   WEB_USER=www-data     sudo ./publish.sh      # Debian/Ubuntu
#
# Two-phase on purpose: bundles first, manifest last. nginx serves live while
# this runs, so a manifest must never reference a bundle that isn't on disk.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$ROOT/dist"

THEME_ROOT="${THEME_ROOT:-/var/www/themes}"
WEB_USER="${WEB_USER:-nginx}"
DOMAIN="${DOMAIN:-cdn.sothy.site}"
DRY_RUN="${DRY_RUN:-0}"

[[ -f "$DIST/manifest.json" ]] || {
  echo "ERROR: dist/manifest.json missing - run ./update-manifest.sh first" >&2
  exit 1; }

SUDO=""
if [[ ! -w "$THEME_ROOT" ]]; then
  if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || {
      echo "ERROR: $THEME_ROOT not writable and sudo unavailable" >&2; exit 1; }
    SUDO="sudo"
  fi
fi
[[ -d "$THEME_ROOT" ]] || { echo "==> creating $THEME_ROOT"; $SUDO mkdir -p "$THEME_ROOT/bundles"; }

HAVE_RSYNC=0
command -v rsync >/dev/null 2>&1 && HAVE_RSYNC=1

# Additive directory copy. rsync when present, cp -a otherwise (hardened
# hosts often ship without rsync).
sync_tree() {
  local src="$1" dst="$2"
  if [[ "$DRY_RUN" == "1" ]]; then
    if [[ "$HAVE_RSYNC" == "1" ]]; then
      $SUDO rsync -a --chmod=D755,F644 --dry-run --itemize-changes "$src" "$dst"
    else
      echo "    (dry run) would copy $src -> $dst"
    fi
    return
  fi
  if [[ "$HAVE_RSYNC" == "1" ]]; then
    $SUDO rsync -a --chmod=D755,F644 "$src" "$dst"
  else
    $SUDO mkdir -p "$dst"
    $SUDO cp -a "$src." "$dst"
    $SUDO find "$dst" -type d -exec chmod 755 {} +
    $SUDO find "$dst" -type f -exec chmod 644 {} +
  fi
}

# Replace one file atomically: write beside the target, then rename.
# rename(2) within a filesystem is atomic, so a device polling mid-publish
# reads either the whole old manifest or the whole new one - never a partial.
sync_file_atomic() {
  local src="$1" dst="$2"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "    (dry run) would install $src -> $dst"; return
  fi
  local tmp="${dst}.tmp.$$"
  $SUDO cp "$src" "$tmp"
  $SUDO chmod 644 "$tmp"
  $SUDO mv -f "$tmp" "$dst"
}

echo "==> Preflight"
python3 - "$DIST" <<'PY'
import json, sys, pathlib, hashlib
dist = pathlib.Path(sys.argv[1])
m = json.loads((dist / "manifest.json").read_text())
ids = {t["id"] for t in m["themes"]}
for key in ("active", "fallback"):
    if m[key] not in ids:
        sys.exit(f"    manifest.{key}={m[key]} not present in themes[]")
for t in m["themes"]:
    z = dist / "bundles" / t["id"] / "theme.zip"
    if not z.is_file():
        sys.exit(f"    missing bundle file: {z}")
    if hashlib.sha256(z.read_bytes()).hexdigest() != t["sha256"]:
        sys.exit(f"    sha256 mismatch for {t['id']} - rebuild it")
    if z.stat().st_size != t["size"]:
        sys.exit(f"    size mismatch for {t['id']}")
print(f"    ok - {len(m['themes'])} bundles, active={m['active']}, "
      f"fallback={m['fallback']}")
PY

# Phase 1. Never --delete here: a device may still be downloading an older
# bundle it read from the previous manifest.
echo "==> [1/2] bundles -> $THEME_ROOT/bundles/"
sync_tree "$DIST/bundles/" "$THEME_ROOT/bundles/"

echo "==> [2/2] manifest -> $THEME_ROOT/manifest.json"
sync_file_atomic "$DIST/manifest.json" "$THEME_ROOT/manifest.json"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "==> DRY RUN - nothing written"
  exit 0
fi

# nginx only needs read access, so root-owned is fine and safer.
$SUDO chown -R root:"$WEB_USER" "$THEME_ROOT" 2>/dev/null || true

# SELinux: files copied from a home directory carry user_home_t and nginx
# answers 403 with a confusing "Permission denied" in the error log.
if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" != "Disabled" ]]; then
  echo "==> SELinux $(getenforce) - setting httpd_sys_content_t"
  $SUDO chcon -R -t httpd_sys_content_t "$THEME_ROOT" 2>/dev/null \
    || $SUDO restorecon -R "$THEME_ROOT" 2>/dev/null || true
fi

echo "==> Verifying over HTTPS"
if command -v curl >/dev/null 2>&1; then
  TMPF="$(mktemp)"
  code=$(curl -sS -o "$TMPF" -w '%{http_code}' \
         --connect-timeout 5 --max-time 20 \
         "https://$DOMAIN/manifest.json" 2>/dev/null || echo 000)
  if [[ "$code" == "200" ]]; then
    python3 - "$TMPF" "$THEME_ROOT" "$DOMAIN" <<'PY'
import json, sys, pathlib, urllib.parse
served = json.loads(pathlib.Path(sys.argv[1]).read_text())
root, domain = pathlib.Path(sys.argv[2]), sys.argv[3]
print(f"    manifest 200 - active={served['active']}")
bad = []
for t in served["themes"]:
    if not (root / "bundles" / t["id"] / "theme.zip").is_file():
        bad.append(t["id"])
    host = urllib.parse.urlparse(t["url"]).netloc
    if host != domain:
        print(f"    WARNING: {t['id']} url points at {host}, not {domain}")
if bad:
    sys.exit(f"    ERROR: served manifest references absent bundles: {bad}")
print(f"    all {len(served['themes'])} referenced bundles present on disk")
PY
  else
    echo "    WARNING: https://$DOMAIN/manifest.json returned HTTP $code"
    echo "    check: sudo tail -20 /var/log/nginx/$DOMAIN-error.log"
    echo "           sudo nginx -t && sudo systemctl reload nginx"
  fi
  rm -f "$TMPF"
fi

echo "==> Published to $THEME_ROOT  (https://$DOMAIN/manifest.json)"
SCAFFOLD_EOF

cat > gen-placeholders.sh <<'SCAFFOLD_EOF'
#!/usr/bin/env bash
# Generate placeholder PNGs for every asset declared in a theme, both modes.
# Stdlib only - no Pillow, no pip install.
#
#   ./gen-placeholders.sh                 # all themes
#   ./gen-placeholders.sh khmer-new-year  # one theme
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

python3 - "${1:-}" <<'PY'
import json, pathlib, struct, sys, zlib

only = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else None

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
    """Vertical gradient PNG built byte by byte with zlib."""
    raw = bytearray()
    for y in range(h):
        t = y / max(h - 1, 1)
        row = bytes(int(top[k] + (bottom[k] - top[k]) * t) for k in range(3))
        raw.append(0)                      # filter type 0 per scanline
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
    shared = cfg.get("assets", {})
    print(f"\n{src.name}/")

    for mode, mcfg in sorted(cfg["modes"].items()):
        colors = mcfg["colors"]
        stops = mcfg.get("gradients", {}).get("header", {}).get("stops")
        top, bottom = (hex_rgb(stops[0]), hex_rgb(stops[1])) if stops else \
                      (hex_rgb(colors["primary"]), hex_rgb(colors["secondary"]))

        print(f"  [{mode}]")
        eff = dict(shared)
        eff.update(mcfg.get("assets", {}))
        for key, rel in eff.items():
            target = src / rel
            if target.is_file():
                continue
            w, h = SIZES.get(key, (512, 512))
            n = write_png(target, w, h, top, bottom)
            total += 1
            print(f"    create {rel}  {w}x{h}  {n:,}B")

        for key, rel in mcfg.get("animations", {}).items():
            t = src / rel
            if t.is_file():
                continue
            t.parent.mkdir(parents=True, exist_ok=True)
            t.write_text(json.dumps({"v": "5.7.4", "fr": 30, "ip": 0, "op": 60,
                                     "w": 512, "h": 512, "nm": f"{key}-{mode}",
                                     "ddd": 0, "assets": [], "layers": []}))
            total += 1
            print(f"    create {rel}")

        # One preview per mode: preview.png is light, preview-dark.png is dark.
        prev = src / ("preview.png" if mode == "light" else "preview-dark.png")
        if not prev.is_file():
            n = write_png(prev, *PREVIEW, top, bottom)
            total += 1
            print(f"    create {prev.name}  {PREVIEW[0]}x{PREVIEW[1]}  {n:,}B")

print(f"\n{total} placeholder file(s) written."
      "\nExisting files are never overwritten - safe to re-run as real art lands.")
PY
SCAFFOLD_EOF

cat > check-assets.sh <<'SCAFFOLD_EOF'
#!/usr/bin/env bash
# List declared assets per mode and whether they exist.
#   ./check-assets.sh                 # all themes
#   ./check-assets.sh khmer-new-year  # one theme
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
python3 - "${1:-}" <<'PY'
import json, pathlib, sys

only = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else None
missing = 0

for src in sorted(pathlib.Path("src").iterdir()):
    if not (src / "theme.json").is_file(): continue
    if only and src.name != only: continue
    cfg = json.loads((src / "theme.json").read_text(encoding="utf-8"))
    shared = cfg.get("assets", {})
    print(f"\n{src.name}/  (default mode: {cfg.get('defaultMode','system')})")

    used = set()
    for mode, mcfg in sorted(cfg["modes"].items()):
        print(f"  [{mode}]")
        eff = dict(shared)
        eff.update(mcfg.get("assets", {}))
        eff.update(mcfg.get("animations", {}))
        for key, rel in eff.items():
            used.add(rel)
            ok = (src / rel).is_file()
            missing += 0 if ok else 1
            tag = "shared" if key in shared and key not in mcfg.get("assets", {}) else "  "
            size = f"{(src/rel).stat().st_size:,}B" if ok else ""
            print(f"    {'ok     ' if ok else 'MISSING'} {tag:6} {key:16} {rel:34} {size}")

    for p, label in (("preview.png", "preview light"), ("preview-dark.png", "preview dark")):
        ok = (src / p).is_file()
        missing += 0 if ok else 1
        print(f"  {'ok     ' if ok else 'MISSING'} {label:16} {p}")

    for p in sorted((src / "images").rglob("*")) if (src / "images").is_dir() else []:
        if p.is_file():
            rel = str(p.relative_to(src))
            if rel not in used:
                print(f"  unused  {'':16} {rel}  (packed but never referenced)")

print(f"\n{missing} missing" if missing else "\nall assets present")
sys.exit(1 if missing else 0)
PY
SCAFFOLD_EOF

cat > nginx/cdn.sothy.site.conf <<'SCAFFOLD_EOF'
# /etc/nginx/conf.d/cdn.sothy.site.conf
#
# Docroot /var/www/themes served at the domain root:
#   https://cdn.sothy.site/manifest.json
#   https://cdn.sothy.site/bundles/khmer-new-year-2026.1/theme.zip
#   https://cdn.sothy.site/bundles/khmer-new-year-2026.1/preview.png
#
# TLS assumes certbot:
#   sudo certbot --nginx -d cdn.sothy.site
# Certbot will rewrite the ssl_certificate lines below to its own paths.

limit_conn_zone $binary_remote_addr zone=theme_conn:10m;
limit_req_zone  $binary_remote_addr zone=theme_req:10m rate=30r/m;

server {
    listen 80;
    listen [::]:80;
    server_name cdn.sothy.site;

    # Leave ACME reachable over plain HTTP for renewals
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type "text/plain";
    }

    location / { return 301 https://$host$request_uri; }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name cdn.sothy.site;

    ssl_certificate     /etc/letsencrypt/live/cdn.sothy.site/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/cdn.sothy.site/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    root /var/www/themes;

    server_tokens off;
    autoindex off;
    add_header X-Content-Type-Options nosniff always;
    add_header Strict-Transport-Security "max-age=31536000" always;

    access_log /var/log/nginx/cdn.sothy.site-access.log combined buffer=32k flush=5s;
    error_log  /var/log/nginx/cdn.sothy.site-error.log warn;

    # ---- manifest: the only mutable file. Short TTL, must revalidate. ----
    location = /manifest.json {
        default_type application/json;
        charset utf-8;
        add_header Cache-Control "public, max-age=60, must-revalidate" always;
        add_header X-Content-Type-Options nosniff always;
        etag on;
        gzip on;
        gzip_types application/json;
        limit_req zone=theme_req burst=10 nodelay;
    }

    # ---- bundles: immutable, version is in the path. Cache for a year. ----
    location /bundles/ {
        add_header Cache-Control "public, max-age=31536000, immutable" always;
        add_header X-Content-Type-Options nosniff always;
        etag on;
        gzip off;                   # zip and png are already compressed

        limit_conn theme_conn 4;
        limit_rate_after 2m;
        limit_rate 1m;              # 1 MB/s per connection after the first 2 MB

        types {
            application/zip  zip;
            image/png        png;
            application/json json;
        }
        try_files $uri =404;
    }

    location = /healthz {
        access_log off;
        default_type text/plain;
        return 200 "ok\n";
    }

    location / { return 404; }
}
SCAFFOLD_EOF

cat > src/default/theme.json <<'SCAFFOLD_EOF'
{
  "schema": 2,
  "id": "default",
  "name": {
    "en": "Default",
    "km": "ស្តង់ដារ"
  },
  "defaultMode": "system",
  "assets": {
    "nav_icon_home": "images/nav_home.png",
    "nav_icon_qr": "images/nav_qr.png"
  },
  "strings": {
    "home_greeting": {
      "en": "Welcome",
      "km": "សូមស្វាគមន៍"
    }
  },
  "modes": {
    "light": {
      "colors": {
        "primary": "#0B5FFF",
        "primaryVariant": "#0846BF",
        "secondary": "#00A3A1",
        "background": "#F5F7FA",
        "surface": "#FFFFFF",
        "onPrimary": "#FFFFFF",
        "onBackground": "#101828",
        "onSurface": "#101828",
        "divider": "#E4E7EC",
        "success": "#1E8E3E",
        "warning": "#E37400",
        "error": "#D93025"
      },
      "gradients": {
        "header": {
          "type": "linear",
          "angle": 135,
          "stops": [
            "#0B5FFF",
            "#00A3A1"
          ]
        }
      },
      "statusBar": {
        "style": "light-content",
        "backgroundColor": "#0B5FFF"
      },
      "assets": {
        "splash_logo": "images/light/splash_logo.png",
        "home_header_bg": "images/light/home_header_bg.png",
        "login_bg": "images/light/login_bg.png",
        "card_pattern": "images/light/card_pattern.png"
      }
    },
    "dark": {
      "colors": {
        "primary": "#6699FF",
        "primaryVariant": "#0B5FFF",
        "secondary": "#33BFBD",
        "background": "#0E1116",
        "surface": "#171B22",
        "onPrimary": "#06121F",
        "onBackground": "#E6EAF0",
        "onSurface": "#E6EAF0",
        "divider": "#252B35",
        "success": "#4CAF6D",
        "warning": "#FFA726",
        "error": "#EF5350"
      },
      "gradients": {
        "header": {
          "type": "linear",
          "angle": 135,
          "stops": [
            "#0846BF",
            "#00706E"
          ]
        }
      },
      "statusBar": {
        "style": "light-content",
        "backgroundColor": "#6699FF"
      },
      "assets": {
        "splash_logo": "images/dark/splash_logo.png",
        "home_header_bg": "images/dark/home_header_bg.png",
        "login_bg": "images/dark/login_bg.png",
        "card_pattern": "images/dark/card_pattern.png"
      }
    }
  }
}
SCAFFOLD_EOF

cat > src/khmer-new-year/theme.json <<'SCAFFOLD_EOF'
{
  "schema": 2,
  "id": "khmer-new-year",
  "name": {
    "en": "Khmer New Year",
    "km": "បុណ្យចូលឆ្នាំខ្មែរ"
  },
  "defaultMode": "system",
  "assets": {
    "nav_icon_home": "images/nav_home.png",
    "nav_icon_qr": "images/nav_qr.png"
  },
  "strings": {
    "home_greeting": {
      "en": "Happy Khmer New Year",
      "km": "រីករាយបុណ្យចូលឆ្នាំខ្មែរ"
    }
  },
  "modes": {
    "light": {
      "colors": {
        "primary": "#C8102E",
        "primaryVariant": "#8E0B20",
        "secondary": "#F2B705",
        "background": "#FFF8EE",
        "surface": "#FFFFFF",
        "onPrimary": "#FFFFFF",
        "onBackground": "#1A1A1A",
        "onSurface": "#1A1A1A",
        "divider": "#E8DCC8",
        "success": "#1E8E3E",
        "warning": "#E37400",
        "error": "#D93025"
      },
      "gradients": {
        "header": {
          "type": "linear",
          "angle": 135,
          "stops": [
            "#C8102E",
            "#F2B705"
          ]
        }
      },
      "statusBar": {
        "style": "light-content",
        "backgroundColor": "#C8102E"
      },
      "assets": {
        "splash_logo": "images/light/splash_logo.png",
        "home_header_bg": "images/light/home_header_bg.png",
        "login_bg": "images/light/login_bg.png",
        "card_pattern": "images/light/card_pattern.png"
      },
      "animations": {
        "splash": "lottie/light/splash.json"
      }
    },
    "dark": {
      "colors": {
        "primary": "#E8536B",
        "primaryVariant": "#C8102E",
        "secondary": "#F2B705",
        "background": "#14100D",
        "surface": "#1E1916",
        "onPrimary": "#1A0A0E",
        "onBackground": "#EFE7DE",
        "onSurface": "#EFE7DE",
        "divider": "#332A24",
        "success": "#4CAF6D",
        "warning": "#FFA726",
        "error": "#EF5350"
      },
      "gradients": {
        "header": {
          "type": "linear",
          "angle": 135,
          "stops": [
            "#8E0B20",
            "#B8860B"
          ]
        }
      },
      "statusBar": {
        "style": "light-content",
        "backgroundColor": "#E8536B"
      },
      "assets": {
        "splash_logo": "images/dark/splash_logo.png",
        "home_header_bg": "images/dark/home_header_bg.png",
        "login_bg": "images/dark/login_bg.png",
        "card_pattern": "images/dark/card_pattern.png"
      },
      "animations": {
        "splash": "lottie/dark/splash.json"
      }
    }
  }
}
SCAFFOLD_EOF

cat > src/pchum-ben/theme.json <<'SCAFFOLD_EOF'
{
  "schema": 2,
  "id": "pchum-ben",
  "name": {
    "en": "Pchum Ben",
    "km": "បុណ្យភ្ជុំបិណ្ឌ"
  },
  "defaultMode": "system",
  "assets": {
    "nav_icon_home": "images/nav_home.png",
    "nav_icon_qr": "images/nav_qr.png"
  },
  "strings": {
    "home_greeting": {
      "en": "Pchum Ben Blessings",
      "km": "សិរីសួស្តីបុណ្យភ្ជុំបិណ្ឌ"
    }
  },
  "modes": {
    "light": {
      "colors": {
        "primary": "#6A4C93",
        "primaryVariant": "#4A356A",
        "secondary": "#E9C46A",
        "background": "#FBF7F2",
        "surface": "#FFFFFF",
        "onPrimary": "#FFFFFF",
        "onBackground": "#1A1A1A",
        "onSurface": "#1A1A1A",
        "divider": "#E6DFD5",
        "success": "#1E8E3E",
        "warning": "#E37400",
        "error": "#D93025"
      },
      "gradients": {
        "header": {
          "type": "linear",
          "angle": 135,
          "stops": [
            "#6A4C93",
            "#E9C46A"
          ]
        }
      },
      "statusBar": {
        "style": "light-content",
        "backgroundColor": "#6A4C93"
      },
      "assets": {
        "splash_logo": "images/light/splash_logo.png",
        "home_header_bg": "images/light/home_header_bg.png",
        "login_bg": "images/light/login_bg.png",
        "card_pattern": "images/light/card_pattern.png"
      },
      "animations": {
        "splash": "lottie/light/splash.json"
      }
    },
    "dark": {
      "colors": {
        "primary": "#A98BD6",
        "primaryVariant": "#6A4C93",
        "secondary": "#E9C46A",
        "background": "#121016",
        "surface": "#1C1922",
        "onPrimary": "#0F0A17",
        "onBackground": "#E9E4EF",
        "onSurface": "#E9E4EF",
        "divider": "#2B2634",
        "success": "#4CAF6D",
        "warning": "#FFA726",
        "error": "#EF5350"
      },
      "gradients": {
        "header": {
          "type": "linear",
          "angle": 135,
          "stops": [
            "#4A356A",
            "#A8863F"
          ]
        }
      },
      "statusBar": {
        "style": "light-content",
        "backgroundColor": "#A98BD6"
      },
      "assets": {
        "splash_logo": "images/dark/splash_logo.png",
        "home_header_bg": "images/dark/home_header_bg.png",
        "login_bg": "images/dark/login_bg.png",
        "card_pattern": "images/dark/card_pattern.png"
      },
      "animations": {
        "splash": "lottie/dark/splash.json"
      }
    }
  }
}
SCAFFOLD_EOF

cat > .gitignore <<'SCAFFOLD_EOF'
# Build output - bundles are reproducible from src/ via build-bundle.sh.
# Committing them puts a new binary zip in history on every build.
dist/*
!dist/.gitkeep

.DS_Store
*.swp
.manifest.json.*
*.tmp.*
SCAFFOLD_EOF

cat > .gitattributes <<'SCAFFOLD_EOF'
*.sh   text eol=lf
*.json text eol=lf
*.conf text eol=lf
*.md   text eol=lf
*.png  binary
*.zip  binary
SCAFFOLD_EOF

cat > README.md <<'SCAFFOLD_EOF'
# Mobile App Theme Hosting — cdn.sothy.site

Seasonal theme bundles served as static files from nginx. The app polls a
single small `manifest.json` and downloads a versioned, hash-pinned zip when
the active theme changes.

Build machine and web server are the same host, so `publish.sh` copies into
the local docroot rather than rsyncing over SSH.

## URLs

```
https://cdn.sothy.site/manifest.json                              # mutable, 60s TTL
https://cdn.sothy.site/bundles/khmer-new-year-2027.1/theme.zip    # immutable, 1y
https://cdn.sothy.site/bundles/khmer-new-year-2027.1/preview.png
https://cdn.sothy.site/healthz
```

Docroot is `/var/www/themes`, served at the domain root — no `/themes/` path
prefix, since the subdomain is dedicated to this.

## Layout

```
themes/
├── src/                        # designers work here, committed to git
│   ├── default/
│   ├── khmer-new-year/
│   │   ├── theme.json            # schema 2: shared base + light/dark modes
│   │   ├── preview.png           # light picker thumbnail, not packed
│   │   ├── preview-dark.png      # dark picker thumbnail, not packed
│   │   ├── images/
│   │   │   ├── nav_home.png      # shared - works on either background
│   │   │   ├── nav_qr.png
│   │   │   ├── light/*.png       # mode-specific artwork
│   │   │   └── dark/*.png
│   │   └── lottie/{light,dark}/splash.json
│   └── pchum-ben/
│
├── dist/                       # build output, gitignored
│   ├── manifest.json           # THE ONLY MUTABLE FILE
│   └── bundles/
│       ├── default-1.0/
│       │   ├── theme.zip
│       │   ├── preview.png
│       │   └── bundle.meta.json
│       └── khmer-new-year-2027.1/
│
├── nginx/cdn.sothy.site.conf
├── build-bundle.sh
├── update-manifest.sh
├── publish.sh
├── gen-placeholders.sh
└── check-assets.sh
```

`dist/` maps onto `/var/www/themes/` on the server.

## First-time server setup

```bash
sudo mkdir -p /var/www/themes/bundles /var/www/certbot
sudo cp nginx/cdn.sothy.site.conf /etc/nginx/conf.d/
sudo nginx -t && sudo systemctl reload nginx

# TLS (rewrites the ssl_certificate lines in place)
sudo certbot --nginx -d cdn.sothy.site
```

Point an A record for `cdn.sothy.site` at the server before running certbot,
or the HTTP-01 challenge fails.

## Release workflow

```bash
./check-assets.sh khmer-new-year               # what's missing
./gen-placeholders.sh khmer-new-year           # optional, until real art lands

./build-bundle.sh khmer-new-year 2027.1
./build-bundle.sh default 1.0                  # fallback must exist

./update-manifest.sh --active khmer-new-year-2027.1 --rollout 25

DRY_RUN=1 ./publish.sh                         # preview
sudo ./publish.sh
```

Widen the rollout once error rates look clean:

```bash
./update-manifest.sh --active khmer-new-year-2027.1 --rollout 100
sudo ./publish.sh
```

### Rollback

```bash
./update-manifest.sh --active default-1.0
sudo ./publish.sh
```

Propagates at the manifest TTL (60s) plus the client poll interval. Devices
holding the old bundle re-apply it with no download.

## Light and dark modes

Both palettes ship inside **one** bundle. A device switching between light and
dark re-reads `theme.json` from what it already extracted — no second download,
no network round trip, no flash of the wrong palette.

`theme.json` is schema 2:

```jsonc
{
  "schema": 2,
  "defaultMode": "system",        // system | light | dark
  "assets": {                     // shared across modes, packed once
    "nav_icon_home": "images/nav_home.png"
  },
  "modes": {
    "light": {
      "colors":     { "background": "#FFF8EE", "onBackground": "#1A1A1A", ... },
      "gradients":  { "header": { "stops": ["#C8102E", "#F2B705"] } },
      "statusBar":  { "style": "light-content", "backgroundColor": "#C8102E" },
      "assets":     { "login_bg": "images/light/login_bg.png", ... },
      "animations": { "splash": "lottie/light/splash.json" }
    },
    "dark": { ...same shape... }
  }
}
```

**Resolution order on the client:**

1. `defaultMode` is `system` → follow the OS setting. Otherwise force that mode.
2. Effective asset map = top-level `assets`, overridden by `modes.<mode>.assets`.
3. Colours come from `modes.<mode>.colors` only — there is no top-level fallback,
   deliberately, so a missing key fails loudly at build time instead of
   rendering an unstyled control in production.

`build-bundle.sh` enforces that both modes exist, that each defines all twelve
required colours as `#RRGGBB`, and that both expose the **same asset keys** —
otherwise dark mode renders with a missing image that light mode has.

Artwork that reads well on either background (flat-colour icons, most glyphs)
goes in the shared `assets` map and is packed once. Only put a file under
`images/light/` or `images/dark/` when it genuinely needs to differ.

Note that dark mode is not the light palette inverted. Saturated brand colours
vibrate against dark backgrounds, so `primary` is lifted — Khmer New Year's
`#C8102E` becomes `#E8536B` in dark — and `onPrimary` flips to a near-black.
Check contrast before shipping; all three themes here clear WCAG AA (4.5:1) for
body text in both modes.

## Why versioned directories

`bundles/<theme>-<version>/` never changes content, so nginx can send
`Cache-Control: immutable, max-age=31536000` and each device downloads a given
bundle exactly once. To ship a fix you cut `2027.2` — `build-bundle.sh`
refuses to overwrite an existing bundle for exactly this reason.

## manifest.json fields

| Field | Purpose |
|---|---|
| `active` | Bundle to apply if in window and in rollout |
| `fallback` | Applied when `active` fails validation or is out of window |
| `poll_interval_seconds` | How often the app re-checks (6h) |
| `themes[].sha256` | Client MUST verify before extracting |
| `themes[].size` | Cheap pre-flight check |
| `themes[].min_app_version` | Older builds ignore the bundle |
| `themes[].active_from/to` | ICT activation window |
| `themes[].modes` | Which modes the bundle carries, e.g. `["dark","light"]` |
| `themes[].default_mode` | `system`, or a forced mode |
| `themes[].preview_url_dark` | Dark thumbnail for the picker |
| `themes[].rollout_percent` | Bucket on a stable device hash, not `random()` |

## Client contract

1. GET `manifest.json` on cold start, and on resume once the poll interval elapsed.
2. Skip if app version < `min_app_version`, if now is outside the window, or if
   the device bucket exceeds `rollout_percent`.
3. Download `theme.zip`; check `size`, then `sha256`. Discard on mismatch.
4. Extract to a staging directory, then rename into place atomically.
4b. Resolve the mode (OS setting when `defaultMode` is `system`) and merge
   shared assets with the mode overrides. Re-resolve on OS mode change —
   never re-download.
5. On any failure — network, hash, parse, missing asset — apply `fallback` and
   carry on. **A theme failure must never block login or transactions.**

Bucket with something stable like `sha256(device_id + bundle_id) % 100` so a
device doesn't flip in and out of the canary on every poll.

## Security notes

- Bundles are unauthenticated public files. Ship **theme assets only** — no
  config, no endpoint URLs, no keys, no feature flags.
- The zip is attacker-relevant input on the client. Cap the uncompressed size,
  reject entries containing `..` or absolute paths (zip-slip), and reject
  unexpected file extensions.
- `sha256` in the manifest is an integrity check, not a signature. Anyone who
  can write to `/var/www/themes` can change both the zip and its hash. If you
  need provenance, sign the manifest with a key pinned in the app.
- Unreleased campaign artwork is public the moment it's in `bundles/`. Keep it
  out of `dist/` until launch, and consider a private git repo.
SCAFFOLD_EOF

chmod +x build-bundle.sh update-manifest.sh publish.sh gen-placeholders.sh check-assets.sh

if command -v git >/dev/null 2>&1; then
  git init -q -b main 2>/dev/null || git init -q
  git add -A
  git commit -q -m "Initial commit: cdn.sothy.site theme hosting (light + dark)" 2>/dev/null || true
  echo "Git repo initialised."
fi

cat <<'MSG'

Created ./themes  (domain: cdn.sothy.site, schema 2 with light + dark)

Next:
  ./check-assets.sh                      # per-mode artwork inventory
  ./gen-placeholders.sh                  # optional, fills both modes
  ./build-bundle.sh khmer-new-year 2027.1
  ./build-bundle.sh default 1.0
  ./update-manifest.sh --active khmer-new-year-2027.1 --rollout 25
  DRY_RUN=1 ./publish.sh
  sudo ./publish.sh

Server, once only:
  sudo mkdir -p /var/www/themes/bundles /var/www/certbot
  sudo cp nginx/cdn.sothy.site.conf /etc/nginx/conf.d/
  sudo nginx -t && sudo systemctl reload nginx
  sudo certbot --nginx -d cdn.sothy.site
MSG
