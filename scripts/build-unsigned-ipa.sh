#!/usr/bin/env bash
# Generate the Xcode project, build an unsigned iOS .app, and zip it as an IPA
# (Payload/LidarScanner.app) that AltStore can re-sign.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is not installed. On a Mac: brew install xcodegen" >&2
  exit 1
fi

echo "Using $(xcodebuild -version | tr '\n' ' ')"
xcodegen generate --spec project.yml

DERIVED="$ROOT/build/DerivedData"
rm -rf "$DERIVED"

xcodebuild \
  -project "$ROOT/LidarScanner.xcodeproj" \
  -scheme LidarScanner \
  -configuration Release \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  ONLY_ACTIVE_ARCH=NO \
  DEBUG_INFORMATION_FORMAT=dwarf \
  build

APP_PATH="$(find "$DERIVED/Build/Products" -type d -name "LidarScanner.app" | head -n 1)"
if [[ -z "${APP_PATH}" || ! -d "${APP_PATH}" ]]; then
  echo "Could not find LidarScanner.app under ${DERIVED}" >&2
  exit 1
fi
echo "Built ${APP_PATH}"

STAGE="$ROOT/build/ipa-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/Payload" "$ROOT/dist"
cp -R "$APP_PATH" "$STAGE/Payload/LidarScanner.app"
rm -rf "$STAGE/Payload/LidarScanner.app/_CodeSignature"
rm -f "$STAGE/Payload/LidarScanner.app/embedded.mobileprovision"

# Entitlements are intentionally absent so a free Apple ID can re-sign the app.
if [[ -f "$STAGE/Payload/LidarScanner.app/LidarScanner.entitlements" ]]; then
  echo "Unexpected entitlements file in the app bundle" >&2
  exit 1
fi

(
  cd "$STAGE"
  zip -r -y "$ROOT/dist/LidarScanner-unsigned.ipa" Payload
)

INFO="$(mktemp)"
unzip -p "$ROOT/dist/LidarScanner-unsigned.ipa" Payload/LidarScanner.app/Info.plist > "$INFO"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$INFO")"
CAMERA="$(plutil -extract NSCameraUsageDescription raw "$INFO")"
echo "Bundle ID: ${BUNDLE_ID}"
echo "Camera usage: ${CAMERA}"
if [[ "${BUNDLE_ID}" != "com.example.lidarscanner" ]]; then
  echo "Unexpected bundle identifier: ${BUNDLE_ID}" >&2
  exit 1
fi
if [[ -z "${CAMERA}" ]]; then
  echo "Missing NSCameraUsageDescription" >&2
  exit 1
fi

# The archive root must be Payload/, which is what AltStore expects.
if ! unzip -l "$ROOT/dist/LidarScanner-unsigned.ipa" | grep -q "Payload/LidarScanner.app/Info.plist"; then
  echo "IPA layout is missing Payload/LidarScanner.app/Info.plist" >&2
  exit 1
fi

echo "Wrote $ROOT/dist/LidarScanner-unsigned.ipa"
