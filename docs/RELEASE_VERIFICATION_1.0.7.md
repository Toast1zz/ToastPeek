# ToastPeek 1.0.7 release verification

## Source and release

- Final tested source commit: `216bac900c7e3a8e7cb65ad4f76a54db3aa4f0d4`.
- Tag: `v1.0.7` points exactly to that commit.
- GitHub release: https://github.com/Toast1zz/ToastPeek/releases/tag/v1.0.7
- Version/build: `1.0.7` / `8`.
- Older v1.0.5 and v1.0.6 tags are superseded; no v1.0.6 GitHub release was published.

## Scope

Audit remediation covers state integrity and instance write locking, profile-scoped site permissions and favicon state, multi-window ownership and find state, import/UI regressions, download commit/cancellation barriers, installer rollback, strict-concurrency SDK compatibility, and quit recovery. The public Arc sidebar-import boundary remains removed. Library file icons decode to bounded PNG data off the main actor before the UI creates `NSImage`; its regression test is included.

Legacy archived records without `archivedAt` retain deterministic `lastVisitedAt` ordering and are not silently purged when age cannot be established. Records with a known close timestamp retain the existing 30-day purge behavior.

## Tests, CI, and packages

- Local core: 39/39 passed.
- Local integration: 65/65 passed, including the bounded file-icon regression test.
- Final CI: run `41348663838` succeeded on commit `216bac900c7e3a8e7cb65ad4f76a54db3aa4f0d4`: https://github.com/Toast1zz/ToastPeek/actions/runs/41348663838
- CI completed core/WebKit tests and strict arm64/universal packaging successfully on the macOS runner.
- Final public arm64 ZIP: `ToastPeek-1.0.7-arm64.zip`, SHA-256 `f623b3cc1ed702fe3ab045a9e7e1c33b8d19df062617703e4f5b8a822e65ac75`.
- Final public universal ZIP: `ToastPeek-1.0.7-universal.zip`, SHA-256 `cd5146b65ab6a63f9b37fab82539d5f1138fac68911fab23a5608cac5d131264`.
- Public download round-trip verified both URLs: unpacked Info.plist is 1.0.7/build 8; arm64 archive is arm64 and universal archive is x86_64+arm64; both pass `codesign --verify --deep --strict`.
- Public archives are ad-hoc signed and not notarized.

## Quit and persistence evidence

All fixtures use owned isolated support directories and Popen-owned processes; no real user profile was used.

- SIGTERM: `/tmp/toastpeek-matrix6-aofdcu1k/evidence.json`; ready state, rc 0 in 0.022 seconds, state JSON decoded with spaces/currentSpaceID/tabs.
- Cmd-Q confirmation: `/tmp/toastpeek-matrix6-2q5hk6k0/evidence.json`; normal exit.
- Cmd-Q cancellation and retry: `/tmp/toastpeek-matrix6-6k83ccl4/evidence.json`; cancel left the process alive, retry exited normally, state JSON decoded.
- Pending slow download cancellation: `/tmp/toastpeek-download-ajopr5mp/evidence.json`; staging partials were removed after rc 0 in 0.024 seconds.
- Actual NSSavePanel download sheet: `/tmp/toastpeek-dlpanel-l97k9mr1/evidence.json`; panel was present, rc 0 in 0.300 seconds, staging files removed.
- Dock-equivalent exact-PID API: `/tmp/toastpeek-pidterm6c-jix6y112/evidence.json`; `NSRunningApplication.terminate()` returned true and the owned process exited rc 0 in 0.069 seconds with persisted state.

AppleScript probes returning user-cancelled `-128` are recorded as cancellation observations, not confirmation success. CUA/manual visual acceptance, VoiceOver, Intel hardware, lowest-supported macOS, Developer ID distribution signing, and notarization were not claimed.

## Installation evidence

The final Apple Development candidate was installed transactionally at `/Applications/ToastPeek.app`. Pre-install snapshot: `/Users/toast1/Developer/Builds/ToastPeek/Release1.0.7/InstallSnapshot`; no installed ToastPeek PID was running before swap. The staged bundle passed deep strict verification before and after swap; installed Info.plist is 1.0.7/build 8 and codesign reports Apple Development with TeamIdentifier N6EN6RZKF2.
Installed runtime evidence: `/Users/toast1/Developer/Builds/ToastPeek/Release1.0.7/InstallSnapshot/runtime-normal-evidence.json` records `/Applications/ToastPeek.app/Contents/MacOS/ToastPeek` PID 41361 alive after 4 seconds, SIGTERM, Popen return code 0, and exit elapsed 0.058 seconds. The release app intentionally ignores `TOASTPEEK_SUPPORT_DIR`; no state contents were read or deleted, so this verifies installed process launch/exit but not a state-file mutation baseline. The separate isolated override attempt PID 41256 also exited rc0 in 0.056 seconds without a state marker.
