#!/bin/zsh
set -euo pipefail

# Notarization is Apple's malware scan. It requires a paid Apple Developer
# Program membership and a "Developer ID Application" certificate.
# A free Personal Team cannot do this.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/Whisperly.app}"
PROFILE="${NOTARY_PROFILE:-whisperly-notary}"

if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    cat <<'EOF'
No Developer ID Application certificate on this Mac.

Hardened Runtime is already on (the local "Whisperly Local" cert).
Notarization is the extra Apple scan that lets other Macs open the app
without a right-click override. It needs:

  1. Enroll in the Apple Developer Program ($99/year)
     https://developer.apple.com/programs/
  2. In Xcode > Settings > Accounts, select your paid team and
     manage certificates > Developer ID Application
  3. Create an app-specific password at https://appleid.apple.com
  4. Store notary credentials once:
       xcrun notarytool store-credentials whisperly-notary \
         --apple-id YOUR_APPLE_ID \
         --team-id YOUR_TEAM_ID \
         --password THAT_APP_SPECIFIC_PASSWORD
  5. ./Scripts/bundle.sh && ./Scripts/notarize.sh

Your free Personal Team cannot notarize. That is an Apple limit, not a
Whisperly limit.
EOF
    exit 1
fi

if [ ! -d "$APP" ]; then
    echo "Missing app bundle: $APP"
    echo "Run ./Scripts/bundle.sh first."
    exit 1
fi

ZIP="${TMPDIR:-/tmp}/Whisperly-notarize.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Submitting $APP to Apple notary..."
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"

INSTALL="$HOME/Applications/Whisperly.app"
rm -rf "$INSTALL"
cp -R "$APP" "$INSTALL"
echo "Stapled and installed $INSTALL"
spctl --assess --type execute -v "$INSTALL" || true
