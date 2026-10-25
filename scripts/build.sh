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
rg "(^|[[:space:]])(error|warning):" "$OUT/build.log" | sort -u | head -60 || true
if [ $code -ne 0 ]; then echo "BUILD FAILED (see $OUT/build.log)"; exit $code; fi
APP="$OUT/DerivedData/Build/Products/$CONFIG/ToastPeek.app"
codesign --verify --deep --strict "$APP"
echo "BUILT $APP"
if [[ "${1:-}" == "install" ]]; then
  # Stop only the installed bundle, rather than every process named ToastPeek.
  # The app handles SIGTERM through its normal save/quit path.
  installed_pids="$(ps -axo pid=,comm= | awk '$2 == "/Applications/ToastPeek.app/Contents/MacOS/ToastPeek" { print $1 }')"
  if [[ -n "$installed_pids" ]]; then
    kill -TERM $installed_pids
    for _ in $(seq 1 75); do
      alive=0
      for pid in $installed_pids; do kill -0 "$pid" 2>/dev/null && alive=1; done
      [[ $alive -eq 0 ]] && break
      sleep 0.2
    done
    if [[ $alive -ne 0 ]]; then echo "The installed browser has not finished saving; installation stopped." >&2; exit 1; fi
  fi
  staged="/Applications/.ToastPeek-install-$$.app"
  ditto "$APP" "$staged"
  codesign --verify --deep --strict "$staged"
  if [[ -e /Applications/ToastPeek.app ]]; then
    mv /Applications/ToastPeek.app "/Applications/ToastPeek-backup-$(date +%Y%m%d-%H%M%S)-$$.app"
  fi
  mv "$staged" /Applications/ToastPeek.app
  echo "INSTALLED /Applications/ToastPeek.app (previous bundle preserved)"
fi
