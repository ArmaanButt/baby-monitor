#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_PATH="$PROJECT_ROOT/BabyMonitor.xcodeproj"
SCHEME="BabyMonitor"
CONFIGURATION="${CONFIGURATION:-Release}"
BUILD_ROOT="${BUILD_ROOT:-$PROJECT_ROOT/.build/trollstore}"
DERIVED_DATA="$BUILD_ROOT/DerivedData"
SOURCE_PACKAGES_PATH="${SOURCE_PACKAGES_PATH:-$PROJECT_ROOT/.build/SourcePackages}"
STAGING_IPA="$BUILD_ROOT/BabyMonitor.ipa"
PACKAGE_ROOT="$BUILD_ROOT/Package"
EXTRACT_ROOT="$BUILD_ROOT/ExtractedIPA"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_ROOT/dist}"
IPA_PATH="$OUTPUT_DIR/BabyMonitor.ipa"
REPORT_PATH="$OUTPUT_DIR/BabyMonitor-validation.txt"
BUILD_LOG="$BUILD_ROOT/xcodebuild.log"

PLIST_BUDDY="/usr/libexec/PlistBuddy"
LIPO="$(xcrun --find lipo)"

rm -rf -- "$DERIVED_DATA" "$PACKAGE_ROOT" "$EXTRACT_ROOT"
mkdir -p "$DERIVED_DATA" "$PACKAGE_ROOT/Payload" "$EXTRACT_ROOT" "$OUTPUT_DIR"

echo "Building an unsigned physical-device arm64 app..."
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_PATH" \
  -disableAutomaticPackageResolution \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  build | tee "$BUILD_LOG"

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION-iphoneos/BabyMonitor.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Expected app bundle was not produced at $APP_PATH" >&2
  exit 1
fi

INFO_PLIST="$APP_PATH/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
  echo "Built app does not contain Info.plist" >&2
  exit 1
fi

EXECUTABLE_NAME="$($PLIST_BUDDY -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
EXECUTABLE_PATH="$APP_PATH/$EXECUTABLE_NAME"
if [[ ! -f "$EXECUTABLE_PATH" ]]; then
  echo "Built app does not contain its declared executable" >&2
  exit 1
fi

for privacy_key in NSCameraUsageDescription NSMicrophoneUsageDescription NSLocalNetworkUsageDescription; do
  privacy_value="$($PLIST_BUDDY -c "Print :$privacy_key" "$INFO_PLIST" 2>/dev/null || true)"
  if [[ -z "$privacy_value" ]]; then
    echo "Missing or empty Info.plist privacy key: $privacy_key" >&2
    exit 1
  fi
done

BONJOUR_SERVICE="$($PLIST_BUDDY -c 'Print :NSBonjourServices:0' "$INFO_PLIST" 2>/dev/null || true)"
if [[ "$BONJOUR_SERVICE" != "_babymonitor._tcp" ]]; then
  echo "Built Info.plist does not declare the BabyMonitor Bonjour service" >&2
  exit 1
fi

IPHONE_FAMILY="$($PLIST_BUDDY -c 'Print :UIDeviceFamily:0' "$INFO_PLIST" 2>/dev/null || true)"
IPAD_FAMILY="$($PLIST_BUDDY -c 'Print :UIDeviceFamily:1' "$INFO_PLIST" 2>/dev/null || true)"
if [[ "$IPHONE_FAMILY" != "1" || "$IPAD_FAMILY" != "2" ]]; then
  echo "Built app must target both iPhone and iPad; found UIDeviceFamily $IPHONE_FAMILY,$IPAD_FAMILY" >&2
  exit 1
fi

if [[ ! -f "$APP_PATH/Assets.car" ]] ||
   [[ ! -f "$APP_PATH/AppIcon60x60@2x.png" ]] ||
   [[ ! -f "$APP_PATH/AppIcon76x76@2x~ipad.png" ]]; then
  echo "Built app is missing compiled iPhone or iPad icon assets" >&2
  exit 1
fi

ARCHITECTURES="$($LIPO -archs "$EXECUTABLE_PATH")"
if [[ "$ARCHITECTURES" != "arm64" ]]; then
  echo "Expected exactly arm64, found: $ARCHITECTURES" >&2
  exit 1
fi

