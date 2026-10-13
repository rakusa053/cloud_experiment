#!/bin/bash
# スクショギャラリーをダウンロードして「アプリケーション」フォルダに入れる
set -euo pipefail

URL="https://github.com/rakusa053/cloud_experiment/releases/download/mac-app-latest/ScreenshotGallery.zip"
APP_NAME="スクショギャラリー.app"

DEST="/Applications"
if [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "ダウンロードしています…"
curl -fsSL "$URL" -o "$TMP/app.zip"
ditto -x -k "$TMP/app.zip" "$TMP"

pkill -x ScreenshotGallery 2>/dev/null || true
rm -rf "${DEST:?}/$APP_NAME"
mv "$TMP/$APP_NAME" "$DEST/"
xattr -dr com.apple.quarantine "$DEST/$APP_NAME" 2>/dev/null || true

echo "インストールしました: $DEST/$APP_NAME"
open "$DEST/$APP_NAME"
