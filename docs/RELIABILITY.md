# Reliability notes for 1.0.2

This release fixes browser lifecycle and data-handling problems without redesigning the interface. It remains an early-stage browser.

## Changes

- A live page has one window/pane owner. An old host cannot detach or resize a page after it moves to another host. Initial SwiftUI mounting retries once the window is registered and has usable dimensions.
- Tabs retain their website-data-store identity when they become Favorites or pinned tabs, or when Spaces are reordered. Permission decisions include the profile and complete origin, including the port. Certificate exceptions are session-only and scoped to profile, origin and certificate fingerprint.
- A state directory has one writer. A second instance can browse but cannot save its state over the first. Writes report failures, snapshots have a schema version, and recovery preserves unreadable files. Clearing history replaces the application-managed backup as well.
- Downloads have unique IDs and an application-owned lifetime. Closing the source tab does not stop a transfer. Concurrent filenames are reserved, incomplete files stay separate from final files, and supported cancelled downloads can resume during the same app session.
- Split-view address editing follows the focused pane. Windows retain their own Space. File inputs use a native file picker, and user-initiated popup windows keep the WebKit configuration and opener relationship. Automatic JavaScript popups are blocked by WebKit.
- Content rules are versioned, canonically serialized and prepared before the first navigation. Stale asynchronous results cannot replace the current policy. CSS Boost edits update the document without reloading and discarding form values.
- Save Page writes a WebArchive of the loaded document. Printing uses native paper pagination. History import takes an SQLite backup that includes committed WAL transactions and reports errors.
- Debug has a separate bundle ID and data directory. CI and integration tests cover real AppKit/WebKit behavior. Public packages are available as arm64 and universal archives.

## Validation

The public source passed 64 tests after integrating the fixes with the current repository: 36 core tests and 28 integration tests. The core suite covers state loading, backup recovery, schema handling, permissions, URL resolution and models. The integration suite exercises real BrowserStore/AppKit ownership and SQLite import, plus 15 tests running WKWebView.

Runtime checks include screenshots of a rendered fixture, private-world script isolation, automatic popup blocking, simultaneous downloads after source-tab closure, cancellation cleanup and byte-for-byte resume, cookie cleanup and pending cleanup after restart, stable profile identity, cross-host page transfer, OfflineAudioContext mute/disconnect behavior, rapid content-rule changes, preserved form values after CSS editing, initial SwiftUI window display, WebArchive and multi-page PDF output.

Build verification checks both CPU slices, bundle signatures and extracted localizations. Local testing used Apple silicon with macOS 27.0.1 and Xcode 27.0. A universal binary is not proof of compatibility with every supported Mac or macOS release.

## Remaining limits

- A blank GitHub release page was observed in an older signed-in instance while its accessibility tree still contained page content. The same URL rendered in isolated profiles. After installing 1.0.2, the restored signed-in tab also rendered and remained visible after refresh. The confirmed page-owner bugs are fixed; the original session's final trigger is still unconfirmed.
- Display diagnostics record lifecycle events, profile/tab IDs and view geometry in `presentation.jsonl`, without page URLs, text, cookies or form input. The file rotates at roughly 2 MB. Valid geometry does not prove that WebKit's compositing output is correct.
- Window Space and pane targeting are improved, but command-bar/find presentation state is still partly shared. Complete restoration of every window and split after restart is not implemented.
- Download resume data is kept only in memory and bounded. The app does not promise resumable downloads across restart.
- Favicon traffic is anonymous and bounded, but it remains separate from the page's website-data-store and content-rule context.
- Device capture, certificate-rotation attacks, every popup/upload variant, complex print layouts, authenticated workflows and DRM need further site/device testing. Passing the current tests does not establish those results.
- Cookie/data clearing waits for WebKit and retains a durable cleanup intent. It does not promise secure erasure of system backups, preserved corrupt recovery files or all operating-system traces.
- There is no Chrome/Safari extension support, password manager or sync. Long-duration resource testing, minimum-system testing and physical Intel Mac validation remain incomplete. Public archives are ad-hoc signed and not notarized.

Before upgrading, quit every older copy and back up your application data. Older versions do not honor the new state-file lock or preserve all new schema fields.
