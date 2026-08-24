#!/bin/bash
#
# Build Disk Inventory X-Ray for Release
#

set -e

cd "$(dirname "$0")"

echo "Building Disk Inventory X-Ray..."

xcodebuild -project DiskInventoryX.xcodeproj \
           -scheme DiskInventoryX \
           -configuration Release \
           -derivedDataPath build \
           clean build

echo ""
echo "Build complete!"
echo "App location: build/Build/Products/Release/Disk Inventory X-Ray.app"

# Report the release architecture
echo ""
echo "Architecture:"
lipo -info "build/Build/Products/Release/Disk Inventory X-Ray.app/Contents/MacOS/Disk Inventory X-Ray"
