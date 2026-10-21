#!/usr/bin/env bash
# Verify the app inside the finished image, not just the disk image checksum.
set -euo pipefail
IMAGE_PATH="${1:?Usage: verify_dmg.sh IMAGE_DMG [SOURCE_APP]}"
SOURCE_APP="${2:-}"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/calshot-dmg-check.XXXXXX")"
MOUNT_DIR="$CHECK_DIR/mounted"
mkdir "$MOUNT_DIR"
cleanup() {
  hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
  rmdir "$MOUNT_DIR" 2>/dev/null || true
  rm -f "$CHECK_DIR/mount.plist"
  rmdir "$CHECK_DIR" 2>/dev/null || true
}
trap cleanup EXIT
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_DIR" -plist "$IMAGE_PATH" > "$CHECK_DIR/mount.plist"
[[ -d "$MOUNT_DIR/Calshot.app/Contents" && -f "$MOUNT_DIR/.DS_Store" ]] || { echo 'DMG is missing Calshot or its Finder layout.' >&2; exit 1; }
[[ -L "$MOUNT_DIR/Applications" && "$(readlink "$MOUNT_DIR/Applications")" == /Applications ]] || { echo 'DMG Applications shortcut is invalid.' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$MOUNT_DIR/Calshot.app/Contents/Info.plist")" == com.calshot.app ]] || { echo 'DMG contains an unexpected app.' >&2; exit 1; }
codesign --verify --deep --strict "$MOUNT_DIR/Calshot.app"
if [[ -n "$SOURCE_APP" ]]; then
  cmp "$SOURCE_APP/Contents/Info.plist" "$MOUNT_DIR/Calshot.app/Contents/Info.plist"
fi
echo 'DMG contents verified: Calshot signature, Applications shortcut and Finder layout.'
