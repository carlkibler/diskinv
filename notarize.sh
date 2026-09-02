#!/bin/bash
#
# Builds a Developer ID distribution app, notarizes it with Apple, staples the
# ticket, and produces a distributable zip — so the downloaded app launches
# without the "unidentified developer / open in Security settings" prompt.
#
# It uses `xcodebuild archive` + `-exportArchive` with ExportOptions.plist
# (method developer-id). That is what produces a *distribution* signature:
# Developer ID cert, hardened runtime, a secure timestamp, and NO
# get-task-allow entitlement. A plain `xcodebuild build` does NOT — its
# signature lacks the timestamp and carries get-task-allow, both of which make
# notarization fail.
#
# Uses notarization credentials stored in the keychain. The profile name comes
# from NOTARIZE_PROFILE (default "dix-notarize"). To (re)create one:
#
#   xcrun notarytool store-credentials "dix-notarize" \
#       --apple-id "you@example.com" \
#       --team-id YOUR_TEAM_ID \
#       --password "abcd-efgh-ijkl-mnop"   # app-specific password from appleid.apple.com
#
# Then run:  ./notarize.sh            (or NOTARIZE_PROFILE=other ./notarize.sh)
#
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${NOTARIZE_PROFILE:-dix-notarize}"
PROJECT="DiskInventoryX/DiskInventoryX.xcodeproj"
SCHEME="DiskInventoryX"
ARCHIVE="build/DiskInventoryX.xcarchive"
EXPORT_DIR="build/export"
APP="$EXPORT_DIR/Disk Inventory X-Ray.app"
ZIP="build/Disk-Inventory-X-Ray.zip"

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "error: no stored notarization profile '$PROFILE'." >&2
  echo "Run the 'xcrun notarytool store-credentials' command in this script's header first." >&2
  exit 1
fi

pkill -9 -f "Disk Inventory X-Ray" 2>/dev/null || true

echo "==> Archiving (Release)…"
rm -rf "$ARCHIVE"
xcodebuild archive -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -archivePath "$ARCHIVE" >/dev/null

echo "==> Exporting a Developer ID distribution build…"
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist ExportOptions.plist >/dev/null

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
echo "Done. Distribute: $(pwd)/$ZIP"
echo "A downloaded copy should now open without the Security-settings prompt."
