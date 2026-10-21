#!/usr/bin/env bash
# A production image requires a notarized Developer ID app. --fixture is local verification only.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE=false
if [[ "${1:-}" == --fixture ]]; then FIXTURE=true; shift; fi
APP_PATH="${1:?Usage: package_dmg.sh [--fixture] APP_PATH OUTPUT_DMG}"
OUTPUT_DMG="${2:?Supply the output DMG path}"
[[ -d "$APP_PATH/Contents" && "$OUTPUT_DMG" == *.dmg ]] || { echo 'Supply an app bundle and a .dmg output path.' >&2; exit 1; }
[[ ! -e "$OUTPUT_DMG" ]] || { echo 'The output already exists. Use a new path to preserve the previous artifact.' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")" == com.calshot.app ]] || { echo 'Expected the Calshot app bundle.' >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$APP_PATH"
VOLUME_NAME="Calshot"
if "$FIXTURE"; then
  VOLUME_NAME="Calshot Packaging Preview"
  echo 'Building an unnotarized packaging fixture. Do not publish this image.' >&2
else
  /usr/bin/codesign -dv "$APP_PATH" 2>&1 | /usr/bin/grep -q '^Authority=Developer ID Application:' || { echo 'A Developer ID Application-signed app is required.' >&2; exit 1; }
  xcrun stapler validate "$APP_PATH"
  /usr/sbin/spctl --assess --type execute "$APP_PATH"
fi
DMG_PYTHON="${DMG_PYTHON:-$ROOT_DIR/build/DMGTools/bin/python3}"
if [[ ! -x "$DMG_PYTHON" ]]; then python3 -m venv "$ROOT_DIR/build/DMGTools"; fi
"$DMG_PYTHON" -m pip install --disable-pip-version-check -r "$ROOT_DIR/script/dmg-requirements.txt"
mkdir -p "$(dirname "$OUTPUT_DMG")"
"$DMG_PYTHON" -m dmgbuild -s "$ROOT_DIR/script/dmg_settings.py" -D "application=$APP_PATH" "$VOLUME_NAME" "$OUTPUT_DMG"
/usr/bin/hdiutil verify "$OUTPUT_DMG"

"$ROOT_DIR/script/verify_dmg.sh" "$OUTPUT_DMG" "$APP_PATH"
