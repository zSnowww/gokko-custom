#!/usr/bin/env bash
set -euo pipefail

# Sync this custom Gokko fork into an isolated Ryoku Store view directory so
# upstream Store updates to "gokko" never overwrite this repository or its edits.

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DATA_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/ryoku"
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/ryoku/store"
BARSTYLE_DATA="$DATA_ROOT/barstyles/gokko"
LAUNCHER_DATA="$DATA_ROOT/launchers/gokko"
BARSTYLE_RECEIPT="$STATE_ROOT/barstyles/gokko.json"
LAUNCHER_RECEIPT="$STATE_ROOT/launchers/gokko.json"
VIEW_TAG="zsnow-gokko-custom"
VIEW_HASH="$(printf '%s' "$VIEW_TAG" | sha256sum | cut -d' ' -f1)"
VIEW_DIR="$STATE_ROOT/barstyle-views/gokko/$VIEW_HASH"
INDEX_FILE="$STATE_ROOT/barstyles.json"
LAUNCHER_TAG="zsnow-gokko-custom-launcher"
LAUNCHER_HASH="$(printf '%s' "$LAUNCHER_TAG" | sha256sum | cut -d' ' -f1)"
LAUNCHER_DIR="$STATE_ROOT/launcher-views/gokko/$LAUNCHER_HASH"
LAUNCHER_INDEX="$STATE_ROOT/launchers.json"
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
    qmllint "$ROOT/upstream/MacDock.qml" "$ROOT/upstream/ResizeKnob.qml" "$ROOT/Scene.qml" "$ROOT/upstream/MacGlyph.qml" "$ROOT/upstream/SpotEmojiPanel.qml" "$ROOT/upstream/SpotAppsPanel.qml"
    # Filter the known upstream IpcHandler `void` signature warning in MacBar/GokkoSpotlight
    for f in "$ROOT/upstream/MacBar.qml" "$ROOT/upstream/GokkoSpotlight.qml" "$ROOT/LauncherMain.qml"; do
        if qmllint "$f" 2>&1 \
            | grep -Ev "Unexpected token \`void'|Expected token \`,'|Unexpected token \`:'|Expected token \`;'" \
            | grep -Eiq 'error|syntax|expected|duplicate|not a type|unable'; then
            echo "qmllint reported errors in $f" >&2
            qmllint "$f" 2>&1 | grep -Ev "Unexpected token \`void'|Expected token \`,'" >&2 || true
            exit 1
        fi
    done
fi

# Compile shaders if Qt's qsb compiler is available, and clear stale user shader caches
QSB_BIN=""
for q in qsb qsb6 qsb-qt6 /usr/lib/qt6/bin/qsb /usr/lib64/qt6/bin/qsb /usr/lib/qt/bin/qsb; do
    if command -v "$q" >/dev/null 2>&1; then QSB_BIN="$q"; break; fi
done
if [[ -n "$QSB_BIN" ]]; then
    "$QSB_BIN" --qt6 -o "$ROOT/upstream/liquidglass.frag.qsb" "$ROOT/upstream/liquidglass.frag"
    "$QSB_BIN" --qt6 -o "$ROOT/upstream/dockglass.frag.qsb" "$ROOT/upstream/dockglass.frag"
fi
rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/macbar/"*.qsb "${XDG_CONFIG_HOME:-$HOME/.config}/macdock/"*.qsb

if command -v ryostore >/dev/null 2>&1; then
    mkdir -p "$BARSTYLE_DATA" "$LAUNCHER_DATA" "$(dirname "$BARSTYLE_RECEIPT")" "$(dirname "$LAUNCHER_RECEIPT")"
    rsync -a --delete --exclude='*.qmlc' \
        "$ROOT/LICENSE" \
        "$ROOT/NOTICE.md" \
        "$ROOT/PROVENANCE.txt" \
        "$ROOT/README.md" \
        "$ROOT/Scene.qml" \
        "$ROOT/VERSION" \
        "$ROOT/upstream" \
        "$BARSTYLE_DATA/"

    rsync -a --delete --exclude='*.qmlc' \
        "$ROOT/LICENSE" \
        "$ROOT/NOTICE.md" \
        "$ROOT/PROVENANCE.txt" \
        "$ROOT/README.md" \
        "$ROOT/VERSION" \
        "$ROOT/upstream" \
        "$LAUNCHER_DATA/"
    cp "$ROOT/LauncherMain.qml" "$LAUNCHER_DATA/Main.qml"

    python3 - "$VERSION" "$BARSTYLE_DATA" "$BARSTYLE_RECEIPT" "$LAUNCHER_DATA" "$LAUNCHER_RECEIPT" << 'PY'
