#!/bin/bash
set -e

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="/private/tmp/echowrite-derived-data"

echo "=== 1/4 先建置 Rust 核心與 iOS XCFramework ==="
bash "$ROOT_DIR/scripts/build_ios.sh"

echo "=== 1.5/4 產生 iOS Xcode 專案 (EchoWriteApp 主程式 + EchoWriteKeyboard 鍵盤擴充) ==="
(cd "$ROOT_DIR/ios" && xcodegen generate)

echo "=== 2/4 建置 iOS App（含內嵌的 Keyboard Extension） ==="
xcodebuild \
  -project "$ROOT_DIR/ios/EchoWrite.xcodeproj" \
  -scheme EchoWriteApp \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA/ios" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

echo "=== 3/4 建置 macOS App ==="
xcodebuild \
  -project "$ROOT_DIR/macos/EchoWriteMac.xcodeproj" \
  -scheme EchoWriteMac \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA/macos" \
  build

echo "=== 4/4 完成 ==="
