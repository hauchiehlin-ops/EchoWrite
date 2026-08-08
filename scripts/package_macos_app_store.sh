#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVE_DIR="${ARCHIVE_DIR:-/tmp/echowrite-mac-archive}"
EXPORT_DIR="${EXPORT_DIR:-/tmp/echowrite-mac-export}"
EXPORT_OPTIONS="${EXPORT_OPTIONS:-/tmp/echowrite-mac-export-options.plist}"
ARCHIVE_PATH="$ARCHIVE_DIR/EchoWriteMac.xcarchive"
ENTITLEMENTS_PATH="$ROOT_DIR/macos/EchoWriteMac.entitlements"
INFO_PLIST="$ROOT_DIR/macos/EchoWriteMac-Info.plist"
MAC_ICON_SOURCE="$ROOT_DIR/chrome-extension/assets/echowrite-floating-icon.png"
MAC_ICONSET_DIR="$ROOT_DIR/macos/AppIcon.iconset"
MAC_ICNS_PATH="$ROOT_DIR/macos/EchoWriteMac.icns"

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: $name" >&2
    exit 1
  fi
}

require_env TEAM_ID
require_env ASC_EMAIL
require_env APP_PASSWORD

if [[ ! "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  cat >&2 <<EOF
TEAM_ID looks wrong: "$TEAM_ID"

Apple Developer Team ID is usually a 10-character uppercase alphanumeric value
such as ABCDE12345. It is not the App Store Connect provider short name
such as HAU_CHIEH.

Find it in:
  Xcode > Settings > Accounts > select your Apple ID > Team > Team ID

If altool needs your provider short name, set it separately:
  export ASC_PROVIDER="HAU_CHIEH"
EOF
  exit 1
fi

APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.echowrite.mac}"
APP_VERSION="${APP_VERSION:-2.3.0}"
BUILD_NUMBER="${BUILD_NUMBER:-17}"
MAC_ARCHS="${MAC_ARCHS:-arm64}"
EXCLUDED_MAC_ARCHS="${EXCLUDED_MAC_ARCHS:-x86_64}"
ASC_PROVIDER_ARGS=()
if [[ -n "${ASC_PROVIDER:-}" ]]; then
  ASC_PROVIDER_ARGS=(--asc-provider "$ASC_PROVIDER")
fi

cd "$ROOT_DIR"

echo "=== EchoWrite macOS App Store package/upload ==="
echo "Bundle ID: $APP_BUNDLE_ID"
echo "Version:   $APP_VERSION ($BUILD_NUMBER)"
echo "Team ID:   $TEAM_ID"
echo "Archs:     $MAC_ARCHS"
if [[ -n "${ASC_PROVIDER:-}" ]]; then
  echo "ASC Provider: $ASC_PROVIDER"
fi

echo "=== 1/8 Checking tools ==="
xcode-select -p >/dev/null
xcodebuild -version
cargo --version

echo "=== 2/8 Preparing macOS entitlements ==="
cat > "$ENTITLEMENTS_PATH" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key>
  <true/>
  <key>com.apple.security.device.audio-input</key>
  <true/>
  <key>com.apple.security.files.user-selected.read-write</key>
  <true/>
</dict>
</plist>
EOF

echo "=== 3/8 Ensuring microphone permission text ==="
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $APP_BUNDLE_ID" "$INFO_PLIST" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $APP_BUNDLE_ID" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$INFO_PLIST" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $APP_VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$INFO_PLIST" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :NSMicrophoneUsageDescription EchoWrite 需要使用麥克風將語音轉成文字。" "$INFO_PLIST" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string EchoWrite 需要使用麥克風將語音轉成文字。" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :LSApplicationCategoryType public.app-category.productivity" "$INFO_PLIST" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :LSApplicationCategoryType string public.app-category.productivity" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile EchoWriteMac" "$INFO_PLIST" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string EchoWriteMac" "$INFO_PLIST"

echo "=== 3.5/8 Generating macOS ICNS icon ==="
if [[ ! -f "$MAC_ICON_SOURCE" ]]; then
  echo "Missing icon source: $MAC_ICON_SOURCE" >&2
  exit 1
fi
rm -rf "$MAC_ICONSET_DIR"
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

echo "=== 4/8 Building Rust core ==="
rustup target add aarch64-apple-darwin
cargo build --release --manifest-path "$ROOT_DIR/core/Cargo.toml" --target aarch64-apple-darwin
cargo build --release --manifest-path "$ROOT_DIR/core/Cargo.toml"

echo "=== 5/8 Cleaning old archive/export ==="
rm -rf "$ARCHIVE_DIR" "$EXPORT_DIR"
mkdir -p "$ARCHIVE_DIR" "$EXPORT_DIR"

echo "=== 6/8 Creating Xcode archive ==="
xcodebuild archive \
  -project "$ROOT_DIR/macos/EchoWriteMac.xcodeproj" \
  -scheme EchoWriteMac \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  PRODUCT_BUNDLE_IDENTIFIER="$APP_BUNDLE_ID" \
  MARKETING_VERSION="$APP_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  ARCHS="$MAC_ARCHS" \
  EXCLUDED_ARCHS="$EXCLUDED_MAC_ARCHS" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_ENTITLEMENTS="$ENTITLEMENTS_PATH" \
  -allowProvisioningUpdates

echo "=== 7/8 Exporting Mac App Store package ==="
cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>export</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>$TEAM_ID</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates

PKG_PATH="$(find "$EXPORT_DIR" -name '*.pkg' | head -n 1)"
if [[ -z "$PKG_PATH" ]]; then
  echo "Export succeeded but no .pkg file was found in $EXPORT_DIR" >&2
  exit 1
fi

echo "=== 8/8 Validating and uploading to App Store Connect ==="
echo "Checking App Store Connect credentials..."
if ! xcrun altool --list-providers \
    -u "$ASC_EMAIL" \
    -p "$APP_PASSWORD" \
    "${ASC_PROVIDER_ARGS[@]}" >/tmp/echowrite-mac-providers.txt; then
  cat >&2 <<EOF

App Store Connect login failed before validation.

Fix these first:
  1. ASC_EMAIL must be the Apple ID email that has App Store Connect access.
  2. APP_PASSWORD must be an Apple ID app-specific password, not your normal Apple ID password.
  3. Do not include masking characters such as ** around APP_PASSWORD.
  4. If your account has multiple providers, set:
       export ASC_PROVIDER="6UJ8GS752W"

Create or manage app-specific passwords here:
  https://account.apple.com/account/manage
EOF
  exit 1
fi

if ! xcrun altool --validate-app \
    -f "$PKG_PATH" \
    -t macos \
    -u "$ASC_EMAIL" \
    -p "$APP_PASSWORD" \
    "${ASC_PROVIDER_ARGS[@]}"; then
  cat >&2 <<EOF

App Store Connect validation failed.

If the error says:
  Cannot determine the Apple ID from Bundle ID '$APP_BUNDLE_ID' and platform 'MAC_OS'
or:
  Could not determine provider public id from Bundle ID '$APP_BUNDLE_ID'

Open App Store Connect and create the macOS app record first:
  https://appstoreconnect.apple.com/apps

Use exactly this Bundle ID:
  $APP_BUNDLE_ID

Also confirm you selected the macOS platform, not iOS.
EOF
  exit 1
fi

xcrun altool --upload-app \
  -f "$PKG_PATH" \
  -t macos \
  -u "$ASC_EMAIL" \
  -p "$APP_PASSWORD" \
  "${ASC_PROVIDER_ARGS[@]}"

echo "=== Done ==="
echo "Uploaded: $PKG_PATH"
echo "Open App Store Connect: https://appstoreconnect.apple.com/apps"
