#!/bin/bash
# Build public, ad-hoc signed Release archives for arm64 and/or universal Macs.
#   scripts/package.sh [all|arm64|universal]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TOASTPEEK_BUILD_DIR:-$HOME/Developer/Builds/ToastPeek}"
MODE="${1:-all}"
case "$MODE" in
  all) variants=(arm64 universal) ;;
  arm64|universal) variants=("$MODE") ;;
  *) echo "Usage: scripts/package.sh [all|arm64|universal]" >&2; exit 2 ;;
esac
export PATH=/opt/homebrew/bin:$PATH
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/ToastPeek/config/ToastPeek-Info.plist")"
RELEASE_DIR="$OUT/Releases/$VERSION"
mkdir -p "$RELEASE_DIR"
cd "$ROOT/ToastPeek"
xcodegen generate --quiet
for variant in "${variants[@]}"; do
  archs=arm64
  [[ "$variant" == universal ]] && archs="arm64 x86_64"
  build_dir="$OUT/Release-$variant"
  mkdir -p "$build_dir"
  if ! xcodebuild -project ToastPeek.xcodeproj -scheme ToastPeek -configuration Release \
    -derivedDataPath "$build_dir/DerivedData" CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
    ARCHS="$archs" ONLY_ACTIVE_ARCH=NO SWIFT_STRICT_CONCURRENCY=complete \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES build > "$build_dir/build.log" 2>&1; then
    echo "BUILD FAILED ($variant; see $build_dir/build.log)" >&2
    tail -50 "$build_dir/build.log" >&2
    exit 1
  fi
  app="$build_dir/DerivedData/Build/Products/Release/ToastPeek.app"
  codesign --verify --deep --strict "$app"
  actual_archs="$(lipo -archs "$app/Contents/MacOS/ToastPeek")"
  if [[ "$variant" == arm64 ]]; then
    [[ "$actual_archs" == arm64 ]] || { echo "Unexpected arm64 binary: $actual_archs" >&2; exit 1; }
  else
    lipo -verify_arch arm64 x86_64 "$app/Contents/MacOS/ToastPeek"
  fi
  TOASTPEEK_DERIVED_DATA="$build_dir/DerivedData" python3 "$ROOT/scripts/l10n_missing.py" Release
  archive="$RELEASE_DIR/ToastPeek-$VERSION-$variant.zip"
  # Write a fresh archive, then rename, so failed packaging leaves the old one intact.
  temporary="$RELEASE_DIR/.ToastPeek-$VERSION-$variant-$$.zip"
  trap 'rm -f "$temporary"' EXIT
  ditto -c -k --sequesterRsrc --keepParent "$app" "$temporary"
  mv "$temporary" "$archive"
  trap - EXIT
  shasum -a 256 "$archive"
done
