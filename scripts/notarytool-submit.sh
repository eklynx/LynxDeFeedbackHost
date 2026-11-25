#!/bin/sh
# Submits a signed file (DMG) to Apple's notary service and waits for the verdict.
# Fails unless the status is Accepted, so a rejection can never be mistaken for success.
#
# Usage: notarytool-submit.sh <file>
#
# Authentication, chosen from the environment:
#   App Store Connect API key (CI): set all three of
#       NOTARY_KEY_PATH     path to the AuthKey_XXXX.p8 file
#       NOTARY_KEY_ID       the key id
#       NOTARY_ISSUER_ID    the issuer id
#   Keychain profile (local builds): otherwise NOTARY_KEYCHAIN_PROFILE (default
#       DeFeedbackHost-Notary), created once with `xcrun notarytool store-credentials`.
# Setting only some of the three API key variables is an error, not a silent fallback to the profile.
set -eu

FILE="${1:?usage: notarytool-submit.sh <file>}"
[ -f "${FILE}" ] || { echo "error: ${FILE} not found" >&2; exit 1; }

KEY_VARS=0
[ -n "${NOTARY_KEY_PATH:-}" ] && KEY_VARS=$((KEY_VARS + 1))
[ -n "${NOTARY_KEY_ID:-}" ] && KEY_VARS=$((KEY_VARS + 1))
[ -n "${NOTARY_ISSUER_ID:-}" ] && KEY_VARS=$((KEY_VARS + 1))

OUTPUT="$(mktemp "${TMPDIR:-/tmp}/notary-output.XXXXXX")"
trap 'rm -f "${OUTPUT}"' EXIT

if [ "${KEY_VARS}" -eq 3 ]; then
    [ -f "${NOTARY_KEY_PATH}" ] || { echo "error: NOTARY_KEY_PATH ${NOTARY_KEY_PATH} not found" >&2; exit 1; }
    xcrun notarytool submit "${FILE}" \
        --key "${NOTARY_KEY_PATH}" --key-id "${NOTARY_KEY_ID}" --issuer "${NOTARY_ISSUER_ID}" \
        --wait 2>&1 | tee "${OUTPUT}" || true
elif [ "${KEY_VARS}" -eq 0 ]; then
    xcrun notarytool submit "${FILE}" \
        --keychain-profile "${NOTARY_KEYCHAIN_PROFILE:-DeFeedbackHost-Notary}" \
        --wait 2>&1 | tee "${OUTPUT}" || true
else
    echo "error: set all of NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID, or none of them" >&2
    exit 1
fi

if ! grep -q "status: Accepted" "${OUTPUT}"; then
    echo "error: notarization of ${FILE} was not accepted" >&2
    exit 1
fi
