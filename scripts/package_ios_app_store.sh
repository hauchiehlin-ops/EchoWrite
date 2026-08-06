#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IOS_DIR="$ROOT_DIR/ios"
ARCHIVE_DIR="${ARCHIVE_DIR:-/tmp/echowrite-ios-archive}"
EXPORT_DIR="${EXPORT_DIR:-/tmp/echowrite-ios-export}"
EXPORT_OPTIONS="${EXPORT_OPTIONS:-/tmp/echowrite-ios-export-options.plist}"
ARCHIVE_PATH="$ARCHIVE_DIR/EchoWriteApp.xcarchive"
KEYBOARD_INFO_PLIST="$IOS_DIR/EchoWriteKeyboard-Info.plist"
APP_ENTITLEMENTS="$IOS_DIR/App/EchoWriteApp.entitlements"
KEYBOARD_ENTITLEMENTS="$IOS_DIR/EchoWriteKeyboard.entitlements"

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
such as ABCDE12345.

Find it in:
  Xcode > Settings > Accounts > select your Apple ID > Team > Team ID
EOF
  exit 1
fi

APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.echowrite.app}"
KEYBOARD_BUNDLE_ID="${KEYBOARD_BUNDLE_ID:-$APP_BUNDLE_ID.keyboard}"
APP_GROUP_ID="${APP_GROUP_ID:-group.com.echowrite.app}"
APP_VERSION="${APP_VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-17.0}"
ASC_PROVIDER_ARGS=()
if [[ -n "${ASC_PROVIDER:-}" ]]; then
  ASC_PROVIDER_ARGS=(--provider-public-id "$ASC_PROVIDER")
fi

cd "$ROOT_DIR"

echo "=== EchoWrite iOS App Store package/upload ==="
echo "App Bundle ID:      $APP_BUNDLE_ID"
echo "Keyboard Bundle ID: $KEYBOARD_BUNDLE_ID"
echo "App Group ID:       $APP_GROUP_ID"
echo "Version:            $APP_VERSION ($BUILD_NUMBER)"
echo "Team ID:            $TEAM_ID"

echo "=== 1/9 Checking tools ==="
xcode-select -p >/dev/null
xcodebuild -version
xcodegen --version
cargo --version

echo "=== 2/9 Building Rust core and iOS XCFramework ==="
IPHONEOS_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" bash "$ROOT_DIR/scripts/build_ios.sh"

echo "=== 3/9 Generating iOS Xcode project ==="
(cd "$IOS_DIR" && xcodegen generate)

echo "=== 4/9 Preparing version/build metadata ==="
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$KEYBOARD_INFO_PLIST" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $APP_VERSION" "$KEYBOARD_INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$KEYBOARD_INFO_PLIST" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$KEYBOARD_INFO_PLIST"

for entitlements in "$APP_ENTITLEMENTS" "$KEYBOARD_ENTITLEMENTS"; do
  /usr/libexec/PlistBuddy -c "Delete :com.apple.security.application-groups" "$entitlements" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups array" "$entitlements"
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups:0 string $APP_GROUP_ID" "$entitlements"
done

echo "=== 5/9 Cleaning old archive/export ==="
rm -rf "$ARCHIVE_DIR" "$EXPORT_DIR"
mkdir -p "$ARCHIVE_DIR" "$EXPORT_DIR"

echo "=== 6/9 Creating Xcode archive ==="
xcodebuild archive \
  -project "$IOS_DIR/EchoWrite.xcodeproj" \
  -scheme EchoWriteApp \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  ECHOWRITE_IOS_APP_BUNDLE_ID="$APP_BUNDLE_ID" \
  ECHOWRITE_IOS_KEYBOARD_BUNDLE_ID="$KEYBOARD_BUNDLE_ID" \
  MARKETING_VERSION="$APP_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  IPHONEOS_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
  CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates

echo "=== 7/9 Exporting App Store Connect IPA ==="
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

IPA_PATH="$(find "$EXPORT_DIR" -name '*.ipa' | head -n 1)"
if [[ -z "$IPA_PATH" ]]; then
  echo "Export succeeded but no .ipa file was found in $EXPORT_DIR" >&2
  exit 1
fi

echo "=== 8/9 Validating IPA with App Store Connect ==="
if ! xcrun altool --validate-app \
    -f "$IPA_PATH" \
    -t ios \
    -u "$ASC_EMAIL" \
    -p "$APP_PASSWORD" \
    "${ASC_PROVIDER_ARGS[@]}"; then
  cat >&2 <<EOF

App Store Connect validation failed.

Check these first:
  1. App Store Connect has an iOS app record for bundle ID "$APP_BUNDLE_ID".
  2. Developer portal has explicit App IDs for:
       $APP_BUNDLE_ID
       $KEYBOARD_BUNDLE_ID
  3. Both App IDs have App Groups enabled and include:
       $APP_GROUP_ID
  4. Your Apple ID app-specific password is correct.
EOF
  exit 1
fi

echo "=== 9/9 Uploading IPA to App Store Connect ==="
xcrun altool --upload-app \
  -f "$IPA_PATH" \
  -t ios \
  -u "$ASC_EMAIL" \
  -p "$APP_PASSWORD" \
  "${ASC_PROVIDER_ARGS[@]}"

echo "=== Done ==="
echo "Uploaded: $IPA_PATH"
echo "Open App Store Connect: https://appstoreconnect.apple.com/apps"