MINIMUM_OS="$($PLIST_BUDDY -c 'Print :MinimumOSVersion' "$INFO_PLIST")"
if ! awk -v actual="$MINIMUM_OS" -v maximum="15.0" 'BEGIN {
  actual_count = split(actual, actual_parts, ".")
  maximum_count = split(maximum, maximum_parts, ".")
  count = actual_count > maximum_count ? actual_count : maximum_count
  for (part_index = 1; part_index <= count; part_index++) {
    actual_part = part_index <= actual_count ? actual_parts[part_index] + 0 : 0
    maximum_part = part_index <= maximum_count ? maximum_parts[part_index] + 0 : 0
    if (actual_part < maximum_part) exit 0
    if (actual_part > maximum_part) exit 1
  }
  exit 0
}'; then
  echo "MinimumOSVersion $MINIMUM_OS is newer than iOS/iPadOS 15.0" >&2
  exit 1
fi

if [[ -e "$APP_PATH/embedded.mobileprovision" ]]; then
  echo "Unexpected Apple provisioning profile found in unsigned app" >&2
  exit 1
fi

ENTITLEMENTS_SETTING="$(xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  ARCHS=arm64 \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_PATH" \
  -disableAutomaticPackageResolution \
  -showBuildSettings | awk -F ' = ' '/^[[:space:]]*CODE_SIGN_ENTITLEMENTS = / { print $2; exit }')"

