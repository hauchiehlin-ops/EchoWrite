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

detect_android_ndk_root() {
  local sdk_root candidate ndk_dir ndk_root

  for candidate in "${ANDROID_NDK_ROOT:-}" "${ANDROID_NDK:-}" "${NDK_ROOT:-}" "${ANDROID_NDK_HOME:-}"; do
    if [[ -n "$candidate" && -d "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  for sdk_root in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" "$HOME/Library/Android/sdk"; do
    ndk_root=""

    if [[ -n "$sdk_root" && -d "$sdk_root/ndk" ]]; then
      while IFS= read -r ndk_dir; do
        [[ -n "$ndk_dir" && -d "$ndk_dir" ]] && ndk_root="$ndk_dir"
      done < <(find "$sdk_root/ndk" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V)
    fi

    if [[ -n "$ndk_root" ]]; then
      printf '%s\n' "$ndk_root"
      return 0
    fi

    if [[ -n "$sdk_root" && -d "$sdk_root/ndk-bundle" ]]; then
      printf '%s\n' "$sdk_root/ndk-bundle"
      return 0
    fi
  done

  return 1
}

detect_android_ndk_prebuilt_tag() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"

  case "$os-$arch" in
    darwin-arm64|darwin-aarch64)
      printf '%s\n' "darwin-arm64"
      ;;
    darwin-x86_64|darwin-amd64)
      printf '%s\n' "darwin-x86_64"
      ;;
    linux-x86_64|linux-amd64)
      printf '%s\n' "linux-x86_64"
      ;;
    linux-arm64|linux-aarch64)
      printf '%s\n' "linux-arm64"
      ;;
    *)
      printf '%s\n' "$os-$arch"
      ;;
  esac
}

detect_android_ndk_llvm_ar() {
  local candidate_dir candidate_tag

  candidate_tag="$(detect_android_ndk_prebuilt_tag)"
  for candidate_dir in \
    "$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/$candidate_tag" \
    "$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/darwin-arm64" \
    "$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/darwin-x86_64" \
    "$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64" \
    "$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-arm64"
  do
    if [[ -x "$candidate_dir/bin/llvm-ar" ]]; then
      printf '%s\n' "$candidate_dir/bin/llvm-ar"
      return 0
    fi
  done

  for candidate_dir in "$ANDROID_NDK_ROOT"/toolchains/llvm/prebuilt/*; do
    if [[ -x "$candidate_dir/bin/llvm-ar" ]]; then
      printf '%s\n' "$candidate_dir/bin/llvm-ar"
      return 0
    fi
  done

  return 1
}

if [[ -z "${ANDROID_NDK_ROOT:-}" || ! -d "${ANDROID_NDK_ROOT:-}" ]]; then
  export ANDROID_NDK_ROOT="$(detect_android_ndk_root)"
fi

if [[ -z "${ANDROID_NDK_ROOT:-}" || ! -d "$ANDROID_NDK_ROOT" ]]; then
  local_sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
  cat >&2 <<EOF
Android NDK not found.

Install it with:
  sdkmanager --sdk_root="$local_sdk_root" "ndk;26.3.11579264"

Or set:
  export ANDROID_NDK_ROOT="$local_sdk_root/ndk/<installed-version>"

Detected SDK roots:
  ANDROID_SDK_ROOT=${ANDROID_SDK_ROOT:-<unset>}
  ANDROID_HOME=${ANDROID_HOME:-<unset>}
EOF
  exit 1
fi

export ANDROID_NDK="$ANDROID_NDK_ROOT"
export NDK_ROOT="$ANDROID_NDK_ROOT"
export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"
echo "Using Android NDK: $ANDROID_NDK_ROOT"

BLAS_SHIM_DIR="$ROOT_DIR/scripts/build/android-native-shims"
mkdir -p "$BLAS_SHIM_DIR"
LLVM_AR="$(detect_android_ndk_llvm_ar || true)"

if [[ ! -x "$LLVM_AR" ]]; then
  cat >&2 <<EOF
Android NDK llvm-ar not found.

Expected:
  $ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/<host>/bin/llvm-ar

Check that the selected NDK matches this host or set ANDROID_NDK_ROOT explicitly.
EOF
  exit 1
fi

"$LLVM_AR" rcs "$BLAS_SHIM_DIR/libggml-blas.a"

ANDROID_MADV_FLAGS="-Dposix_madvise=madvise -DPOSIX_MADV_WILLNEED=MADV_WILLNEED -DPOSIX_MADV_RANDOM=MADV_RANDOM"
export CFLAGS="${CFLAGS:-} $ANDROID_MADV_FLAGS"
export CXXFLAGS="${CXXFLAGS:-} $ANDROID_MADV_FLAGS"
export CMAKE_C_FLAGS="${CMAKE_C_FLAGS:-} $ANDROID_MADV_FLAGS"
export CMAKE_CXX_FLAGS="${CMAKE_CXX_FLAGS:-} $ANDROID_MADV_FLAGS"
export RUSTFLAGS="${RUSTFLAGS:-} -L native=$BLAS_SHIM_DIR"

# 1. 確保 Android NDK 交叉編譯 target 已安裝
rustup target add aarch64-linux-android x86_64-linux-android

# 2. 開始為 Android 四大架構編譯
echo "--- 正在編譯 aarch64-linux-android (主流 64位元 手機) ---"
cargo ndk -t arm64-v8a -o "$ANDROID_DIR/app/src/main/jniLibs" build --release --manifest-path "$ROOT_DIR/core/Cargo.toml"

echo "--- 正在編譯 x86_64-linux-android (64位元 模擬器) ---"
cargo ndk -t x86_64 -o "$ANDROID_DIR/app/src/main/jniLibs" build --release --manifest-path "$ROOT_DIR/core/Cargo.toml"

# 3. 確保 C++ 依賴庫 libc++_shared.so 完整包含在 jniLibs 中
echo "--- 正在同步 libc++_shared.so 至 jniLibs ---"
for abi_pair in "arm64-v8a:aarch64-linux-android" "x86_64:x86_64-linux-android"; do
  abi="${abi_pair%%:*}"
  triple="${abi_pair##*:}"
  libcxx_src="$(find "$ANDROID_NDK_ROOT" -path "*$triple/libc++_shared.so" 2>/dev/null | head -n 1)"
  if [[ -n "$libcxx_src" && -f "$libcxx_src" ]]; then
    mkdir -p "$ANDROID_DIR/app/src/main/jniLibs/$abi"
    cp -f "$libcxx_src" "$ANDROID_DIR/app/src/main/jniLibs/$abi/"
    echo "  -> Copied libc++_shared.so to $abi"
  fi
done

echo "=== Android Google Play 專用 .so 與 Kotlin/Manifest 骨架準備完成 ==="
