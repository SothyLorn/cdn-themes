#!/usr/bin/env bash
# Package a theme source directory into a versioned, immutable bundle.
#
#   ./build-bundle.sh khmer-new-year 2026.1
#
# Output: dist/bundles/khmer-new-year-2026.1/{theme.zip,preview.png,bundle.meta.json}
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$ROOT/src"
DIST_DIR="$ROOT/dist"

THEME="${1:?usage: build-bundle.sh <theme-name> <version>}"
VERSION="${2:?usage: build-bundle.sh <theme-name> <version>}"

SRC="$SRC_DIR/$THEME"
BUNDLE_ID="${THEME}-${VERSION}"
OUT="$DIST_DIR/bundles/$BUNDLE_ID"

[[ -d "$SRC" ]]              || { echo "ERROR: no such theme source: $SRC" >&2; exit 1; }
[[ -f "$SRC/theme.json" ]]   || { echo "ERROR: missing $SRC/theme.json" >&2; exit 1; }

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

missing = [k for k in ("schema", "id", "colors", "assets") if k not in t]
if missing:
    sys.exit(f"theme.json missing required keys: {missing}")

# Every declared asset must actually exist in the bundle
absent = [rel for rel in t["assets"].values() if not (src / rel).is_file()]
for rel in t.get("animations", {}).values():
    if not (src / rel).is_file():
        absent.append(rel)
if absent:
    sys.exit(f"declared assets not found on disk: {absent}")

# Colors must be #RRGGBB so clients can parse without guessing
bad = [f"{k}={v}" for k, v in t["colors"].items()
       if not (isinstance(v, str) and len(v) == 7 and v.startswith("#"))]
if bad:
    sys.exit(f"invalid color values: {bad}")
print(f"    ok - {len(t['assets'])} assets, {len(t['colors'])} colors")
PY

mkdir -p "$OUT"

echo "==> Packing theme.zip"
# -X drops extended attrs/timestamps so the same input yields the same hash.
( cd "$SRC" && zip -q -r -X "$OUT/theme.zip" . -x 'preview.png' '.*' '*/.*' )

cp "$SRC/preview.png" "$OUT/preview.png" 2>/dev/null || true

SHA="$(sha256sum "$OUT/theme.zip" | awk '{print $1}')"
SIZE="$(stat -c%s "$OUT/theme.zip")"

cat > "$OUT/bundle.meta.json" <<EOF
{
  "id": "$BUNDLE_ID",
  "theme": "$THEME",
  "version": "$VERSION",
  "sha256": "$SHA",
  "size": $SIZE,
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "built_by": "${USER:-ci}"
}
EOF

echo "==> Built $BUNDLE_ID"
echo "    sha256 : $SHA"
echo "    size   : $(numfmt --to=iec-i --suffix=B "$SIZE" 2>/dev/null || echo "${SIZE}B")"
echo "    path   : $OUT"
