#!/bin/bash
# Build ToastPeek into ~/Developer/Builds/ToastPeek (override with TOASTPEEK_BUILD_DIR).
#   scripts/build.sh            Debug build
#   scripts/build.sh release    Release build
#   scripts/build.sh install    Release build, then copy to /Applications
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TOASTPEEK_BUILD_DIR:-$HOME/Developer/Builds/ToastPeek}"
CONFIG=Debug
[[ "${1:-}" == "release" || "${1:-}" == "install" ]] && CONFIG=Release
export PATH=/opt/homebrew/bin:$PATH
mkdir -p "$OUT"
cd "$ROOT/ToastPeek"
xcodegen generate --quiet
set +e
xcodebuild -project ToastPeek.xcodeproj -scheme ToastPeek -configuration "$CONFIG" \
  -derivedDataPath "$OUT/DerivedData" build > "$OUT/build.log" 2>&1
code=$?
set -e
grep -E "error:|warning: .*ToastPeek/" "$OUT/build.log" | sort -u | head -60 || true
if [ $code -ne 0 ]; then echo "BUILD FAILED (see $OUT/build.log)"; exit $code; fi
APP="$OUT/DerivedData/Build/Products/$CONFIG/ToastPeek.app"
codesign --verify --deep --strict "$APP"
echo "BUILT $APP"
if [[ "${1:-}" == "install" ]]; then
  # Quit like Cmd+Q so Spaces and tabs are saved and the engine shuts down
  # cleanly. SIGTERM is handled the same way by the app (main.swift).
  if pgrep -x ToastPeek >/dev/null; then
    osascript -e 'tell application id "app.toastpeek.mac" to quit' >/dev/null 2>&1 || pkill -TERM -x ToastPeek || true
    for _ in $(seq 1 75); do pgrep -x ToastPeek >/dev/null || break; sleep 0.2; done
    if pgrep -x ToastPeek >/dev/null; then echo "ToastPeek is still running; quit it and re-run." >&2; exit 1; fi
  fi
  rm -rf /Applications/ToastPeek.app
  cp -R "$APP" /Applications/ToastPeek.app
  echo "INSTALLED /Applications/ToastPeek.app"
fi
