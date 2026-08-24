# CLAUDE.md

## Build and test

```bash
# Release build
cd DiskInventoryX && ./BuildRelease.sh

# Debug build
xcodebuild -project DiskInventoryX/DiskInventoryX.xcodeproj \
  -scheme DiskInventoryX -configuration Debug

# Tests
xcodebuild test \
  -project DiskInventoryX/DiskInventoryX.xcodeproj \
  -scheme DiskInventoryX \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO \
  ENABLE_HARDENED_RUNTIME=NO
```

## Current application

The maintained app is the SwiftUI implementation under `DiskInventoryX/`. It targets macOS 14 or later and builds for Apple silicon.

- `App/`: application state and lifecycle
- `Models/`: filesystem tree and file-kind data
- `Services/`: bounded background scanning and color assignment
- `Views/`: chooser, progress, outline, treemap, settings, and trash confirmation
- `Tests/`: scanner, cancellation, layout, accounting, and deletion-safety tests

Scanning must remain off the main actor. Keep filesystem concurrency bounded and avoid retaining duplicate scan trees or file contents. UI state mutations return to `AppState`, which is main-actor isolated.

The Objective-C code in `src/` and the older treemap implementation in `treemap/` are retained as upstream reference code. They are not part of the Swift application target.

## License

GPL v3. Preserve upstream notices and the separate notices on legacy reference files.
