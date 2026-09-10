#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$PROJECT_ROOT/.build/mac-release}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_ROOT/dist}"
DERIVED_DATA="$BUILD_ROOT/DerivedData"
PACKAGE_ROOT="$BUILD_ROOT/Package"
EXTRACT_ROOT="$BUILD_ROOT/Extracted"
PLIST_BUDDY="/usr/libexec/PlistBuddy"

mkdir -p "$BUILD_ROOT" "$OUTPUT_DIR"

# Catalyst pairing uses the Data Protection keychain, which requires a real
# signing identity and provisioning profile. Ad hoc signing can launch the UI
# but fails to save pairings with errSecMissingEntitlement (-34018).
# Use the project's existing signing settings. This script does not contact
# Apple to create/update signing resources or modify the iOS signing settings.
xcodebuild \
  -project "$PROJECT_ROOT/BabyMonitor.xcodeproj" \
  -scheme BabyMonitor \
  -configuration Release \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  build | tee "$BUILD_ROOT/xcodebuild.log"

APP_PATH="$DERIVED_DATA/Build/Products/Release-maccatalyst/BabyMonitor.app"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
EXECUTABLE="$APP_PATH/Contents/MacOS/BabyMonitor"
ARCHITECTURES="$(xcrun lipo -archs "$EXECUTABLE")"
[[ "$ARCHITECTURES" == "x86_64 arm64" || "$ARCHITECTURES" == "arm64 x86_64" ]]
[[ "$("$PLIST_BUDDY" -c 'Print :CFBundleIdentifier' "$INFO_PLIST")" == "com.armaanbutt.BabyMonitor" ]]
[[ "$("$PLIST_BUDDY" -c 'Print :CFBundleSupportedPlatforms:0' "$INFO_PLIST")" == "MacOSX" ]]
[[ "$("$PLIST_BUDDY" -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST")" == "12.0" ]]
[[ "$("$PLIST_BUDDY" -c 'Print :NSBonjourServices:0' "$INFO_PLIST")" == "_babymonitor._tcp" ]]
[[ -f "$APP_PATH/Contents/Resources/AppIcon.icns" ]]
for privacy_key in NSCameraUsageDescription NSMicrophoneUsageDescription NSLocalNetworkUsageDescription; do
  [[ -n "$("$PLIST_BUDDY" -c "Print :$privacy_key" "$INFO_PLIST")" ]]
done

codesign --verify --deep --strict "$APP_PATH"
codesign -d --entitlements :- "$APP_PATH" > "$BUILD_ROOT/entitlements.plist" 2> "$BUILD_ROOT/signature.txt"
APPLICATION_ID="$("$PLIST_BUDDY" -c 'Print :com.apple.application-identifier' "$BUILD_ROOT/entitlements.plist")"
ACCESS_GROUP="$("$PLIST_BUDDY" -c 'Print :keychain-access-groups:0' "$BUILD_ROOT/entitlements.plist")"
[[ "$APPLICATION_ID" == *".com.armaanbutt.BabyMonitor" ]]
[[ "$ACCESS_GROUP" == "$APPLICATION_ID" ]]
[[ -f "$APP_PATH/Contents/embedded.provisionprofile" ]]
security cms -D -i "$APP_PATH/Contents/embedded.provisionprofile" > "$BUILD_ROOT/profile.plist"
PROFILE_EXPIRATION="$(plutil -extract ExpirationDate raw -o - "$BUILD_ROOT/profile.plist")"
PROFILE_EXPIRATION_SECONDS="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$PROFILE_EXPIRATION" '+%s')"
[[ "$PROFILE_EXPIRATION_SECONDS" -gt "$(date '+%s')" ]]

rm -rf -- "$PACKAGE_ROOT" "$EXTRACT_ROOT"
mkdir -p "$PACKAGE_ROOT" "$EXTRACT_ROOT"
ditto "$APP_PATH" "$PACKAGE_ROOT/BabyMonitor.app"
ZIP_PATH="$BUILD_ROOT/BabyMonitor-Mac.zip"
ditto -c -k --sequesterRsrc --keepParent "$PACKAGE_ROOT/BabyMonitor.app" "$ZIP_PATH"
unzip -tq "$ZIP_PATH" >/dev/null
ditto -x -k "$ZIP_PATH" "$EXTRACT_ROOT"
codesign --verify --deep --strict "$EXTRACT_ROOT/BabyMonitor.app"
cmp "$EXECUTABLE" "$EXTRACT_ROOT/BabyMonitor.app/Contents/MacOS/BabyMonitor"

ZIP_SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
ZIP_SIZE="$(stat -f '%z' "$ZIP_PATH")"
{
  echo "BabyMonitor Mac Catalyst validation"
  echo "Archive: BabyMonitor-Mac.zip"
  echo "SHA-256: $ZIP_SHA256"
  echo "Size: $ZIP_SIZE bytes"
  echo "Architectures: $ARCHITECTURES"
  echo "Minimum macOS: 12.0"
  echo "Bundle identifier: com.armaanbutt.BabyMonitor"
  echo "Default role: Viewer"
  echo "Keychain access: application identifier and access group match"
  echo "Code signature and extracted archive: verified"
  echo "Distribution: development build for Macs permitted by its provisioning profile"
  echo "Provisioning profile expires (UTC): $PROFILE_EXPIRATION"
  echo "Notarization and public distribution: not implemented"
  echo "Physical Monitor-to-Mac discovery, pairing, video/audio and reconnect: manual test required"
} > "$BUILD_ROOT/BabyMonitor-Mac-validation.txt"

# Publish only after the complete archive passes validation.
cp "$ZIP_PATH" "$OUTPUT_DIR/BabyMonitor-Mac.zip.new"
mv "$OUTPUT_DIR/BabyMonitor-Mac.zip.new" "$OUTPUT_DIR/BabyMonitor-Mac.zip"
cp "$BUILD_ROOT/BabyMonitor-Mac-validation.txt" "$OUTPUT_DIR/BabyMonitor-Mac-validation.txt"
cat "$OUTPUT_DIR/BabyMonitor-Mac-validation.txt"
