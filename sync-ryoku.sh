#!/usr/bin/env bash
set -euo pipefail

# Sync this custom Gokko fork into an isolated Ryoku Store view directory so
# upstream Store updates to "gokko" never overwrite this repository or its edits.

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/ryoku/store"
VIEW_TAG="zsnow-gokko-custom"
VIEW_HASH="$(printf '%s' "$VIEW_TAG" | sha256sum | cut -d' ' -f1)"
VIEW_DIR="$STATE_ROOT/barstyle-views/gokko/$VIEW_HASH"
INDEX_FILE="$STATE_ROOT/barstyles.json"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
DO_RELOAD=1
DO_LINT=0

for arg in "$@"; do
    case "$arg" in
        --no-reload) DO_RELOAD=0 ;;
        --lint) DO_LINT=1 ;;
        -h|--help)
            echo "Usage: $(basename "$0") [--lint] [--no-reload]"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 1
            ;;
    esac
done

if [[ "$DO_LINT" -eq 1 ]] && command -v qmllint >/dev/null 2>&1; then
    echo "Running qmllint..."
    qmllint "$ROOT/upstream/MacDock.qml" "$ROOT/upstream/ResizeKnob.qml" "$ROOT/Scene.qml"
    # Filter the known upstream IpcHandler `void` signature warning in MacBar.qml
    if qmllint "$ROOT/upstream/MacBar.qml" 2>&1 \
        | grep -Ev "Unexpected token \`void'|Expected token \`,'" \
        | grep -Eiq 'error|syntax|expected|duplicate|not a type|unable'; then
        echo "qmllint reported errors in upstream/MacBar.qml" >&2
        exit 1
    fi
fi

mkdir -p "$VIEW_DIR"
rsync -a --delete --exclude='*.qmlc' \
    "$ROOT/LICENSE" \
    "$ROOT/NOTICE.md" \
    "$ROOT/PROVENANCE.txt" \
    "$ROOT/README.md" \
    "$ROOT/Scene.qml" \
    "$ROOT/VERSION" \
    "$ROOT/upstream" \
    "$VIEW_DIR/"

python3 - "$INDEX_FILE" "$VERSION" "barstyle-views/gokko/$VIEW_HASH" << 'PY'
import json
import os
import sys
import tempfile

index_path, version, view_rel = sys.argv[1:]
os.makedirs(os.path.dirname(index_path), exist_ok=True)

rows = []
if os.path.exists(index_path):
    with open(index_path, "r", encoding="utf-8") as f:
        try:
            data = json.load(f)
            if isinstance(data, list):
                rows = data
        except Exception:
            rows = []

updated = False
for row in rows:
    if isinstance(row, dict) and row.get("id") == "gokko":
        row["version"] = version
        row["scene"] = "Scene.qml"
        row["view"] = view_rel
        updated = True
        break

if not updated:
    rows.append({
        "id": "gokko",
        "version": version,
        "scene": "Scene.qml",
        "view": view_rel,
    })

fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(index_path), prefix=".barstyles.")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(rows, f, separators=(",", ":"))
    os.chmod(tmp_path, 0o600)
    os.replace(tmp_path, index_path)
except Exception:
    if os.path.exists(tmp_path):
        os.unlink(tmp_path)
    raise
PY

echo "Installed custom Gokko ($VERSION) -> $VIEW_DIR"

if [[ "$DO_RELOAD" -eq 1 ]] && command -v ryoku-shell >/dev/null 2>&1; then
    echo "Reloading ryoku-shell..."
    ryoku-shell reload
fi
