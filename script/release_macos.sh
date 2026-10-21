#!/usr/bin/env bash
# Builds and verifies artifacts only. Publishing is a separate workflow step.
set -euo pipefail
umask 077
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:?Usage: release_macos.sh VERSION BUILD_NUMBER}"
BUILD_NUMBER="${2:?Supply an increasing numeric build number}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Use a stable version such as 1.0.0.' >&2; exit 1; }
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || { echo 'Build number must be a positive integer.' >&2; exit 1; }
: "${SIGNING_IDENTITY:?Set a Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set a notarytool keychain profile}"
[[ "$SIGNING_IDENTITY" == 'Developer ID Application: '* ]] || { echo 'A Developer ID Application certificate is required.' >&2; exit 1; }
security find-identity -v -p codesigning | rg -F "$SIGNING_IDENTITY" >/dev/null || { echo 'Distribution signing identity is unavailable.' >&2; exit 1; }
OUT_DIR="$ROOT_DIR/build/release"
TOOLS_DIR="$OUT_DIR/sparkle"
mkdir -p "$OUT_DIR" "$TOOLS_DIR"
curl --fail --location --retry 3 --output "$OUT_DIR/Sparkle.tar.xz" https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz
(cd "$OUT_DIR" && echo 'c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c  Sparkle.tar.xz' | shasum -a 256 -c -)
tar -xf "$OUT_DIR/Sparkle.tar.xz" -C "$TOOLS_DIR"
npm --prefix "$ROOT_DIR/WebUI" ci
npm --prefix "$ROOT_DIR/WebUI" run build
xcodebuild archive -project "$ROOT_DIR/Calshot.xcodeproj" -scheme Calshot -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$OUT_DIR/Calshot.xcarchive" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" ENABLE_HARDENED_RUNTIME=YES
APP_PATH="$OUT_DIR/Calshot.xcarchive/Products/Applications/Calshot.app"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dv --verbose=4 "$APP_PATH" 2> "$OUT_DIR/signing.txt"
rg 'Authority=Developer ID Application:' "$OUT_DIR/signing.txt" >/dev/null
rg 'flags=.*runtime' "$OUT_DIR/signing.txt" >/dev/null
lipo -verify_arch arm64 x86_64 "$APP_PATH/Contents/MacOS/Calshot"
# The first ZIP is only for Apple's notarization service; publish the stapled archive below.
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$OUT_DIR/notarization.zip"
NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then NOTARY_ARGS+=(--keychain "$NOTARY_KEYCHAIN"); fi
xcrun notarytool submit "$OUT_DIR/notarization.zip" "${NOTARY_ARGS[@]}" --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"
ARCHIVE_NAME="Calshot-$VERSION.zip"
FEED_DIR="$(mktemp -d "$OUT_DIR/feed.XXXXXX")"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$FEED_DIR/$ARCHIVE_NAME"
SIGNING_ARGS=(--account com.calshot.updates)
if [[ -n "${SPARKLE_KEY_FILE:-}" ]]; then SIGNING_ARGS=(--ed-key-file "$SPARKLE_KEY_FILE"); fi
# Carry previous signed items forward and reject build-number downgrades before publishing.
curl --fail --location --retry 3 --output "$OUT_DIR/previous.xml" https://github.com/erfansaffari/Calshot/releases/download/updates/appcast.xml
"$TOOLS_DIR/bin/sign_update" "${SIGNING_ARGS[@]}" --verify "$OUT_DIR/previous.xml"
python3 - "$OUT_DIR/previous.xml" "$BUILD_NUMBER" <<'PY'
import sys, xml.etree.ElementTree as ET
versions = [int(e.text) for e in ET.parse(sys.argv[1]).iter('{http://www.andymatuschak.org/xml-namespaces/sparkle}version')]
if versions and int(sys.argv[2]) <= max(versions):
    sys.exit('Build number must be greater than every published build.')
PY
"$TOOLS_DIR/bin/generate_appcast" "${SIGNING_ARGS[@]}" --maximum-deltas 0 \
  --download-url-prefix "https://github.com/erfansaffari/Calshot/releases/download/v$VERSION/" \
  -o "$FEED_DIR/appcast.xml" "$FEED_DIR"
# Editing invalidates the generated feed signature; sign the complete XML again after merging.
python3 - "$OUT_DIR/previous.xml" "$FEED_DIR/appcast.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
ET.register_namespace('sparkle', 'http://www.andymatuschak.org/xml-namespaces/sparkle')
old, new = ET.parse(sys.argv[1]), ET.parse(sys.argv[2])
channel = new.find('channel')
for item in old.findall('./channel/item')[:9]: channel.append(item)
new.write(sys.argv[2], encoding='utf-8', xml_declaration=True)
PY
"$TOOLS_DIR/bin/sign_update" "${SIGNING_ARGS[@]}" "$FEED_DIR/appcast.xml"
"$TOOLS_DIR/bin/sign_update" "${SIGNING_ARGS[@]}" --verify "$FEED_DIR/appcast.xml"
(cd "$FEED_DIR" && shasum -a 256 "$ARCHIVE_NAME" > SHA256SUMS)
mkdir -p "$OUT_DIR/feed"
cp "$FEED_DIR/$ARCHIVE_NAME" "$FEED_DIR/appcast.xml" "$FEED_DIR/SHA256SUMS" "$OUT_DIR/feed/"
rm -r "$FEED_DIR"
echo "Verified release artifacts: $OUT_DIR/feed"
