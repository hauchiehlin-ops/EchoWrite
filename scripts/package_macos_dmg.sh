#!/usr/bin/env bash
set -euo pipefail

# EchoWrite macOS DMG 獨立分發 / 官網下載安裝檔打包腳本
# 輸出：EchoWrite-<版本號>.dmg

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/scripts/build/macos_dmg}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist}"
APP_VERSION="${APP_VERSION:-2.3.0}"
BUILD_NUMBER="${BUILD_NUMBER:-17}"
DMG_NAME="EchoWrite-${APP_VERSION}.dmg"
DMG_OUTPUT_PATH="$OUTPUT_DIR/$DMG_NAME"
INFO_PLIST="$ROOT_DIR/macos/EchoWriteMac-Info.plist"
MAC_ICON_SOURCE="$ROOT_DIR/chrome-extension/assets/echowrite-floating-icon.png"
MAC_ICONSET_DIR="$ROOT_DIR/macos/AppIcon.iconset"
MAC_ICNS_PATH="$ROOT_DIR/macos/EchoWriteMac.icns"

echo "=== EchoWrite macOS DMG 打包流程 ==="
echo "Version: $APP_VERSION ($BUILD_NUMBER)"
echo "Output:  $DMG_OUTPUT_PATH"

# 0. 同步更新 Info.plist 版本資訊
if [[ -f "$INFO_PLIST" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$INFO_PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $APP_VERSION" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$INFO_PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$INFO_PLIST"
fi

# 1. 產生高解析度 ICNS 圖示
if [[ -f "$MAC_ICON_SOURCE" ]]; then
  echo "--- 正在產生 macOS 圖示 (.icns) ---"
  mkdir -p "$MAC_ICONSET_DIR"
  MAC_ICON_SOURCE="$MAC_ICON_SOURCE" MAC_ICONSET_DIR="$MAC_ICONSET_DIR" python3 <<'PY'
import os
from pathlib import Path
from PIL import Image

src = Path(os.environ["MAC_ICON_SOURCE"])
out_dir = Path(os.environ["MAC_ICONSET_DIR"])
img = Image.open(src).convert("RGBA")
sizes = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]
for name, size in sizes:
    img.resize((size, size), Image.Resampling.LANCZOS).save(out_dir / name)
PY
  iconutil -c icns "$MAC_ICONSET_DIR" -o "$MAC_ICNS_PATH"
fi

# 2. 編譯 Rust 核心庫 (Release)
echo "--- 正在編譯 Rust 核心 (Release) ---"
rustup target add aarch64-apple-darwin 2>/dev/null || true
cargo build --release --manifest-path "$ROOT_DIR/core/Cargo.toml" --target aarch64-apple-darwin 2>/dev/null || true
cargo build --release --manifest-path "$ROOT_DIR/core/Cargo.toml"

# 3. 清理並準備建置目錄
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/App"
mkdir -p "$BUILD_DIR/DMG"
mkdir -p "$OUTPUT_DIR"

# 4. 建置 macOS App (Release)
echo "--- 正在編譯 macOS 應用程式 ---"
xcodebuild -project "$ROOT_DIR/macos/EchoWriteMac.xcodeproj" \
  -scheme EchoWriteMac \
  -configuration Release \
  -destination "generic/platform=macOS" \
  ARCHS="arm64" \
  EXCLUDED_ARCHS="x86_64" \
  MARKETING_VERSION="$APP_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CONFIGURATION_BUILD_DIR="$BUILD_DIR/App" \
  build CODE_SIGNING_ALLOWED=NO

APP_PATH="$BUILD_DIR/App/EchoWriteMac.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "錯誤：找不到編譯完成的 EchoWriteMac.app" >&2
  exit 1
fi

# 5. 準備 DMG 內容並執行代碼簽署與屬性清理
echo "--- 正在封裝與簽署 DMG 應用程式 ---"
cp -R "$APP_PATH" "$BUILD_DIR/DMG/EchoWrite.app"
ln -s /Applications "$BUILD_DIR/DMG/Applications"

# 清除 Quarantine 與限制屬性，避免 macOS Gatekeeper 誤判為已損毀
xattr -cr "$BUILD_DIR/DMG/EchoWrite.app"
chmod -R 755 "$BUILD_DIR/DMG/EchoWrite.app"

# 執行深度 Ad-Hoc 代碼簽署以通過 macOS 安全執行檢查
codesign --force --deep --sign - "$BUILD_DIR/DMG/EchoWrite.app"

# 6. 使用 hdiutil 產生壓縮格式的 DMG
rm -f "$DMG_OUTPUT_PATH"
hdiutil create \
  -volname "EchoWrite" \
  -srcfolder "$BUILD_DIR/DMG" \
  -ov \
  -format UDZO \
  "$DMG_OUTPUT_PATH"

echo "=== 打包完成！ ==="
echo "📦 DMG 檔案輸出路徑：$DMG_OUTPUT_PATH"
echo "檔案大小：$(du -sh "$DMG_OUTPUT_PATH" | cut -f1)"
