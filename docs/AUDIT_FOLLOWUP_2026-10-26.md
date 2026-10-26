# Favicon audit for 1.0.3

Date: October 26, 2026. Baseline: 1.0.2 (`0ede2afaf5f240f3e29b96e3807f19571feca73b`).

## Changes

Favicon cache keys now include the tab's stable profile UUID and complete origin, including scheme and port. Paths and query strings do not affect the key. Each BrowserStore owns its cache next to its state file, so temporary test state also uses temporary icon storage.

Requests run through the owning WKWebView. A script captures native APIs at document start and performs bounded, same-origin fetches in the page world. This uses the profile's cookies, WebKit content rules and the document's CSP connect-src policy. URLs with credentials and all redirects are refused. There is no URLSession or isolated-world fallback.

The initial isolated-world implementation failed a dedicated CSP test: `connect-src 'none'` still allowed a 69-byte icon response and the server received the request. Moving the request into the page world fixed both assertions. Page overrides of fetch, btoa, timers and AbortController methods are covered separately.

An invalid linked image now falls back to the same origin's `/favicon.ico`. Responses are limited to 512 KiB, including streams without Content-Length, and aborted after six seconds. Accepted images must be no larger than 1024 by 1024 pixels; the cache decodes the first frame into a thumbnail of at most 64 px.

Removing a Space waits for its profile's icon files to be cleared before completing the durable deletion intent. Clearing all icons or removing a profile invalidates older asynchronous results and clears retained image slots. A visible slot is reused after NSCache eviction so later results still update the displayed image.

## Validation

`scripts/test.sh headless` passed 52 tests locally with no test windows:

- 36 core tests.
- 9 real WebKit tests for profile cookies, page API overrides, content rules, CSP, cross-origin URLs and redirects, the exact byte limit, the request deadline, controller fallback, Space deletion and data clearing.
- 5 cache tests for profile/origin separation and disk restoration, stale results after clearing, scoped profile removal, decoded thumbnail size and invalid images.
- 2 SQLite history import tests.

A 1024 by 512 PNG produced a 64 by 32 CGImage with a pixel buffer no larger than 8192 bytes. This verifies cached image dimensions; whole-application RSS, peak decode memory and browsing responsiveness were not measured.

The universal Release passed complete Swift concurrency checks with Swift warnings treated as errors, bundle signature verification and localization extraction checks. The final release is also built separately for arm64. CI runs the full core, AppKit and WebKit suites; the headless command does not replace that coverage.

## Limits

Icons available only from another origin, through a redirect, or blocked by connect-src can show the globe placeholder. History and Boost records lack a stored profile and use the placeholder. Old host-only cache files are ignored rather than assigned to an account; Clear Browsing Data removes them.

NSCache has a countLimit of 512, and visible views may retain additional slots. Disk cleanup targets 512 files or 25 MB; filesystem failures can prevent deletion. These are not hard limits on all live objects or guaranteed disk usage.

This work does not close the original intermittent blank-page diagnosis, complete window restoration, device/site compatibility testing or long-duration resource testing. See [reliability notes](RELIABILITY.md).
