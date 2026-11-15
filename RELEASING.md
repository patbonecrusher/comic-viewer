# Releasing Comic Viewer

Bundle ID `com.patlaplante.ComicViewer`. Everything is driven by `build.sh`; see `./build.sh --help`. Personal settings (`TEAM_ID`, `ASC_KEY_ID`,
`ASC_ISSUER_ID`, `TAP_DIR`) come from `~/.config/mac-app-kit/defaults.env` or `./.release.env` (git-ignored).

## Direct download (Developer ID + notarization) and Homebrew

```sh
Tools/release.sh                              # notarized universal zip → GitHub release → cask update in the tap
```

Needs a *Developer ID Application* certificate in the keychain and the Homebrew tap checked out at `$TAP_DIR`. Install: `brew install --cask patbonecrusher/tap/comic-viewer`.

## Mac App Store

One-time: *Apple Distribution* + *Mac Installer Distribution* certs, App ID, Mac App Store provisioning profile at
`Resources/ComicViewer.provisionprofile` (git-ignored), app record in App Store Connect, API key.

```sh
# bump CFBundleVersion (must strictly increase) in Resources/Info.plist, then:
./build.sh --universal --sign appstore --pkg --upload
Tools/asc.py all        # metadata (Marketing/listing.json), screenshots (Marketing/screenshot-*.png), price, review contact, build
Tools/asc.py submit
```

App Privacy has no public API: App Store Connect → App Privacy → Get Started → answer → **Publish** (the Publish button matters).

Notes: `build.sh` signs with the certificate embedded in the provisioning profile (App Store Connect rejects any other),
strips extended attributes before signing (ITMS-91109), and distribution-signed builds cannot be launched locally —
use `--sign dev` for local testing and screenshots.

## iCloud

The app's own iCloud Drive folder needs the container `iCloud.com.patlaplante.ComicViewer`, created once in the developer
portal (Identifiers → iCloud Containers → +) and assigned to the App ID (Identifiers → the App ID → iCloud → Configure).
Then fetch profiles that grant it:

```sh
Tools/asc.py profiles     # → Resources/ComicViewer.provisionprofile, -devid.provisionprofile, -dev.provisionprofile (git-ignored)
```

`build.sh` embeds the profile for the signing mode and claims the iCloud entitlements only when the profile grants the
container; without one (or with `--sign none`) the app builds as before and simply has no iCloud folder. Profiles expire
with their certificates; rerun the command to renew them.

## iPhone and iPad

The iOS app lives in `iOS/` and shares `ComicCore` with the Mac app. Its Xcode project is generated (needs `xcodegen`):

```sh
iOS/generate.sh                               # writes iOS/Local.xcconfig (signing team, git-ignored) and the .xcodeproj
open iOS/ComicViewerMobile.xcodeproj          # choose a simulator or your device and Run
```

It uses the Mac app's bundle ID and iCloud container, so comics the Mac app keeps in iCloud show up on the phone, and
the two can be one App Store record. Launch arguments for screenshots and testing: `-openFirst YES`, `-startPage 12`,
`-panelMode YES`, `-testScript nnLnP` (n next, p previous, L sideways, P upright). The icon comes from
`swift run MakeIcon --ios iOS/Assets.xcassets/AppIcon.appiconset/AppIcon.png`.
