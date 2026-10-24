# ToastPeek

ToastPeek is a macOS web browser with a vertical tab sidebar and Spaces. The interface is SwiftUI and AppKit; pages are rendered by the system WebKit engine (`WKWebView`).

## Features

- **Sidebar tabs.** Favorites are shared across Spaces. Each Space has pinned tabs (with folders) and a Today section. Today tabs that you have not visited for 12 hours move to an archive (the interval is configurable). Archived tabs stay in the Library for 30 days.
- **Spaces.** Each Space has its own name, icon, color and website data store, so cookies and logins in one Space are not visible in another.
- **Command bar.** Press ⌘T to open a tab or ⌘L to edit the current address. The bar searches open tabs, history and commands across all Spaces.
- **Split view.** Show up to four tabs side by side in one window, with draggable dividers.
- **Peek.** Links from other apps, and Shift-clicked links, can open in a small floating window. You can move the page into a Space or close it. An optional global shortcut (⌥⌘N) opens Peek from any app.
- **Boosts and built-in tools.** Boosts add your own CSS or JavaScript to a site and apply as you edit. Built-in options include a content blocker (Safari content-blocker rules for third-party ad and tracker hosts) and a dark-mode style for websites.

ToastPeek also includes a PDF viewer, a Library (downloads, media, archived tabs), find in page, history import from Safari, Chrome, Firefox and other Chromium-based browsers, rebindable shortcuts, light and dark appearance, and English and Simplified Chinese localizations.

## Requirements

- macOS 14.0 or later
- Apple silicon (arm64). There is no Intel build.

## Install

1. Download `ToastPeek-<version>-arm64.zip` from [Releases](../../releases) and unzip it.
2. Move `ToastPeek.app` to `/Applications`.
3. The app is ad-hoc signed and not notarized, so Gatekeeper blocks the first launch. Right-click the app and choose **Open**, or run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/ToastPeek.app
   ```

Data is stored in `~/Library/Application Support/ToastPeek`, and logs in `~/Library/Logs/ToastPeek`.

## Why WebKit instead of CEF/Chromium

ToastPeek is a personal, free, open-source project. A browser that embeds CEF or another Chromium-based engine must rebuild and ship a large Chromium build on a regular schedule to keep up with security fixes. The official CEF builds also leave out proprietary codecs such as H.264 and AAC, and adding them means compiling Chromium from source, which takes hours each time. The project does not have time for that.

WebKit ships with macOS. The system provides engine updates, security fixes and media decoding, including H.264, AAC and HEVC.

The trade-off is that Chrome extensions do not work in ToastPeek, and the app does not load Safari Web Extensions either. The only extension-like features are the two built-in options described above (content blocker and website dark mode) and Boosts.

## Known limitations

- No support for Chrome or Safari Web Extensions (see above).
- No Widevine DRM, so services that require Widevine do not play.
- No picture-in-picture. macOS `WKWebView` has no public API for it.
- No password manager and no sync.
- Rendering and media support follow the installed macOS version of WebKit.
- The release build is ad-hoc signed and not notarized.

## Build from source

Requirements: Xcode (developed with Xcode 27) and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
git clone https://github.com/Toast1zz/ToastPeek.git
cd ToastPeek
scripts/build.sh release     # Release build
scripts/test.sh              # unit tests
```

`scripts/build.sh` generates `ToastPeek/ToastPeek.xcodeproj` from `ToastPeek/project.yml` and builds into `~/Developer/Builds/ToastPeek`. To use a different folder, set `TOASTPEEK_BUILD_DIR`. The app is written to `DerivedData/Build/Products/<Config>/ToastPeek.app` under that folder. `scripts/build.sh` with no argument makes a Debug build, and `scripts/build.sh install` copies the Release build to `/Applications`. If ToastPeek is running, the install step quits it first.

Builds are ad-hoc signed by default. To sign with your own Apple Development certificate, copy `ToastPeek/config/Local.xcconfig.example` to `ToastPeek/config/Local.xcconfig` and fill in your identity and team ID. Git ignores that file. A stable identity keeps keychain items trusted across rebuilds.

More development notes are in [docs/NOTES.md](docs/NOTES.md).

## License

ToastPeek is released under the [MIT License](LICENSE).

## Third-party software

ToastPeek bundles no third-party code. It links only Apple system frameworks (WebKit, PDFKit, SwiftUI, AppKit) and the system `libsqlite3`, which reads history files during import.
