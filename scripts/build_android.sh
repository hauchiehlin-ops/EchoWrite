#!/bin/bash
set -e

# EchoWrite Android Google Play 自動化編譯與打包腳本
# 輸出：各架構的 libechowrite_core.so 與 Kotlin 類別檔案

echo "=== 開始編譯 Android 專用 Rust 核心庫 (echowrite-core) ==="

# 1. 確保 Android NDK 交叉編譯 target 已安裝
rustup target add aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android

# 2. 開始為 Android 四大架構編譯
echo "--- 正在編譯 aarch64-linux-android (主流 64位元 手機) ---"
cargo ndk -t arm64-v8a -o ../android/src/main/jniLibs build --release --manifest-path ../core/Cargo.toml

echo "--- 正在編譯 armv7-linux-androideabi (舊型 32位元 手機) ---"
cargo ndk -t armeabi-v7a -o ../android/src/main/jniLibs build --release --manifest-path ../core/Cargo.toml

echo "--- 正在編譯 x86_64-linux-android (64位元 模擬器) ---"
cargo ndk -t x86_64 -o ../android/src/main/jniLibs build --release --manifest-path ../core/Cargo.toml

echo "--- 正在編譯 i686-linux-android (32位元 模擬器) ---"
cargo ndk -t x86 -o ../android/src/main/jniLibs build --release --manifest-path ../core/Cargo.toml

# 3. 生成 Kotlin UniFFI 語言對接接口
echo "--- 正在生成 Kotlin 語言綁定 (UniFFI Bindings) ---"
mkdir -p build/android-bindings
cargo run --features=uniffi/cli --bin uniffi-bindgen generate \
  ../core/src/lib.rs --language kotlin --out-dir build/android-bindings

# 4. 將 Kotlin 介面複製到 Android 專案源碼目錄下
mkdir -p ../android/src/main/java/com/echowrite/app/
cp build/android-bindings/echowrite_core.kt ../android/src/main/java/com/echowrite/app/

echo "=== Android Google Play 專用 .so 靜態/動態庫與 Kotlin 綁定打包完成 ==="
