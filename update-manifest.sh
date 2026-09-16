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
