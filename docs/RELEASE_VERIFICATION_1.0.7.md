# ToastPeek 1.0.7 release verification

Version `1.0.7`, build `8`; source commit `b17a15fb4d54658ce7a5125368a6f67ef078c957`.
The historical `v1.0.5` and `v1.0.6` tags are superseded. No v1.0.6 GitHub release was published; v1.0.7 is authoritative.

## Scope

Audit remediation covers state integrity and instance write locking, profile-scoped site permissions and favicon state, multi-window ownership and find state, import/UI regressions, download commit/cancellation barriers, installer rollback, and quit recovery. The public Arc sidebar-import boundary remains removed. Library file icons decode to bounded PNG data off the main actor before the UI creates `NSImage`; its regression test is included.

Legacy archived records without `archivedAt` retain deterministic `lastVisitedAt` ordering and are not silently purged when age cannot be established. Known close timestamps retain the existing 30-day purge behavior.

## Automated evidence

- Core: 39/39 passed; integration: 65/65 passed. Output: `/tmp/toastpeek-v107`.
- Strict `scripts/package.sh all` passed with warnings-as-errors and localization validation.
- Arm64 ZIP: `/tmp/toastpeek-v107-pack/Releases/1.0.7/ToastPeek-1.0.7-arm64.zip`; SHA-256 `58647140dece2d4e611b2e93893a134e4decdc89ec8c29faab5fd944e756b91e`.
- Universal ZIP: `/tmp/toastpeek-v107-pack/Releases/1.0.7/ToastPeek-1.0.7-universal.zip`; SHA-256 `32b3a7597e34c3ad455031a6caa2622497c4fb8fdadfac3de2240752d68e7331`.
- Both archives were checked for version/build metadata, architecture, localization, and deep strict ad-hoc signatures.

## Quit/persistence evidence

Owned isolated Popen fixtures: SIGTERM `/tmp/toastpeek-matrix6-aofdcu1k/evidence.json`; Cmd-Q confirm `/tmp/toastpeek-matrix6-2q5hk6k0/evidence.json`; Cmd-Q cancel/retry `/tmp/toastpeek-matrix6-6k83ccl4/evidence.json`; pending download `/tmp/toastpeek-download-ajopr5mp/evidence.json`; NSSavePanel barrier `/tmp/toastpeek-dlpanel-l97k9mr1/evidence.json`; exact-PID Dock-equivalent API `/tmp/toastpeek-pidterm6c-jix6y112/evidence.json`. They verify normal rc0 exits, persisted state, cancellation, partial cleanup, an actual save-panel sheet, and `NSRunningApplication.terminate()` returning true with owned-process exit rc0 in 0.069 seconds.

AppleScript probes returning user-cancelled `-128` are recorded as cancellation observations, not confirmation success. CUA/manual visual, VoiceOver, Intel hardware, lowest-supported macOS, notarization, and Developer ID signing were unavailable and are not claimed.

## CI/publication

Final source CI run: 41345875305, https://github.com/Toast1zz/ToastPeek/actions/runs/41345875305. Its result is recorded only after completion; no green claim is made while it is in progress.

Expected public assets are `ToastPeek-1.0.7-arm64.zip` and `ToastPeek-1.0.7-universal.zip` with the hashes above. The build is ad-hoc signed and not notarized.
