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
