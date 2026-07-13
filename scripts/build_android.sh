#!/bin/bash
set -e

# EchoWrite Android Google Play 自動化編譯與打包腳本
# 輸出：各架構的 libechowrite_core.so 與 Kotlin 類別檔案

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_DIR="$ROOT_DIR/android"

echo "=== 開始編譯 Android 專用 Rust 核心庫 (echowrite-core) ==="

if ! command -v cargo-ndk >/dev/null 2>&1; then
  echo "Android build skipped: cargo-ndk is not installed on this host."
  exit 1
fi

# 1. 確保 Android NDK 交叉編譯 target 已安裝
rustup target add aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android

# 2. 開始為 Android 四大架構編譯
echo "--- 正在編譯 aarch64-linux-android (主流 64位元 手機) ---"
cargo ndk -t arm64-v8a -o "$ANDROID_DIR/app/src/main/jniLibs" build --release --manifest-path "$ROOT_DIR/core/Cargo.toml"

echo "--- 正在編譯 armv7-linux-androideabi (舊型 32位元 手機) ---"
cargo ndk -t armeabi-v7a -o "$ANDROID_DIR/app/src/main/jniLibs" build --release --manifest-path "$ROOT_DIR/core/Cargo.toml"

echo "--- 正在編譯 x86_64-linux-android (64位元 模擬器) ---"
cargo ndk -t x86_64 -o "$ANDROID_DIR/app/src/main/jniLibs" build --release --manifest-path "$ROOT_DIR/core/Cargo.toml"

echo "--- 正在編譯 i686-linux-android (32位元 模擬器) ---"
cargo ndk -t x86 -o "$ANDROID_DIR/app/src/main/jniLibs" build --release --manifest-path "$ROOT_DIR/core/Cargo.toml"

echo "=== Android Google Play 專用 .so 與 Kotlin/Manifest 骨架準備完成 ==="
