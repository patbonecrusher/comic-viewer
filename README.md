# Comic Viewer

A native Mac comic reader with panel-by-panel viewing and a library for your collection.

Native macOS app (Swift, SwiftUI/AppKit). Sandboxed, no accounts, no telemetry.

## Install

```sh
brew install --cask patbonecrusher/tap/comic-viewer
```

or the Mac App Store / the [releases page](https://github.com/patbonecrusher/comic-viewer/releases). Website: https://patbonecrusher.github.io/comic-viewer/

## Build

```sh
./build.sh            # → build/Comic Viewer.app (ad-hoc signed, sandboxed)
./build.sh --open
./build.sh --sign dev # Apple Development signing (tests the sandbox for real)
```

Requires Xcode 15+. No Xcode project — a Swift Package; `build.sh` assembles the `.app` bundle.
Signed / notarized / App Store builds: see [RELEASING.md](RELEASING.md).

## Layout

| Path | Purpose |
| --- | --- |
| `Sources/ComicViewer/` | App entry, views, settings |
| `Resources/Info.plist`, `Resources/ComicViewer.entitlements` | Bundle metadata, sandbox entitlements |
| `Tools/MakeIcon` | Generates the app icon at build time |
| `Tools/asc.py`, `Tools/release.sh` | App Store Connect listing automation, direct-download release |
| `Marketing/` | Screenshots, listing text, review notes |
| `docs/` | GitHub Pages site (landing page + privacy policy) |
