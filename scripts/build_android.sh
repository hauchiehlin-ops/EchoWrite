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

if [[ -z "${ANDROID_NDK_ROOT:-}" && -z "${ANDROID_NDK:-}" && -z "${NDK_ROOT:-}" ]]; then
  if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then
    export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
  elif [[ -n "${ANDROID_HOME:-}" && -d "$ANDROID_HOME/ndk/26.3.11579264" ]]; then
    export ANDROID_NDK_ROOT="$ANDROID_HOME/ndk/26.3.11579264"
  elif [[ -n "${ANDROID_SDK_ROOT:-}" && -d "$ANDROID_SDK_ROOT/ndk/26.3.11579264" ]]; then
    export ANDROID_NDK_ROOT="$ANDROID_SDK_ROOT/ndk/26.3.11579264"
  elif [[ -d "$HOME/Library/Android/sdk/ndk/26.3.11579264" ]]; then
    export ANDROID_NDK_ROOT="$HOME/Library/Android/sdk/ndk/26.3.11579264"
  elif [[ -n "${ANDROID_HOME:-}" && -d "$ANDROID_HOME/ndk" ]]; then
    export ANDROID_NDK_ROOT="$(find "$ANDROID_HOME/ndk" -mindepth 1 -maxdepth 1 -type d | sort -V | head -n 1)"
  elif [[ -n "${ANDROID_SDK_ROOT:-}" && -d "$ANDROID_SDK_ROOT/ndk" ]]; then
    export ANDROID_NDK_ROOT="$(find "$ANDROID_SDK_ROOT/ndk" -mindepth 1 -maxdepth 1 -type d | sort -V | head -n 1)"
  elif [[ -d "$HOME/Library/Android/sdk/ndk" ]]; then
    export ANDROID_NDK_ROOT="$(find "$HOME/Library/Android/sdk/ndk" -mindepth 1 -maxdepth 1 -type d | sort -V | head -n 1)"
  fi
fi

if [[ -z "${ANDROID_NDK_ROOT:-}" || ! -d "$ANDROID_NDK_ROOT" ]]; then
  cat >&2 <<EOF
Android NDK not found.

Install it with:
  sdkmanager --sdk_root="\$HOME/Library/Android/sdk" "ndk;26.3.11579264"

Or set:
  export ANDROID_NDK_ROOT="\$HOME/Library/Android/sdk/ndk/26.3.11579264"
EOF
  exit 1
fi

export ANDROID_NDK="$ANDROID_NDK_ROOT"
export NDK_ROOT="$ANDROID_NDK_ROOT"
export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"
echo "Using Android NDK: $ANDROID_NDK_ROOT"

BLAS_SHIM_DIR="$ROOT_DIR/scripts/build/android-native-shims"
mkdir -p "$BLAS_SHIM_DIR"
"$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-ar" rcs "$BLAS_SHIM_DIR/libggml-blas.a"

ANDROID_MADV_FLAGS="-Dposix_madvise=madvise -DPOSIX_MADV_WILLNEED=MADV_WILLNEED -DPOSIX_MADV_RANDOM=MADV_RANDOM"
export CFLAGS="${CFLAGS:-} $ANDROID_MADV_FLAGS"
export CXXFLAGS="${CXXFLAGS:-} $ANDROID_MADV_FLAGS"
export CMAKE_C_FLAGS="${CMAKE_C_FLAGS:-} $ANDROID_MADV_FLAGS"
export CMAKE_CXX_FLAGS="${CMAKE_CXX_FLAGS:-} $ANDROID_MADV_FLAGS"
export RUSTFLAGS="${RUSTFLAGS:-} -L native=$BLAS_SHIM_DIR"

# 1. 確保 Android NDK 交叉編譯 target 已安裝
rustup target add aarch64-linux-android x86_64-linux-android

rm -rf \
  "$ROOT_DIR/target/aarch64-linux-android/release/build/llama-cpp-sys-2-"* \
  "$ROOT_DIR/target/x86_64-linux-android/release/build/llama-cpp-sys-2-"*

# 2. 開始為 Android 四大架構編譯
echo "--- 正在編譯 aarch64-linux-android (主流 64位元 手機) ---"
cargo ndk -t arm64-v8a -o "$ANDROID_DIR/app/src/main/jniLibs" build --release --manifest-path "$ROOT_DIR/core/Cargo.toml"

echo "--- 正在編譯 x86_64-linux-android (64位元 模擬器) ---"
cargo ndk -t x86_64 -o "$ANDROID_DIR/app/src/main/jniLibs" build --release --manifest-path "$ROOT_DIR/core/Cargo.toml"

echo "=== Android Google Play 專用 .so 與 Kotlin/Manifest 骨架準備完成 ==="
