#!/bin/zsh
set -euo pipefail

# Build a downloadable Lowkey.app archive. By default this produces an
# ad-hoc-signed build, which is useful for testing. Release CI can provide a
# Developer ID identity and notarization credentials through environment
# variables (see .github/workflows/release.yml).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${LOWKEY_VERSION:-1.0.0}"
ARCH="$(uname -m)"
case "$ARCH" in
    arm64|x86_64) ;;
    *)
        echo "Unsupported macOS architecture: $ARCH" >&2
        exit 1
        ;;
esac

OUTPUT="${LOWKEY_OUTPUT_DIR:-$ROOT/dist/release}"
APP="$ROOT/dist/Lowkey.app"
ZIP="$OUTPUT/Lowkey-${ARCH}.zip"
IDENTITY="${LOWKEY_SIGNING_IDENTITY:-}"

rm -rf "$APP" "$OUTPUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUTPUT"

swift build -c release --product Lowkey
cp "$ROOT/.build/release/Lowkey" "$APP/Contents/MacOS/Lowkey"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
chmod +x "$APP/Contents/MacOS/Lowkey"

# Keep the source plist stable while allowing tags such as v1.1.0 to identify
# the app correctly in Finder and in System Settings.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION#v}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${GITHUB_RUN_NUMBER:-1}" "$APP/Contents/Info.plist"

if [[ -n "$IDENTITY" ]]; then
    echo "Signing with: $IDENTITY"
    codesign --force --deep --options runtime --timestamp \
        --sign "$IDENTITY" \
        --identifier app.lowkey.local \
        --entitlements "$ROOT/Lowkey.entitlements" \
        "$APP"
else
    echo "Signing with an ad-hoc identity"
    codesign --force --deep --options runtime \
        --sign - \
        --identifier app.lowkey.local \
        --entitlements "$ROOT/Lowkey.entitlements" \
        "$APP"
fi

codesign --verify --deep --strict "$APP"

# ditto --keepParent preserves the .app bundle as the single item in the zip.
# Disable AppleDouble metadata files so the archive contains only Lowkey.app.
COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$APP" "$ZIP"

# A notarized app must be stapled before the final archive is generated.
if [[ -n "${LOWKEY_NOTARY_APPLE_ID:-}" || -n "${LOWKEY_NOTARY_TEAM_ID:-}" || -n "${LOWKEY_NOTARY_PASSWORD:-}" ]]; then
    if [[ -z "${LOWKEY_NOTARY_APPLE_ID:-}" || -z "${LOWKEY_NOTARY_TEAM_ID:-}" || -z "${LOWKEY_NOTARY_PASSWORD:-}" ]]; then
        echo "Notarization requires LOWKEY_NOTARY_APPLE_ID, LOWKEY_NOTARY_TEAM_ID, and LOWKEY_NOTARY_PASSWORD." >&2
        exit 1
    fi
    if [[ -z "$IDENTITY" ]]; then
        echo "Notarization requires a Developer ID signing identity." >&2
        exit 1
    fi

    echo "Submitting to Apple for notarization"
    xcrun notarytool submit "$ZIP" \
        --apple-id "$LOWKEY_NOTARY_APPLE_ID" \
        --team-id "$LOWKEY_NOTARY_TEAM_ID" \
        --password "$LOWKEY_NOTARY_PASSWORD" \
        --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
fi

( cd "$OUTPUT" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256" )
echo "Built $ZIP"
