#!/bin/bash
# Build ToastPeek (signed, WebKit) into ~/Developer/Builds/ToastPeek.
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
grep -E "(^|[[:space:]])(error|warning):" "$OUT/build.log" | sort -u | head -60 || true
if [ $code -ne 0 ]; then echo "BUILD FAILED (see $OUT/build.log)"; exit $code; fi
APP="$OUT/DerivedData/Build/Products/$CONFIG/ToastPeek.app"
codesign --verify --deep --strict "$APP"
echo "BUILT $APP"
if [[ "${1:-}" == "install" ]]; then
  install_dir="${TOASTPEEK_INSTALL_DIR:-/Applications}"
  installed="$install_dir/ToastPeek.app"
  # Stop only the installed bundle and let it complete its normal save/quit path.
  installed_pids="$(ps -axo pid=,comm= | awk -v executable="$installed/Contents/MacOS/ToastPeek" '$2 == executable { print $1 }')"
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

  # Keep rollback on the installation volume, and the durable backup outside it.
  # A private directory also keeps the backup from appearing as another app.
  umask 077
  mkdir -p "$OUT/InstallBackups"
  chmod 700 "$OUT/InstallBackups"
  backup_root="$(cd "$OUT/InstallBackups" && pwd -P)"
  install_root="$(cd "$install_dir" && pwd -P)"
  case "$backup_root/" in
    "$install_root/"*) echo "Backup directory must be outside the installation directory." >&2; exit 1 ;;
  esac
  transaction="$(mktemp -d "$install_root/.ToastPeek-install.XXXXXX")"
  staged="$transaction/staged.app"
  previous="$transaction/previous.app"
  old_moved=0
  new_installed=0
  backup=""
  backup_complete=0
  cleanup_install() {
    status=$?
    trap - EXIT HUP INT TERM
    set +e
    if [[ $status -ne 0 ]]; then
      if [[ $new_installed -eq 1 ]]; then
        rm -rf "$installed"
      fi
      if [[ $old_moved -eq 1 ]]; then
        if ! mv "$previous" "$installed"; then
          echo "Rollback failed; previous bundle remains at $previous" >&2
          return "$status"
        fi
      fi
    fi
    if [[ -n "$backup" && $backup_complete -eq 0 ]]; then
      rm -rf "$backup"
    fi
    rm -rf "$transaction"
    return "$status"
  }
  trap cleanup_install EXIT
  trap 'exit 1' HUP INT TERM

  ditto "$APP" "$staged"
  codesign --verify --deep --strict "$staged"
  cmp -s "$APP/Contents/Info.plist" "$staged/Contents/Info.plist"
  if [[ -e "$installed" ]]; then
    backup="$(mktemp -d "$backup_root/install.XXXXXX")"
    ditto "$installed" "$backup/previous"
    codesign --verify --deep --strict "$backup/previous"
    cmp -s "$installed/Contents/Info.plist" "$backup/previous/Contents/Info.plist"
    backup_complete=1
    mv "$installed" "$previous"
    old_moved=1
  fi
  mv "$staged" "$installed"
  new_installed=1
  codesign --verify --deep --strict "$installed"
  cmp -s "$APP/Contents/Info.plist" "$installed/Contents/Info.plist"
  echo "INSTALLED $installed (previous bundle preserved in $backup_root when present)"
  trap - EXIT HUP INT TERM
  rm -rf "$transaction"
fi
