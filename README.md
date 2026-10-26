# ToastPeek

> [!WARNING]
> ToastPeek is at an early stage. Expect bugs, crashes and breaking changes between versions, and keep a backup of anything important. Bug reports and pull requests are welcome.

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

- macOS 14.0 or later.
- A Mac with Apple silicon or an Intel processor. Release builds are universal (arm64 + x86_64). The Intel code has been checked only under Rosetta on an Apple silicon Mac, not on an Intel Mac.

## Install

1. Download `ToastPeek-<version>-arm64.zip` for Apple silicon, or `ToastPeek-<version>-universal.zip` for Apple silicon and Intel, from the [latest release](../../releases/latest), and unzip it.
2. Move `ToastPeek.app` to `/Applications`.
3. The app is ad-hoc signed and not notarized, so Gatekeeper blocks the first launch. On macOS 14, right-click the app and choose **Open**. On macOS 15 and later, try to open it once, then click **Open Anyway** in System Settings > Privacy & Security. Alternatively, run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/ToastPeek.app
   ```

Data is stored in `~/Library/Application Support/ToastPeek`, and logs in `~/Library/Logs/ToastPeek`.

Quit all older copies before upgrading. Version 1.0.2 prevents two new instances from saving to the same state file, but older builds do not honor that lock. Keep a backup before opening your data in a new version; downgrading can discard newer state fields.

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
- Release builds are ad-hoc signed and not notarized.
- The Intel (x86_64) code has not been tested on an Intel Mac.

Version 1.0.3 isolates favicon caches by profile and origin, keeps icon requests within the page's cookie and security context, and reduces cached image dimensions. The page-hosting fixes from 1.0.2 remain; an intermittent blank GitHub page seen in an older, signed-in session has not been conclusively diagnosed. See [reliability notes](docs/RELIABILITY.md) for the fixes, test coverage and remaining limits.

## Build from source

Requirements: Xcode (developed with Xcode 27) and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
git clone https://github.com/Toast1zz/ToastPeek.git
cd ToastPeek
scripts/build.sh release     # universal Release build
scripts/test.sh              # core and real AppKit/WebKit tests (shows test windows)
scripts/test.sh headless     # core, favicon and import tests without test windows
scripts/package.sh           # arm64 and universal public Release archives
```

`scripts/build.sh` generates `ToastPeek/ToastPeek.xcodeproj` from `ToastPeek/project.yml` and builds into `~/Developer/Builds/ToastPeek`. To use a different folder, set `TOASTPEEK_BUILD_DIR`. The app is written to `DerivedData/Build/Products/<Config>/ToastPeek.app` under that folder. `scripts/build.sh` with no argument makes an arm64-only Debug build. `scripts/build.sh release` makes a universal Release build. `scripts/build.sh install` also copies the Release build to `/Applications`, quits the installed copy first, and preserves the previous app bundle. Quit any other copies using the same data before installing.

Debug uses `app.toastpeek.mac.debug` and stores data in `~/Library/Application Support/ToastPeek-Development`; `TOASTPEEK_SUPPORT_DIR` can point it at a temporary directory. Release uses the normal data directory. Tests use temporary state files and website data stores.

`scripts/package.sh` explicitly uses ad-hoc signing and complete Swift concurrency checks. Its archives are written to `Releases/<version>` under the build folder. Pass `arm64` or `universal` to build only one variant. This packaging path does not install the app.

Builds are ad-hoc signed by default. To sign with your own Apple Development certificate, copy `ToastPeek/config/Local.xcconfig.example` to `ToastPeek/config/Local.xcconfig` and fill in your identity and team ID. Git ignores that file. A stable identity keeps keychain items trusted across rebuilds.

More development notes are in [docs/NOTES.md](docs/NOTES.md).

## License

ToastPeek is released under the [MIT License](LICENSE).

## Third-party software

ToastPeek bundles no third-party code. It links only Apple system frameworks (WebKit, PDFKit, SwiftUI, AppKit) and the system `libsqlite3`, which reads history files during import.
