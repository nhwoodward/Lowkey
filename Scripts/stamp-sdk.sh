#!/bin/zsh
# Some SwiftPM toolchains record the deployment target as the binary's SDK
# version. AppKit and SwiftUI choose their current appearance from that
# field, so a binary marked "sdk 14.0" draws the legacy look on newer macOS.
# Record the SDK that actually built it. Run before code signing.
set -euo pipefail
BIN="$1"
SDK="$(xcrun --sdk macosx --show-sdk-version)"
read -r MINOS CURRENT < <(otool -l "$BIN" | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "minos" { minos = $2 } found && $1 == "sdk" { print minos, $2; exit }')
[[ "$CURRENT" == "$SDK" ]] && exit 0
# vtool warns that the linker signature is now invalid; the caller re-signs.
vtool -set-build-version macos "$MINOS" "$SDK" -replace -output "$BIN.stamped" "$BIN" 2>/dev/null
mv "$BIN.stamped" "$BIN"
