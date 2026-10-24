# ToastPeek development notes

These notes cover things that are not obvious from the code.

## Build and test

- `scripts/build.sh` makes a Debug build. `scripts/build.sh install` makes a Release build and copies it to `/Applications`, quitting a running instance cleanly first.
- `scripts/test.sh` runs the unit tests, which cover only the engine-independent logic. `scripts/l10n_missing.py` lists UI strings that have no zh-Hans translation.
- XcodeGen generates the project from `ToastPeek/project.yml`. The `.xcodeproj` is not committed.
- Signing is ad-hoc unless `ToastPeek/config/Local.xcconfig` sets an identity. Builds are not notarized.
- Release builds are universal (arm64 + x86_64). Debug builds are arm64 only, to keep everyday builds fast.

## Data locations

- `~/Library/Application Support/ToastPeek`: `state.json` (and `.bak`), `Favicons`, `shortcuts.json`.
- Logs: `~/Library/Logs/ToastPeek`.
- Each Space has its own `WKWebsiteDataStore`, keyed by the Space's `dataStoreID`, so cookies are isolated between Spaces.

## Debug automation (Debug builds only)

`ToastPeek --automation <dir>` reads commands from `<dir>/in.txt` and writes results to `<dir>/out.txt`. `TOASTPEEK_SUPPORT_DIR` points the data folder at a temporary location so that real data is not touched. The command list is in the header and `case` labels of `Support/Automation.swift`. Synthesized events do not trigger AppKit drag and drop, so a person has to check drag interactions by hand.

## Known limitations

- Picture-in-picture: macOS `WKWebView` has no public API for it.
- No Chrome extensions, password manager or sync.
- Without Accessibility permission, the automation driver cannot post real mouse events.
