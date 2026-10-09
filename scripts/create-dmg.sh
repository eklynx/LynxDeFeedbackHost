#!/bin/sh
# Packages the installed app into a notarized, drag-to-Applications disk image.
#
# Run from an install-only Run Script build phase (Product > Archive). Writes
# build/<PRODUCT_NAME>-<MARKETING_VERSION>.dmg in the project directory.
#
# Notarization uses a notarytool keychain profile. Create it once with:
#   xcrun notarytool store-credentials DeFeedbackHost-Notary \
#       --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>
# Override the profile name with NOTARY_KEYCHAIN_PROFILE. Set SKIP_NOTARIZATION=YES
# to build a signed but un-notarized image.
set -eu

NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-DeFeedbackHost-Notary}"
SKIP_NOTARIZATION="${SKIP_NOTARIZATION:-NO}"

APP_PATH="${TARGET_BUILD_DIR}/${FULL_PRODUCT_NAME}"
DMG_DIR="${PROJECT_DIR}/build"
DMG_PATH="${DMG_DIR}/${PRODUCT_NAME}-${MARKETING_VERSION}.dmg"
STAGING_DIR="${TARGET_TEMP_DIR}/dmg-staging"
STAGED_APP="${STAGING_DIR}/${FULL_PRODUCT_NAME}"
ENTITLEMENTS="${TARGET_TEMP_DIR}/dmg-entitlements.plist"

# Notarization requires a Developer ID certificate; archives sign with Apple
# Development, so find this team's Developer ID identity by its SHA-1 hash.
SIGN_IDENTITY="$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" \
    | grep "(${DEVELOPMENT_TEAM})" \
    | head -n 1 \
    | awk '{ print $2 }')"
if [ -z "${SIGN_IDENTITY}" ]; then
    echo "error: No \"Developer ID Application\" identity for team ${DEVELOPMENT_TEAM} in the keychain."
    exit 1
fi

rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}" "${DMG_DIR}"
ditto "${APP_PATH}" "${STAGED_APP}"

# Reuse the entitlements Xcode derived from the build settings (e.g. audio input),
# minus get-task-allow, which notarization rejects.
XCODE_ENTITLEMENTS="${TARGET_TEMP_DIR}/${FULL_PRODUCT_NAME}.xcent"
if [ -f "${XCODE_ENTITLEMENTS}" ]; then
    cp "${XCODE_ENTITLEMENTS}" "${ENTITLEMENTS}"
    /usr/libexec/PlistBuddy -c "Delete :com.apple.security.get-task-allow" "${ENTITLEMENTS}" 2>/dev/null || true
else
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.device.audio-input bool true" "${ENTITLEMENTS}"
fi

# Xcode signs the product only after every build phase has run, so the staged
# copy is not signed yet. Sign it for distribution: hardened runtime + timestamp.
codesign --force --options runtime --timestamp \
    --sign "${SIGN_IDENTITY}" \
    --entitlements "${ENTITLEMENTS}" \
    "${STAGED_APP}"
codesign --verify --strict --verbose=2 "${STAGED_APP}"

ln -s /Applications "${STAGING_DIR}/Applications"

rm -f "${DMG_PATH}"
hdiutil create -volname "Lynx DeFeedback Host" -srcfolder "${STAGING_DIR}" -format UDZO -ov "${DMG_PATH}"
codesign --force --timestamp --sign "${SIGN_IDENTITY}" "${DMG_PATH}"
rm -rf "${STAGING_DIR}" "${ENTITLEMENTS}"

if [ "${SKIP_NOTARIZATION}" = "YES" ]; then
    echo "warning: Skipping notarization; ${DMG_PATH} will trigger Gatekeeper on other Macs."
    exit 0
fi

xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARY_KEYCHAIN_PROFILE}" --wait
xcrun stapler staple "${DMG_PATH}"
spctl --assess --type open --context context:primary-signature --verbose=2 "${DMG_PATH}"

echo "Created ${DMG_PATH}"
