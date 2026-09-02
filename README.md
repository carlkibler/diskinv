# Disk Inventory X-Ray

An updated version of Tjark Derlien's Disk Inventory X for modern Macs running Apple Silicon. It visualizes disk space usage with treemaps, and this fork rewrites the app in SwiftUI with background scanning, safer deletion, and a layout focused on folder navigation.

- Original Disk Inventory X: <https://derlien.com/>
- Project status and clarification: <https://diskinv.github.io/>
- Repository this fork is based on: <https://github.com/diskinv/diskinv>

The original Objective-C application remains under `src/` for reference.

## Install

Grab the latest release from [this fork](https://github.com/carlkibler/disk-inventory-xray/releases). Unzip it and drag Disk Inventory X-Ray to `/Applications`.

Requirements: macOS 14 or later.

## Build from source

```sh
cd DiskInventoryX
./BuildRelease.sh
```

The release app is written to `DiskInventoryX/build/Build/Products/Release/Disk Inventory X-Ray.app`.

## Layout

- `DiskInventoryX/` — the SwiftUI application and release build script
- `src/` — the Objective-C app (NSDocument-based, AppKit)
- `treemap/` — the embedded `TreeMapView.framework`
- `NOTARIZATION.md` — the legacy Objective-C release recipe

Architectural notes live in [`CLAUDE.md`](CLAUDE.md).

## Credits

- **Tjark Derlien** — original author of Disk Inventory X (2003–2022)
- **Mahmoud Lababidi** — Apple Silicon port, Xcode 26 warning cleanup, Hardened Runtime fix, notarized release pipeline (2026)
- **Carl Kibler** — Swift rewrite improvements, resource-bounded scanning, and safer file management (2026)

## License

GNU GPL v3. See [`LICENSE`](LICENSE) and [`NOTICE.md`](NOTICE.md).
