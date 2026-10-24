#!/bin/bash
# Run the unit tests (no browser engine needed at runtime).
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
set +e
# NB: the identity must be a command-line build setting: merely exporting
# CODE_SIGN_IDENTITY does not change what xcodebuild signs with.
xcodebuild -project ToastPeek.xcodeproj -scheme ToastPeekTests -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$OUT/DerivedData" CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}" test > "$OUT/test.log" 2>&1
code=$?
set -e
grep -E "error:|Test Case .* failed|Executed [0-9]+ tests|TEST (SUCCEEDED|FAILED)" "$OUT/test.log" | tail -40 || true
exit $code
