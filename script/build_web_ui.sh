#!/bin/bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$SRCROOT/WebUI"
if ! command -v node >/dev/null || ! command -v npm >/dev/null; then
  echo 'error: Calshot requires Node.js and npm to build its React workspace.' >&2
  exit 1
fi
if [ ! -d node_modules ]; then npm ci --no-audit --no-fund; fi
npm run build
DESTINATION="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/WebUI"
mkdir -p "$DESTINATION"
rsync -a --delete dist/ "$DESTINATION/"
cp src/tokens.css "$DESTINATION/native-tokens.css"
mkdir -p "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/ThirdPartyNotices"
cp "$SRCROOT/ThirdPartyNotices/PermissionFlow.txt" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/ThirdPartyNotices/PermissionFlow.txt"
