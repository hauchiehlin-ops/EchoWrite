#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_DIR="$ROOT_DIR/android"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/scripts/build/android-release}"
KEYSTORE_DIR="${KEYSTORE_DIR:-$ROOT_DIR/android/keystore}"
KEYSTORE_ENV_FILE="${KEYSTORE_ENV_FILE:-$KEYSTORE_DIR/echowrite-upload.env}"
KEYSTORE_PATH="${ANDROID_KEYSTORE_PATH:-$KEYSTORE_DIR/echowrite-upload.jks}"

if [[ -f "$KEYSTORE_ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$KEYSTORE_ENV_FILE"
fi

ANDROID_APPLICATION_ID="${ANDROID_APPLICATION_ID:-com.echowrite.app}"
ANDROID_VERSION_NAME="${ANDROID_VERSION_NAME:-1.0.0}"
ANDROID_VERSION_CODE="${ANDROID_VERSION_CODE:-2}"
ANDROID_KEY_ALIAS="${ANDROID_KEY_ALIAS:-echowrite_upload}"
KEYSTORE_PATH="${ANDROID_KEYSTORE_PATH:-$KEYSTORE_PATH}"

GRADLE_CMD=""
if [[ -x "$ANDROID_DIR/gradlew" ]]; then
  GRADLE_CMD="$ANDROID_DIR/gradlew"
elif command -v gradle >/dev/null 2>&1; then
  GRADLE_CMD="$(command -v gradle)"
else
  cat >&2 <<EOF
Gradle was not found.

Install it with:
  brew install gradle

Then rerun:
  ./scripts/package_android_play.sh
EOF
  exit 1
fi

if ! command -v keytool >/dev/null 2>&1; then
  cat >&2 <<EOF
keytool was not found. Install JDK 17 first:
  brew install openjdk@17
EOF
  exit 1
fi

detect_java_home() {
  local candidate

  if [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/java" ]]; then
    printf '%s\n' "$JAVA_HOME"
    return 0
  fi

  for candidate in \
    "/Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home" \
    "/Library/Java/JavaVirtualMachines/openjdk-17.jdk/Contents/Home" \
    "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home" \
    "/usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
  do
    if [[ -x "$candidate/bin/java" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  if command -v /usr/libexec/java_home >/dev/null 2>&1; then
    candidate="$(/usr/libexec/java_home -v 17 2>/dev/null || true)"
    if [[ -n "$candidate" && -x "$candidate/bin/java" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  if command -v java >/dev/null 2>&1; then
    candidate="$(command -v java)"
    candidate="$(cd "$(dirname "$candidate")/.." && pwd -P)"
    if [[ -x "$candidate/bin/java" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  return 1
}

if ! command -v cargo-ndk >/dev/null 2>&1; then
  cat >&2 <<EOF
cargo-ndk was not found.

Install it with:
  cargo install cargo-ndk
EOF
  exit 1
fi

mkdir -p "$KEYSTORE_DIR" "$OUTPUT_DIR"

if [[ ! -f "$KEYSTORE_PATH" ]]; then
  if [[ -z "${ANDROID_KEYSTORE_PASSWORD:-}" ]]; then
    ANDROID_KEYSTORE_PASSWORD="$(openssl rand -base64 24 | tr -d '\n')"
  fi
  if [[ -z "${ANDROID_KEY_PASSWORD:-}" ]]; then
    ANDROID_KEY_PASSWORD="$ANDROID_KEYSTORE_PASSWORD"
  fi

  echo "=== Creating Android upload keystore ==="
  keytool -genkeypair \
    -v \
    -keystore "$KEYSTORE_PATH" \
    -storepass "$ANDROID_KEYSTORE_PASSWORD" \
    -keypass "$ANDROID_KEY_PASSWORD" \
    -alias "$ANDROID_KEY_ALIAS" \
    -keyalg RSA \
    -keysize 4096 \
    -validity 10000 \
    -dname "CN=EchoWrite, OU=EchoWrite, O=EchoWrite, L=Taipei, ST=Taiwan, C=TW"

  cat > "$KEYSTORE_ENV_FILE" <<EOF
export ANDROID_KEYSTORE_PATH="$KEYSTORE_PATH"
export ANDROID_KEYSTORE_PASSWORD="$ANDROID_KEYSTORE_PASSWORD"
export ANDROID_KEY_ALIAS="$ANDROID_KEY_ALIAS"
export ANDROID_KEY_PASSWORD="$ANDROID_KEY_PASSWORD"
EOF
  chmod 600 "$KEYSTORE_ENV_FILE"
elif [[ -z "${ANDROID_KEYSTORE_PASSWORD:-}" || -z "${ANDROID_KEY_PASSWORD:-}" ]]; then
  cat >&2 <<EOF
Existing keystore found, but signing passwords are missing.

Either set:
  export ANDROID_KEYSTORE_PASSWORD="..."
  export ANDROID_KEY_PASSWORD="..."

Or restore the local env file:
  $KEYSTORE_ENV_FILE
EOF
  exit 1
fi

export ANDROID_KEYSTORE_PATH="$KEYSTORE_PATH"
export ANDROID_KEYSTORE_PASSWORD
export ANDROID_KEY_ALIAS
export ANDROID_KEY_PASSWORD
export ANDROID_APPLICATION_ID
export ANDROID_VERSION_NAME
export ANDROID_VERSION_CODE
if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then
  export ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT:-$ANDROID_NDK_HOME}"
fi
if [[ -n "${ANDROID_NDK_ROOT:-}" ]]; then
  export ANDROID_NDK="$ANDROID_NDK_ROOT"
  export NDK_ROOT="$ANDROID_NDK_ROOT"
  export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"
fi

JAVA_HOME_RESOLVED="$(detect_java_home || true)"
if [[ -z "$JAVA_HOME_RESOLVED" ]]; then
  cat >&2 <<EOF
No valid JDK 17 was found.

Install one of:
  brew install openjdk@17
  brew install temurin@17

Or set:
  export JAVA_HOME="/path/to/your/jdk"
EOF
  exit 1
fi

export JAVA_HOME="$JAVA_HOME_RESOLVED"
export PATH="$JAVA_HOME/bin:$PATH"

echo "=== EchoWrite Android package ==="
echo "Application ID: $ANDROID_APPLICATION_ID"
echo "Version:        $ANDROID_VERSION_NAME ($ANDROID_VERSION_CODE)"
echo "Keystore:       $ANDROID_KEYSTORE_PATH"
echo "Java Home:      $JAVA_HOME"

echo "=== 1/4 Building Rust Android libraries ==="
bash "$ROOT_DIR/scripts/build_android.sh"

echo "=== 2/4 Building signed Google Play AAB ==="
(cd "$ANDROID_DIR" && "$GRADLE_CMD" clean bundleRelease)

echo "=== 3/4 Building signed sideload APK for testers ==="
(cd "$ANDROID_DIR" && "$GRADLE_CMD" assembleRelease)

AAB_PATH="$(find "$ANDROID_DIR/app/build/outputs/bundle/release" -name '*.aab' | head -n 1)"
APK_PATH="$(find "$ANDROID_DIR/app/build/outputs/apk/release" -name '*.apk' | head -n 1)"

if [[ -z "$AAB_PATH" ]]; then
  echo "Build succeeded but no .aab was found." >&2
  exit 1
fi
if [[ -z "$APK_PATH" ]]; then
  echo "Build succeeded but no release .apk was found." >&2
  exit 1
fi

echo "=== 4/4 Copying artifacts ==="
cp "$AAB_PATH" "$OUTPUT_DIR/EchoWrite-$ANDROID_VERSION_NAME-$ANDROID_VERSION_CODE-play.aab"
cp "$APK_PATH" "$OUTPUT_DIR/EchoWrite-$ANDROID_VERSION_NAME-$ANDROID_VERSION_CODE-sideload.apk"

cat > "$OUTPUT_DIR/KEEP_THIS_KEYSTORE_INFO.txt" <<EOF
EchoWrite Android upload key information

Keystore path:
  $ANDROID_KEYSTORE_PATH

Key alias:
  $ANDROID_KEY_ALIAS

Local signing env file:
  $KEYSTORE_ENV_FILE

Important:
  Keep this keystore and password safe. You need the same upload key for future Google Play updates.
  Do not commit the keystore or passwords to git.
EOF

echo "=== Done ==="
echo "Google Play AAB: $OUTPUT_DIR/EchoWrite-$ANDROID_VERSION_NAME-$ANDROID_VERSION_CODE-play.aab"
echo "Tester APK:      $OUTPUT_DIR/EchoWrite-$ANDROID_VERSION_NAME-$ANDROID_VERSION_CODE-sideload.apk"