import hashlib
import json
import os
import stat
import sys
import tempfile

version, bar_data, bar_receipt, launcher_data, launcher_receipt = sys.argv[1:]

def write_receipt(dest_dir, receipt_path, category, ver, dest_rel):
    files = []
    for root_dir, dirs, names in os.walk(dest_dir):
        dirs.sort()
        names.sort()
        for name in names:
            full = os.path.join(root_dir, name)
            rel = os.path.relpath(full, dest_dir).replace(os.sep, "/")
            with open(full, "rb") as f:
                data = f.read()
            st = os.stat(full)
            files.append({
                "source": rel,
                "destination": rel,
                "sha256": hashlib.sha256(data).hexdigest(),
                "mode": format(stat.S_IMODE(st.st_mode), "04o"),
                "size": st.st_size,
            })
    receipt = {
        "category": category,
        "id": "gokko",
        "version": ver,
        "destination": dest_rel,
        "files": files,
    }
    fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(receipt_path), prefix=".receipt.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(receipt, f, separators=(",", ":"))
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, receipt_path)
    except Exception:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
        raise

write_receipt(bar_data, bar_receipt, "barstyles", version, "ryoku/barstyles/gokko")
write_receipt(launcher_data, launcher_receipt, "launchers", version, "ryoku/launchers/gokko")
PY

    ryostore catalog --category barstyles >/dev/null
    ryostore catalog --category launchers >/dev/null
    echo "Installed custom Gokko ($VERSION) via ryostore receipts ($BARSTYLE_DATA + $LAUNCHER_DATA)"
else
    mkdir -p "$VIEW_DIR" "$LAUNCHER_DIR"
    rsync -a --delete --exclude='*.qmlc' \
        "$ROOT/LICENSE" \
        "$ROOT/NOTICE.md" \
        "$ROOT/PROVENANCE.txt" \
        "$ROOT/README.md" \
        "$ROOT/Scene.qml" \
        "$ROOT/VERSION" \
        "$ROOT/upstream" \
        "$VIEW_DIR/"

    rsync -a --delete --exclude='*.qmlc' \
        "$ROOT/LICENSE" \
        "$ROOT/NOTICE.md" \
        "$ROOT/PROVENANCE.txt" \
        "$ROOT/README.md" \
        "$ROOT/VERSION" \
        "$ROOT/upstream" \
        "$LAUNCHER_DIR/"
    cp "$ROOT/LauncherMain.qml" "$LAUNCHER_DIR/Main.qml"

    python3 - "$INDEX_FILE" "$VERSION" "barstyle-views/gokko/$VIEW_HASH" "$LAUNCHER_INDEX" "launcher-views/gokko/$LAUNCHER_HASH" << 'PY'
import json
import os
import sys
import tempfile

index_path, version, view_rel, launcher_index_path, launcher_view_rel = sys.argv[1:]

def update_index(path, extra):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    rows = []
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as f:
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
            row.update(extra)
            updated = True
            break
    if not updated:
        base = {"id": "gokko", "version": version}
        base.update(extra)
        rows.append(base)
    fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".store.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(rows, f, separators=(",", ":"))
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, path)
    except Exception:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
        raise

update_index(index_path, {"scene": "Scene.qml", "view": view_rel})
update_index(launcher_index_path, {"view": launcher_view_rel})
PY

    echo "Installed custom Gokko ($VERSION) -> $VIEW_DIR + $LAUNCHER_DIR"
fi

if [[ "$DO_RELOAD" -eq 1 ]] && command -v ryoku-shell >/dev/null 2>&1; then
    echo "Reloading ryoku-shell..."
    ryoku-shell reload
fi
