#!/bin/sh
# Packages the installed app into a notarized, drag-to-Applications disk image.
#
# Run from an install-only Run Script build phase (Product > Archive). Writes
# build/<PRODUCT_NAME>-<MARKETING_VERSION>.dmg in the project directory.
#
# Notarization (see scripts/notarytool-submit.sh): in CI an App Store Connect API key
# (NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID); locally a notarytool keychain profile,
# created once with:
#   xcrun notarytool store-credentials DeFeedbackHost-Notary \
#       --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>
# Override the profile name with NOTARY_KEYCHAIN_PROFILE. Set SKIP_NOTARIZATION=YES
# to build a signed but un-notarized image. ALLOW_UNSIGNED_DMG=YES packs the app into an UNSIGNED,
# un-notarized image when there is no Developer ID identity (CI uses it to prove packaging works on
# pull requests, where no certificate is available); never ship that image.
set -eu

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
UNSIGNED=NO
if [ -z "${SIGN_IDENTITY}" ]; then
    if [ "${ALLOW_UNSIGNED_DMG:-NO}" = "YES" ]; then
        UNSIGNED=YES
        echo "warning: no Developer ID identity; building an UNSIGNED, un-notarized image (ALLOW_UNSIGNED_DMG=YES)."
    else
        echo "error: No \"Developer ID Application\" identity for team ${DEVELOPMENT_TEAM} in the keychain."
        exit 1
    fi
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

if [ "${UNSIGNED}" = "NO" ]; then
    # Sparkle's nested code must be signed first (inside-out) or notarization rejects the app.
    "${PROJECT_DIR}/scripts/sign-sparkle.sh" "${STAGED_APP}" "${SIGN_IDENTITY}"

    # Xcode signs the product only after every build phase has run, so the staged
    # copy is not signed yet. Sign it for distribution: hardened runtime + timestamp.
    codesign --force --options runtime --timestamp \
        --sign "${SIGN_IDENTITY}" \
        --entitlements "${ENTITLEMENTS}" \
        "${STAGED_APP}"
    codesign --verify --strict --verbose=2 "${STAGED_APP}"
fi

ln -s /Applications "${STAGING_DIR}/Applications"

rm -f "${DMG_PATH}"
"${PROJECT_DIR}/scripts/make-dmg.sh" "${STAGING_DIR}" "${DMG_PATH}" "Lynx DeFeedback Host"
[ "${UNSIGNED}" = "NO" ] && codesign --force --timestamp --sign "${SIGN_IDENTITY}" "${DMG_PATH}"
rm -rf "${STAGING_DIR}" "${ENTITLEMENTS}"

if [ "${UNSIGNED}" = "YES" ]; then
    echo "Created UNSIGNED ${DMG_PATH} (not notarized; do not ship)."
    exit 0
fi

if [ "${SKIP_NOTARIZATION}" = "YES" ]; then
    echo "warning: Skipping notarization; ${DMG_PATH} will trigger Gatekeeper on other Macs."
    exit 0
fi

"${PROJECT_DIR}/scripts/notarytool-submit.sh" "${DMG_PATH}"
xcrun stapler staple "${DMG_PATH}"
spctl --assess --type open --context context:primary-signature --verbose=2 "${DMG_PATH}"

echo "Created ${DMG_PATH}"