ENTITLEMENTS_STATUS="No CODE_SIGN_ENTITLEMENTS file is configured."
PROVISIONING_FLAGS="None."
if [[ -n "$ENTITLEMENTS_SETTING" ]]; then
  if [[ "$ENTITLEMENTS_SETTING" = /* ]]; then
    ENTITLEMENTS_PATH="$ENTITLEMENTS_SETTING"
  else
    ENTITLEMENTS_PATH="$PROJECT_ROOT/$ENTITLEMENTS_SETTING"
  fi

  if [[ ! -f "$ENTITLEMENTS_PATH" ]]; then
    echo "Configured entitlements file does not exist: $ENTITLEMENTS_PATH" >&2
    exit 1
  fi

  flagged_keys=()
  provisioning_keys=(
    aps-environment
    com.apple.developer.applesignin
    com.apple.developer.associated-domains
    com.apple.developer.icloud-container-identifiers
    com.apple.developer.icloud-services
    com.apple.developer.ubiquity-container-identifiers
    com.apple.developer.ubiquity-kvstore-identifier
  )
  for entitlement_key in "${provisioning_keys[@]}"; do
    if "$PLIST_BUDDY" -c "Print :$entitlement_key" "$ENTITLEMENTS_PATH" >/dev/null 2>&1; then
      flagged_keys+=("$entitlement_key")
    fi
  done

  if (( ${#flagged_keys[@]} > 0 )); then
    PROVISIONING_FLAGS="Requires Apple provisioning review: ${flagged_keys[*]}"
    echo "Warning: $PROVISIONING_FLAGS" >&2
  fi

  if ! command -v ldid >/dev/null 2>&1; then
    echo "Entitlements are configured, but ldid is unavailable. Install a current ldid or remove the unintended entitlements before packaging." >&2
    exit 1
  fi

  ldid -S"$ENTITLEMENTS_PATH" "$EXECUTABLE_PATH"
  ENTITLEMENTS_STATUS="Applied configured entitlements with ldid from $ENTITLEMENTS_SETTING."
else
  if codesign --verify "$EXECUTABLE_PATH" >/dev/null 2>&1; then
    echo "Expected an unsigned executable, but a valid code signature is present" >&2
    exit 1
  fi
fi

/usr/bin/ditto "$APP_PATH" "$PACKAGE_ROOT/Payload/BabyMonitor.app"
rm -f -- "$STAGING_IPA"
(
  cd "$PACKAGE_ROOT"
  /usr/bin/ditto -c -k --norsrc --keepParent Payload "$STAGING_IPA"
)

/usr/bin/unzip -tq "$STAGING_IPA" >/dev/null
/usr/bin/ditto -x -k "$STAGING_IPA" "$EXTRACT_ROOT"

payload_entries=()
while IFS= read -r entry; do
  payload_entries+=("$entry")
done < <(find "$EXTRACT_ROOT/Payload" -mindepth 1 -maxdepth 1 -print)

if (( ${#payload_entries[@]} != 1 )) || [[ "${payload_entries[0]}" != "$EXTRACT_ROOT/Payload/BabyMonitor.app" ]]; then
  echo "IPA must contain exactly Payload/BabyMonitor.app at its top level" >&2
  exit 1
fi

EXTRACTED_APP="$EXTRACT_ROOT/Payload/BabyMonitor.app"
EXTRACTED_EXECUTABLE="$EXTRACTED_APP/$EXECUTABLE_NAME"
EXTRACTED_ARCHITECTURES="$($LIPO -archs "$EXTRACTED_EXECUTABLE")"
if [[ "$EXTRACTED_ARCHITECTURES" != "arm64" ]]; then
  echo "Packaged executable is not exactly arm64: $EXTRACTED_ARCHITECTURES" >&2
  exit 1
fi

for privacy_key in NSCameraUsageDescription NSMicrophoneUsageDescription NSLocalNetworkUsageDescription; do
  if ! "$PLIST_BUDDY" -c "Print :$privacy_key" "$EXTRACTED_APP/Info.plist" >/dev/null 2>&1; then
    echo "Packaged Info.plist is missing $privacy_key" >&2
    exit 1
  fi
done

if [[ "$($PLIST_BUDDY -c 'Print :NSBonjourServices:0' "$EXTRACTED_APP/Info.plist" 2>/dev/null || true)" != "_babymonitor._tcp" ]]; then
  echo "Packaged Info.plist is missing the BabyMonitor Bonjour service" >&2
  exit 1
fi

if [[ "$($PLIST_BUDDY -c 'Print :UIDeviceFamily:0' "$EXTRACTED_APP/Info.plist" 2>/dev/null || true)" != "1" ]] ||
   [[ "$($PLIST_BUDDY -c 'Print :UIDeviceFamily:1' "$EXTRACTED_APP/Info.plist" 2>/dev/null || true)" != "2" ]]; then
  echo "Packaged app does not target both iPhone and iPad" >&2
  exit 1
fi

if [[ ! -f "$EXTRACTED_APP/Assets.car" ]] ||
   [[ ! -f "$EXTRACTED_APP/AppIcon60x60@2x.png" ]] ||
   [[ ! -f "$EXTRACTED_APP/AppIcon76x76@2x~ipad.png" ]]; then
  echo "Packaged app is missing compiled iPhone or iPad icon assets" >&2
  exit 1
fi

python3 "$SCRIPT_DIR/audit-unsigned-app.py" "$EXTRACTED_APP" > "$BUILD_ROOT/embedded-executable-audit.txt"

# Replace the deliverable only after the archive and all embedded binaries pass.
mv -f -- "$STAGING_IPA" "$IPA_PATH"

IPA_SHA256="$(shasum -a 256 "$IPA_PATH" | awk '{print $1}')"
IPA_SIZE="$(stat -f '%z' "$IPA_PATH")"

{
  echo "BabyMonitor TrollStore IPA validation"
  echo "IPA: $IPA_PATH"
  echo "SHA-256: $IPA_SHA256"
  echo "Size: $IPA_SIZE bytes"
  echo "Structure: Payload/BabyMonitor.app"
  echo "Executable: $EXECUTABLE_NAME"
  echo "Architectures: $EXTRACTED_ARCHITECTURES"
  echo "MinimumOSVersion: $MINIMUM_OS"
  echo "Supported device families: iPhone and iPad"
  echo "Bonjour service: _babymonitor._tcp"
  echo "Compiled app icons: iPhone and iPad present"
  echo "Apple provisioning profile: absent"
  echo "Privacy descriptions: camera, microphone, and local network present"
  echo "Entitlements: $ENTITLEMENTS_STATUS"
  echo "Provisioning-sensitive entitlements: $PROVISIONING_FLAGS"
  echo "Archive integrity: passed"
  cat "$BUILD_ROOT/embedded-executable-audit.txt"
  echo "TrollStore document compatibility: .ipa with one Payload/BabyMonitor.app bundle"
  echo "Device launch: requires manual installation verification on both jailbroken target devices"
} > "$REPORT_PATH"

echo
cat "$REPORT_PATH"
