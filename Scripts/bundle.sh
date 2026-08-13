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

IDENT="Whisperly Local"
# find-identity -v hides this cert as untrusted, but codesign still accepts it
# and produces a stable designated requirement. That is what TCC keys off.
if security find-identity -p codesigning 2>/dev/null | grep -q "${IDENT}"; then
    codesign --force --deep --sign "${IDENT}" \
        --identifier app.whisperly.local \
        --entitlements "$ROOT/Whisperly.entitlements" \
        "$APP" >/dev/null
else
    codesign --force --deep --sign - "$APP" >/dev/null
fi

INSTALL="$HOME/Applications/Whisperly.app"
rm -rf "$INSTALL"
cp -R "$APP" "$INSTALL"

echo "Built $APP"
echo "Installed $INSTALL"
echo "Signed with: $(codesign -dv "$INSTALL" 2>&1 | awk -F= '/Authority|Signature|Identifier/{print}')"
