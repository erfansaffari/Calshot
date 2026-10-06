#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/build/DerivedData/Build/Products/Debug/Calshot.app"

pkill -x Calshot >/dev/null 2>&1 || true
xcodebuild build -quiet \
  -project "$ROOT_DIR/Calshot.xcodeproj" \
  -scheme Calshot \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$ROOT_DIR/build/DerivedData" \
  CODE_SIGNING_ALLOWED=YES

case "$MODE" in
  run)
    /usr/bin/open -n "$APP_BUNDLE"
    ;;
  --debug|debug)
    lldb -- "$APP_BUNDLE/Contents/MacOS/Calshot"
    ;;
  --logs|logs)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate 'process == "Calshot"'
    ;;
  --telemetry|telemetry)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.calshot.app"'
    ;;
  --verify|verify)
    /usr/bin/open -n "$APP_BUNDLE"
    sleep 1
    pgrep -x Calshot >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
