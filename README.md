# Comic Viewer

A native Mac comic reader with panel-by-panel viewing and a library for your collection.

Native macOS app (Swift, SwiftUI/AppKit). Sandboxed, no accounts, no telemetry.

## What makes it different

- **Panel by panel on the Mac.** Most Mac comic readers show whole pages. Comic Viewer steps through a page one panel
  at a time, which makes comics comfortable on a laptop screen.
- **Works on the comics you already own.** Panels are found on your Mac from the page artwork, so any CBZ, CBR or PDF
  works: no store, no special format, nothing uploaded.
- **You can fix what it gets wrong.** Every page has a panel editor, and corrections can be saved inside the CBZ so
  they travel with the comic.
- **Free and open.** No subscription, account, ads or network access; MIT licensed.

## Features

- **Panel by panel** — detects the panels on each page and steps through them in reading order (⇧⌘P).
  Works from gutters on grid pages and from panel borders where framed panels sit on full-page art (the whole
  page is shown first, then each panel). Pages it can't split (splash pages, borderless or slanted layouts) are shown whole.
- **Panel editor** — when detection gets a page wrong, draw, move, resize, reorder or delete its panels (⌘E).
  Edits are saved per page, and optionally inside the CBZ itself (a small `ComicViewerPanels.json`) so they travel
  with the comic. Panel frames from an embedded ACBF file are used when a comic has them.
- **Library** — add folders of comics; covers, series, search, unread / in progress / finished. Files stay where they are.
  **Rename File…** gives a comic's file a tidy name built from its title (`Series 002 - Title (Year)`), keeping its
  reading position and panel edits. **Rename Series…** gives a series a better name (or merges it into another)
  without touching the files; issues added later join it. **Move to Series…** puts the selected comics in
  another series, or in a new one you name. Dragging comics onto a series in the sidebar does the same.
- **Cleaning up** — select several comics (⌘-click, ⇧-click, ⌘A) and remove them from the library; files are never
  deleted. A comic removed from inside a library folder stays removed across rescans until you choose
  File → Restore Removed Comics. File → Remove Missing Comics clears entries whose files are gone.
- **iCloud** — comics kept in iCloud Drive are listed without being downloaded, show a cloud badge, download when
  opened, and can have their local copy removed again. With iCloud enabled for the build (see RELEASING.md), the app
  also has its own "Comic Viewer" folder in iCloud Drive and a Copy to iCloud command, which leaves the original file where it is.
- **Reader** — single and double page, fit page / width / height, pinch zoom, thumbnails, page scrubber,
  keyboard, click and swipe navigation, left-to-right or right-to-left (manga) per comic.
- **Formats** — CBZ, CBR, PDF and folders of images; reads `ComicInfo.xml` when present.

## Install

```sh
brew install --cask patbonecrusher/tap/comic-viewer
```

Or download the signed, notarized app from [Releases](https://github.com/patbonecrusher/comic-viewer/releases/latest).
Website: https://patbonecrusher.github.io/comic-viewer/

## iPhone and iPad (in progress)

An iOS app in `iOS/` shares the core with the Mac app: a library of the comics in its own folder and in the same
iCloud Drive folder the Mac app uses, and a reader with panel-by-panel reading that re-fits when the device is turned
(sideways: fill the width, or two facing pages). Run `iOS/generate.sh`, open `iOS/ComicViewerMobile.xcodeproj`, and Run.
It is not on the App Store yet.

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
