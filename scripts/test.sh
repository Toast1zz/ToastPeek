#!/bin/bash
# Run core logic and real AppKit/WebKit integration tests.
#   scripts/test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TOASTPEEK_BUILD_DIR:-$HOME/Developer/Builds/ToastPeek}"
export PATH=/opt/homebrew/bin:$PATH
# SSH sessions cannot reach the login keychain, so default to ad-hoc
# signing (overridable) instead of failing with errSecInternalComponent.
export CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
mkdir -p "$OUT"
cd "$ROOT/ToastPeek"
xcodegen generate --quiet
schemes=(ToastPeekTests ToastPeekIntegrationTests)
if [[ "${1:-}" == "core" ]]; then schemes=(ToastPeekTests); fi
if [[ "${1:-}" == "integration" ]]; then schemes=(ToastPeekIntegrationTests); fi
test_args=(test)
if [[ -n "${TOASTPEEK_TEST_FILTER:-}" ]]; then test_args+=("-only-testing:$TOASTPEEK_TEST_FILTER"); fi
for scheme in "${schemes[@]}"; do
  log="$OUT/$scheme.log"
  set +e
  xcodebuild -project ToastPeek.xcodeproj -scheme "$scheme" -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$OUT/DerivedData" CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}" "${test_args[@]}" > "$log" 2>&1
  code=$?
  set -e
  grep -E "^[^[:space:]].*:[0-9]+:[0-9]+: (error|warning):|^Test Case .* failed|Executed [0-9]+ tests?|TEST (SUCCEEDED|FAILED)" "$log" | tail -40 || true
  if [[ $code -eq 0 ]] && ! grep -Eq "Executed [1-9][0-9]* tests?" "$log"; then echo "No tests ran; see $log" >&2; exit 1; fi
  if [[ $code -ne 0 ]]; then echo "Tests failed; see $log" >&2; exit "$code"; fi
done
