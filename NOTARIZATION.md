# Notarized release recipe

`DiskInventoryX/BuildRelease.sh` produces an ad-hoc signed Apple-silicon build for local use. Public downloads need a Developer ID Application signature and Apple notarization.

## One-time setup

1. Join the Apple Developer Program and install a **Developer ID Application** certificate in the login keychain.
2. Create an app-specific password at <https://appleid.apple.com> and store it with `notarytool`:

   ```sh
   xcrun notarytool store-credentials "dix-notarize" \
       --apple-id "you@example.com" \
       --team-id "YOUR_TEAM_ID" \
       --password "your-app-specific-password"
   ```

3. Set the signing team and Developer ID identity for the Release configuration in Xcode. Keep hardened runtime enabled.

## Build and notarize

```sh
./notarize.sh
```

The script archives `DiskInventoryX/DiskInventoryX.xcodeproj`, exports a Developer ID build, verifies it, submits it to Apple, staples the ticket, and writes:

```text
build/Disk-Inventory-X-Ray.zip
```

Before publishing, confirm the final assessment reports `accepted`:

```sh
spctl -a -vvv -t execute "build/export/Disk Inventory X-Ray.app"
```

Never put Apple credentials in this repository. The script reads the stored `dix-notarize` Keychain profile.
