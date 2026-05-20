#!/bin/bash
set -e

# ==============================================================================
# X-Display Release Automation Script
# ==============================================================================
# This script automates:
# 1. Cleaning and building the macOS Host application
# 2. Creating a signed and zipped application bundle
# 3. Notarizing the application bundle with Apple's notary service
# 4. Generating/updating Sparkle's appcast.xml for software updates
# ==============================================================================

# Configurations
APP_NAME="X-Display"
BUNDLE_ID="com.goodbad-web.X-Display"
SCHEME="X-Display"
CONFIGURATION="Release"
BUILD_DIR="./.build/release-output"
EXPORT_PATH="${BUILD_DIR}/${APP_NAME}.app"
ZIP_PATH="${BUILD_DIR}/${APP_NAME}.zip"

# Developer Identity (Must be installed in Keychain)
DEVELOPER_ID_APPLICATION="Developer ID Application: Your Company (ABC123XYZ)"
APPLE_ID="your-apple-id@email.com"
TEAM_ID="ABC123XYZ"
NOTARY_KEYCHAIN_PROFILE="XDisplayNotaryProfile"

echo "[*] Phase 1: Building Xcode Project..."
xcodebuild clean build \
  -project "${APP_NAME}.xcodeproj" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -derivedDataPath "${BUILD_DIR}/DerivedData" \
  CONFIGURATION_BUILD_DIR="${BUILD_DIR}"

echo "[*] Phase 2: Code Signing with Developer ID..."
# Signing all nested targets first, then the main bundle
codesign --force --options runtime --deep --sign "${DEVELOPER_ID_APPLICATION}" "${EXPORT_PATH}"

echo "[*] Phase 3: Packaging..."
ditto -c -k --sequesterRsrc --keepParent "${EXPORT_PATH}" "${ZIP_PATH}"

echo "[*] Phase 4: Apple Notarization..."
echo "[!] Submitting to Notary Service..."
# Note: Requires keychain profile configured via `xcrun notarytool store-credentials`
xcrun notarytool submit "${ZIP_PATH}" \
  --keychain-profile "${NOTARY_KEYCHAIN_PROFILE}" \
  --wait

echo "[*] Phase 5: Stapling Ticket..."
xcrun stapler staple "${EXPORT_PATH}"

echo "[*] Phase 6: Regenerating ZIP with Stapled App..."
rm "${ZIP_PATH}"
ditto -c -k --sequesterRsrc --keepParent "${EXPORT_PATH}" "${ZIP_PATH}"

echo "[*] Phase 7: Generating Sparkle Appcast..."
# Check if Sparkle's generate_appcast tool exists in the Swift PM checkout
SPARKLE_BIN_PATH=$(find .build/SourcePackages/checkouts/Sparkle/bin -name generate_appcast | head -n 1)

if [ -n "${SPARKLE_BIN_PATH}" ]; then
  "${SPARKLE_BIN_PATH}" "${BUILD_DIR}"
  echo "[+] Sparkle appcast updated successfully."
else
  echo "[!] Sparkle generate_appcast utility not found in SPM checkout."
  echo "[!] Please run appcast generation manually using Sparkle binary."
fi

echo "[+] Release build, notarization, and update generation finished successfully!"
