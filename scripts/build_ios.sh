#!/bin/bash
set -e

# EchoWrite iOS App Store 自動化編譯與打包腳本
# 輸出：EchoWriteCore.xcframework

echo "=== 開始編譯 iOS 專用 Rust 核心庫 (echowrite-core) ==="

# 1. 確保 iOS 編譯 target 已安裝
rustup target add aarch64-apple-ios x86_64-apple-ios aarch64-apple-ios-sim

# 2. 開始交叉編譯 Rust 二進位檔案 (Release 模式)
export IPHONEOS_DEPLOYMENT_TARGET=17.0
export MACOSX_DEPLOYMENT_TARGET=14.0
echo "--- 正在為 iPhone 實體機 (aarch64-apple-ios) 進行編譯 ---"
cargo build --release --manifest-path ../core/Cargo.toml --target aarch64-apple-ios

echo "--- 正在為 iOS 模擬器 (aarch64/x86_64) 進行編譯 ---"
cargo build --release --manifest-path ../core/Cargo.toml --target x86_64-apple-ios
cargo build --release --manifest-path ../core/Cargo.toml --target aarch64-apple-ios-sim

# 3. 建立輸出暫存資料夾
mkdir -p build/ios-device
mkdir -p build/ios-simulator

# 複製實體機 .a 靜態庫
cp ../target/aarch64-apple-ios/release/libechowrite_core.a build/ios-device/libechowrite_core.a

# 合併模擬器二進位檔案為 fat binary
lipo -create \
  ../target/x86_64-apple-ios/release/libechowrite_core.a \
  ../target/aarch64-apple-ios-sim/release/libechowrite_core.a \
  -output build/ios-simulator/libechowrite_core.a

# 4. 生成 Swift UniFFI 語言綁定界面 (Swift classes & headers)
echo "--- 正在生成 Swift 語言綁定接口 (UniFFI Bindings) ---"
cargo run --features=uniffi/cli --bin uniffi-bindgen generate \
  ../core/src/lib.rs --language swift --out-dir build/bindings

# 5. 複製生成的 C header 與 modulemap 到裝置與模擬器資料夾，以便 XCode 連結
mkdir -p build/ios-device/Headers
mkdir -p build/ios-simulator/Headers
cp build/bindings/echowrite_coreFFI.h build/ios-device/Headers/
cp build/bindings/echowrite_coreFFI.h build/ios-simulator/Headers/
cp build/bindings/echowrite_coreFFI.modulemap build/ios-device/Headers/module.modulemap
cp build/bindings/echowrite_coreFFI.modulemap build/ios-simulator/Headers/module.modulemap

# 6. 利用 Apple xcodebuild 封裝成 XCFramework
echo "--- 正在打包為 Apple XCFramework 格式 ---"
rm -rf ../ios/EchoWriteCore.xcframework

xcodebuild -create-xcframework \
  -library build/ios-device/libechowrite_core.a \
  -headers build/ios-device/Headers \
  -library build/ios-simulator/libechowrite_core.a \
  -headers build/ios-simulator/Headers \
  -output ../ios/EchoWriteCore.xcframework

# 7. 將生成的 Swift 配對綁定檔案拷貝至 iOS 專案目錄下
cp build/bindings/echowrite_core.swift ../ios/

echo "=== iOS App Store 專用 EchoWriteCore.xcframework 打包完成 ==="
