#!/bin/bash
#
# Builds a Developer ID-signed Release, notarizes it with Apple, staples the
# ticket, and produces a distributable zip — so the downloaded app launches
# without the "unidentified developer / open in Security settings" prompt.
#
# ONE-TIME SETUP (stores your notarization credentials in the keychain):
#
#   xcrun notarytool store-credentials "DIX-notary" \
#       --apple-id "you@example.com" \
#       --team-id V29E8BPY35 \
#       --password "abcd-efgh-ijkl-mnop"
#
#   The password is an *app-specific password*, NOT your Apple ID password —
#   create one at https://appleid.apple.com -> Sign-In and Security ->
#   App-Specific Passwords. (Alternatively use an App Store Connect API key:
#   --key / --key-id / --issuer instead of --apple-id/--password.)
#
# Then just run:  ./notarize.sh
#
set -euo pipefail
cd "$(dirname "$0")/src"

PROFILE="DIX-notary"
APP="build/Release/Disk Inventory Xs.app"
ZIP="build/Release/Disk-Inventory-X.zip"

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "error: no stored notarization profile '$PROFILE'." >&2
  echo "Run the 'xcrun notarytool store-credentials' command in this script's header first." >&2
  exit 1
fi

echo "==> Building Developer ID-signed Release…"
pkill -9 -f "Disk Inventory Xs" 2>/dev/null || true
xcodebuild -project "Disk Inventory X.xcodeproj" -target "Disk Inventory X" \
  -configuration Release clean build >/dev/null

echo "==> Verifying the signature…"
codesign --verify --deep --strict "$APP"

echo "==> Zipping for submission…"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple's notary service (this takes a few minutes)…"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> Stapling the notarization ticket to the app…"
xcrun stapler staple "$APP"

echo "==> Re-zipping the stapled app for distribution…"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Gatekeeper assessment:"
spctl -a -vvv "$APP" || true

echo
echo "Done. Distribute: $(cd "$(dirname "$ZIP")" && pwd)/$(basename "$ZIP")"
echo "A downloaded copy should now open without the Security-settings prompt."
