#!/bin/sh
# Checks a finished release DMG before anything is published.
#
# Usage: verify-release.sh <dmg> <expected marketing version> <expected build number>
#
# Verifies: the DMG is notarized and stapled, Gatekeeper accepts it, and the app inside carries the
# expected CFBundleShortVersionString and CFBundleVersion (a wrong number would break update order).
set -eu

DMG="${1:?usage: verify-release.sh <dmg> <version> <build>}"
VERSION="${2:?usage: verify-release.sh <dmg> <version> <build>}"
BUILD="${3:?usage: verify-release.sh <dmg> <version> <build>}"

[ -f "${DMG}" ] || { echo "error: ${DMG} not found" >&2; exit 1; }

xcrun stapler validate "${DMG}"
spctl --assess --type open --context context:primary-signature --verbose=2 "${DMG}"

MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/verify-release.XXXXXX")"
cleanup() { hdiutil detach "${MOUNT}" -quiet 2>/dev/null || true; rmdir "${MOUNT}" 2>/dev/null || true; }
trap cleanup EXIT
hdiutil attach "${DMG}" -nobrowse -readonly -mountpoint "${MOUNT}" -quiet

APP="$(ls -d "${MOUNT}"/*.app | head -n 1)"
[ -d "${APP}" ] || { echo "error: no .app inside ${DMG}" >&2; exit 1; }
PLIST="${APP}/Contents/Info.plist"
GOT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PLIST}")"
GOT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${PLIST}")"

[ "${GOT_VERSION}" = "${VERSION}" ] || { echo "error: app version ${GOT_VERSION}, expected ${VERSION}" >&2; exit 1; }
[ "${GOT_BUILD}" = "${BUILD}" ] || { echo "error: app build ${GOT_BUILD}, expected ${BUILD}" >&2; exit 1; }
codesign --verify --deep --strict --verbose=2 "${APP}"

echo "Verified ${DMG}: version ${GOT_VERSION}, build ${GOT_BUILD}."
