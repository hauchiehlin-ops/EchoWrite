#!/bin/bash
set -e

# EchoWrite iOS App Store 自動化編譯與打包腳本
# 輸出：EchoWriteCore.xcframework

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/scripts/build/ios"
IOS_DIR="$ROOT_DIR/ios"

echo "=== 開始編譯 iOS 專用 Rust 核心庫 (echowrite-core) ==="

# 1. 確保 iOS 編譯 target 已安裝
rustup target add aarch64-apple-ios x86_64-apple-ios aarch64-apple-ios-sim

# 2. 開始交叉編譯 Rust 二進位檔案 (Release 模式)
export IPHONEOS_DEPLOYMENT_TARGET=17.0
export MACOSX_DEPLOYMENT_TARGET=14.0
echo "--- 正在為 iPhone 實體機 (aarch64-apple-ios) 進行編譯 ---"
RUSTFLAGS="-C link-arg=-miphoneos-version-min=17.0" cargo build --release --manifest-path "$ROOT_DIR/core/Cargo.toml" --target aarch64-apple-ios

echo "--- 正在為 iOS 模擬器 (aarch64/x86_64) 進行編譯 ---"
RUSTFLAGS="-C link-arg=-mios-simulator-version-min=17.0" cargo build --release --manifest-path "$ROOT_DIR/core/Cargo.toml" --target x86_64-apple-ios
RUSTFLAGS="-C link-arg=-mios-simulator-version-min=17.0" cargo build --release --manifest-path "$ROOT_DIR/core/Cargo.toml" --target aarch64-apple-ios-sim

# 3. 建立輸出暫存資料夾
mkdir -p "$BUILD_DIR/ios-device"
mkdir -p "$BUILD_DIR/ios-simulator"

# 複製實體機 .a 靜態庫
cp "$ROOT_DIR/target/aarch64-apple-ios/release/libechowrite_core.a" "$BUILD_DIR/ios-device/libechowrite_core.a"

# 合併模擬器二進位檔案為 fat binary
lipo -create \
  "$ROOT_DIR/target/x86_64-apple-ios/release/libechowrite_core.a" \
  "$ROOT_DIR/target/aarch64-apple-ios-sim/release/libechowrite_core.a" \
  -output "$BUILD_DIR/ios-simulator/libechowrite_core.a"

# 4. 生成 Swift UniFFI 語言綁定界面 (Swift classes & headers)
echo "--- 正在編譯本機 macOS 庫以生成 Swift 綁定接口 ---"
cargo build --release --manifest-path "$ROOT_DIR/core/Cargo.toml"
echo "--- 正在生成 Swift 語言綁定接口 (UniFFI Bindings) ---"
cargo run --manifest-path "$ROOT_DIR/core/Cargo.toml" --features=uniffi/cli --bin uniffi-bindgen generate \
  --library "$ROOT_DIR/target/release/libechowrite_core.dylib" --language swift --out-dir "$BUILD_DIR/bindings"

# 5. 複製生成的 C header 與 modulemap 到裝置與模擬器資料夾，以便 XCode 連結
mkdir -p "$BUILD_DIR/ios-device/Headers"
mkdir -p "$BUILD_DIR/ios-simulator/Headers"
cp "$BUILD_DIR/bindings/echowrite_coreFFI.h" "$BUILD_DIR/ios-device/Headers/"
cp "$BUILD_DIR/bindings/echowrite_coreFFI.h" "$BUILD_DIR/ios-simulator/Headers/"
cp "$BUILD_DIR/bindings/echowrite_coreFFI.modulemap" "$BUILD_DIR/ios-device/Headers/module.modulemap"
cp "$BUILD_DIR/bindings/echowrite_coreFFI.modulemap" "$BUILD_DIR/ios-simulator/Headers/module.modulemap"

# 6. 利用 Apple xcodebuild 封裝成 XCFramework
echo "--- 正在打包為 Apple XCFramework 格式 ---"
rm -rf "$IOS_DIR/EchoWriteCore.xcframework"

xcodebuild -create-xcframework \
  -library "$BUILD_DIR/ios-device/libechowrite_core.a" \
  -headers "$BUILD_DIR/ios-device/Headers" \
  -library "$BUILD_DIR/ios-simulator/libechowrite_core.a" \
  -headers "$BUILD_DIR/ios-simulator/Headers" \
  -output "$IOS_DIR/EchoWriteCore.xcframework"

# 7. 將生成的 Swift 配對綁定檔案拷貝至 iOS 專案目錄下
cp "$BUILD_DIR/bindings/echowrite_core.swift" "$IOS_DIR/"

echo "=== iOS App Store 專用 EchoWriteCore.xcframework 打包完成 ==="
