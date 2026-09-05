#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MODE="${1:-run}"
APP="$ROOT/dist/Lowkey Development.app"
SUPPORT="$ROOT/dist/development-support"
# Only stop the development copy owned by this checkout.
if [[ -f "$SUPPORT/app.pid" ]]; then
    prior_pid="$(cat "$SUPPORT/app.pid")"
    if [[ "$(ps -p "$prior_pid" -o comm= 2>/dev/null || true)" == "$APP/Contents/MacOS/LowkeyDev" ]]; then
        kill "$prior_pid"
    fi
fi
swift build --product Lowkey
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$SUPPORT"
cp "$(swift build --show-bin-path)/Lowkey" "$APP/Contents/MacOS/LowkeyDev"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier app.lowkey.development' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable LowkeyDev' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Lowkey Development' "$APP/Contents/Info.plist"
if [[ ! -f "$SUPPORT/config.json" ]]; then
    python3 - "$SUPPORT/config.json" <<'PY'
import json, pathlib, sys
root=pathlib.Path.home()/'Library/Application Support/Lowkey/models'
pathlib.Path(sys.argv[1]).write_text(json.dumps({'port':18791, 'hotkey':'rightOption', 'hideFromDock':False, 'showBarAlways':True, 'modelPath':str(root/'ggml-small.en-q5_1.bin')}))
PY
fi
# Reuse an existing signing identity so privacy grants survive rebuilds.
IDENTITY="$(security find-identity -v -p codesigning | awk '/Developer ID Application/{print $2; exit}')"
if [[ -z "$IDENTITY" ]]; then IDENTITY="-"; fi
codesign --force --sign "$IDENTITY" --timestamp=none --options runtime --entitlements Lowkey.entitlements "$APP"
if [[ "$MODE" == "--build-only" ]]; then
    echo "$APP"
    exit 0
fi
open -n "$APP" --env LOWKEY_SUPPORT_DIRECTORY="$SUPPORT" --env LOWKEY_UI="${LOWKEY_UI:-main}"
case "$MODE" in
    --logs) tail -F "$SUPPORT/logs/app.log" ;;
    --verify) sleep 1; pgrep -fl "$APP/Contents/MacOS/LowkeyDev" ;;
    run) ;;
    *) echo 'Usage: script/build_and_run.sh [--build-only|--logs|--verify]' >&2; exit 2 ;;
esac
