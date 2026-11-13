# Comic Viewer

A native Mac comic reader with panel-by-panel viewing and a library for your collection.

Native macOS app (Swift, SwiftUI/AppKit). Sandboxed, no accounts, no telemetry.

## Features

- **Panel by panel** — detects the panels on each page and steps through them in reading order (⇧⌘P).
  Pages it can't split (splash pages, borderless layouts) are shown whole.
- **Library** — add folders of comics; covers, series, search, unread / in progress / finished. Files stay where they are.
- **Reader** — single and double page, fit page / width / height, pinch zoom, thumbnails, page scrubber,
  keyboard, click and swipe navigation, left-to-right or right-to-left (manga) per comic.
- **Formats** — CBZ, CBR, PDF and folders of images; reads `ComicInfo.xml` when present.

Status: early development, no release yet. Website: https://patbonecrusher.github.io/comic-viewer/

## Build

```sh
./build.sh            # → build/Comic Viewer.app (ad-hoc signed, sandboxed)
./build.sh --open
./build.sh --sign dev # Apple Development signing (tests the sandbox for real)
```

Requires Xcode 16+ and macOS 15+. No Xcode project — a Swift Package; `build.sh` assembles the `.app` bundle.
Signed / notarized / App Store builds: see [RELEASING.md](RELEASING.md).

## Layout

| Path | Purpose |
| --- | --- |
| `Sources/ComicCore/` | Platform-neutral core: archives, PDF, spreads, panel detection, library database (shared with a future iPad app) |
| `Sources/ComicViewer/` | The Mac app: library window, reader windows, menus, settings |
| `Tests/ComicCoreTests/` | Unit tests (`swift test`) |
| `Tools/PanelDebug` | Draws detected panels over a comic's pages, for tuning the detector |
| `Resources/Info.plist`, `Resources/ComicViewer.entitlements` | Bundle metadata, sandbox entitlements |
| `Tools/MakeIcon` | Generates the app icon at build time |
| `Tools/asc.py`, `Tools/release.sh` | App Store Connect listing automation, direct-download release |
| `Marketing/` | Screenshots, listing text, review notes |
| `docs/` | GitHub Pages site (landing page + privacy policy) |

## Credits

[ZIPFoundation](https://github.com/weichsel/ZIPFoundation) (MIT), [Unrar.swift](https://github.com/mtgto/Unrar.swift) (MIT, bundles
UnRAR source under the UnRAR licence: free to use for extracting archives), [GRDB](https://github.com/groue/GRDB.swift) (MIT).

## Licence

MIT — see [LICENSE](LICENSE).
