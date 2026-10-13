#!/bin/bash
# スクショギャラリー.app をビルドする（macOS + Xcode Command Line Tools が必要）
set -euo pipefail
cd "$(dirname "$0")"

APP="build/スクショギャラリー.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  xcrun swiftc -O -parse-as-library \
    -target "$arch-apple-macos13.0" \
    -o "build/ScreenshotGallery-$arch" \
    Sources/ScreenshotGallery.swift
done
lipo -create -output "$APP/Contents/MacOS/ScreenshotGallery" build/ScreenshotGallery-*

cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

echo "Built: $(pwd)/$APP"
