#!/bin/bash
# Run the SwiftUI application's unit tests.

set -euo pipefail
cd "$(dirname "$0")"

exec xcodebuild test \
  -project DiskInventoryX/DiskInventoryX.xcodeproj \
  -scheme DiskInventoryX \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO \
  ENABLE_HARDENED_RUNTIME=NO \
  "$@"
