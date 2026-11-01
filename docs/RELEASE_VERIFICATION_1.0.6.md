# ToastPeek 1.0.6 release verification

## Published source

- Release commit: `1b4f25b91e9c10096be96a1f0a43d3609e4f3fac`
- Parent: `48ceddb55609525def479adbfa1fd756ce6786b7`, itself based on public `v1.0.4` commit `b793c9af79cf196bb6a3175e6f37c596566d534a`.
- Version: `1.0.6` / build `7`.
- Tag: `v1.0.6`.
- The prior `v1.0.5` release is explicitly superseded because it did not retain the bounded file-icon decoding fix; it remains available for reproducibility.

## Scope delivered

The release includes the audit remediation work for state integrity and instance write locking, profile-scoped site permissions and favicon state, multi-window ownership and find state, import and UI regressions, download commit/cancellation barriers, installer transaction rollback, and the quit recovery path. The public Arc sidebar-import boundary remains removed. Library file icons are decoded to bounded PNG data off the main actor before the UI creates an `NSImage`; the corresponding regression test is included.

Legacy archived records without `archivedAt` retain deterministic `lastVisitedAt` ordering and are not silently purged when their age cannot be established. Records with a known close timestamp retain the existing 30-day purge behavior.

## Automated evidence

- Core tests: 39/39 passed. Log: `/tmp/toastpeek-v106-tests`.
- Integration tests: 65/65 passed. Same output directory: `/tmp/toastpeek-v106-tests`.
- Strict package build: `scripts/package.sh all`, warnings-as-errors and localization validation passed.
- Arm64 archive: `/tmp/toastpeek-v106-pack/Releases/1.0.6/ToastPeek-1.0.6-arm64.zip`; SHA-256 `917a0d6b7d01f2fa8d71737bf5d2bd34262d9e362f6d553297e74ed5b33d97b1`.
- Universal archive: `/tmp/toastpeek-v106-pack/Releases/1.0.6/ToastPeek-1.0.6-universal.zip`; SHA-256 `3c6970f85d454c12329cb75518ef8e981303d1834a7432d5a1bcb881bc9a9d8e`.
- Both archives were validated by the package script for arm64/universal architecture, version/build metadata, localization, and deep strict ad-hoc signature.

## Quit and persistence matrix

All fixtures use owned isolated support directories and Popen-owned processes; no real user profile was used.

- SIGTERM: `/tmp/toastpeek-matrix6-aofdcu1k/evidence.json`; readiness state observed, return code 0 in 0.022 seconds, state JSON 3185 bytes with decoded spaces/currentSpaceID/tabs.
- Cmd-Q confirm: `/tmp/toastpeek-matrix6-2q5hk6k0/evidence.json`; confirmation path exited normally.
- Cmd-Q cancel then retry: `/tmp/toastpeek-matrix6-6k83ccl4/evidence.json`; cancel left the process alive, retry confirmation exited normally, state JSON decoded.
- Pending slow download cancellation: `/tmp/toastpeek-download-ajopr5mp/evidence.json`; partial staging files were removed after return code 0 in 0.024 seconds.
- Download save-panel sheet: `/tmp/toastpeek-dlpanel-l97k9mr1/evidence.json`; `NSSavePanel` was actually present, return code 0 in 0.300 seconds, and staging files were removed.
- Dock-equivalent PID API: `/tmp/toastpeek-pidterm6c-jix6y112/evidence.json`; `NSRunningApplication.terminate()` returned `true`, process return code 0 in 0.069 seconds, state JSON 3185 bytes.

AppleScript quit probes that returned user-cancelled `-128` are recorded as cancellation observations, not as successful confirmation. CUA/manual visual, VoiceOver, Intel hardware, lowest-supported macOS, notarization, and Developer ID signing were not available and are not claimed.

## Public release

- GitHub release: https://github.com/Toast1zz/ToastPeek/releases/tag/v1.0.6
- Expected assets: `ToastPeek-1.0.6-arm64.zip` and `ToastPeek-1.0.6-universal.zip`.
- Build output is ad-hoc signed and not notarized. Remote asset digests and download round-trip verification are recorded after upload; CI status is recorded separately and is not called green until the run completes.
