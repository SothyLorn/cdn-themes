#!/usr/bin/env bash
# List every declared asset and whether it exists.
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
    print(f"\n{src.name}/")
    declared = dict(cfg["assets"]); declared.update(cfg.get("animations", {}))
    for key, rel in declared.items():
        ok = (src / rel).is_file()
        missing += 0 if ok else 1
        size = f"{(src/rel).stat().st_size:,}B" if ok else ""
        print(f"  {'ok     ' if ok else 'MISSING'} {key:16} {rel:28} {size}")
    if (src / "preview.png").is_file():
        print(f"  {'ok     '} {'preview':16} preview.png")
    else:
        missing += 1; print(f"  MISSING {'preview':16} preview.png")
    if (src / "images").is_dir():
        for p in sorted((src / "images").glob("*")):
            if f"images/{p.name}" not in declared.values():
                print(f"  unused  {'':16} images/{p.name}  (packed but never used)")
print(f"\n{missing} missing" if missing else "\nall assets present")
sys.exit(1 if missing else 0)
PY
