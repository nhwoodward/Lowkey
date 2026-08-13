#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

"$ROOT/Scripts/ensure-identity.sh"

swift build -c release --product Whisperly

BIN="$ROOT/.build/release/Whisperly"
APP="$ROOT/dist/Whisperly.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Whisperly"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
chmod +x "$APP/Contents/MacOS/Whisperly"

# Prefer a paid Developer ID if one exists. Otherwise keep the stable
# "Whisperly Local" identity so TCC (mic / Accessibility) does not reset.
IDENT=""
TIMESTAMP=()
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    IDENT="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')"
    TIMESTAMP=(--timestamp)
elif security find-identity -p codesigning 2>/dev/null | grep -q "Whisperly Local"; then
    IDENT="Whisperly Local"
fi

if [ -n "${IDENT}" ]; then
    codesign --force --deep --options runtime \
        --sign "${IDENT}" \
        --identifier app.whisperly.local \
        --entitlements "$ROOT/Whisperly.entitlements" \
        "${TIMESTAMP[@]}" \
        "$APP" >/dev/null
else
    codesign --force --deep --options runtime --sign - "$APP" >/dev/null
fi

INSTALL="$HOME/Applications/Whisperly.app"
rm -rf "$INSTALL"
cp -R "$APP" "$INSTALL"

echo "Built $APP"
echo "Installed $INSTALL"
echo "Signed with: $(codesign -dv "$INSTALL" 2>&1 | awk -F= '/Authority|Signature|Identifier|TeamIdentifier|CodeDirectory/{print}')"
