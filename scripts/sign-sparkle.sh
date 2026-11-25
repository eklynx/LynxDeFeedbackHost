#!/bin/sh
# Re-signs the embedded Sparkle.framework inside-out with a Developer ID identity.
#
# Notarization needs every nested executable signed with hardened runtime + timestamp, and
# `codesign` on the app alone does not do that for nested code (and we avoid --deep). Run this
# BEFORE signing the app bundle itself, since the app's signature covers the framework.
#
# Usage: sign-sparkle.sh <path/to/App.app> <codesign identity>
# Non-interactive, so a GitHub Action can call it unchanged.
set -eu

APP="${1:?usage: sign-sparkle.sh <App.app> <identity>}"
IDENTITY="${2:?usage: sign-sparkle.sh <App.app> <identity>}"

FRAMEWORK="${APP}/Contents/Frameworks/Sparkle.framework"
if [ ! -d "${FRAMEWORK}" ]; then
    echo "warning: no Sparkle.framework in ${APP}; nothing to sign."
    exit 0
fi

B="${FRAMEWORK}/Versions/B"
sign() { codesign --force --options runtime --timestamp --sign "${IDENTITY}" "$@"; }

# Innermost first. Downloader.xpc (present in sandbox-capable builds) must keep its entitlements.
for xpc in "${B}"/XPCServices/*.xpc; do
    [ -d "${xpc}" ] || continue
    case "${xpc}" in
        *Downloader.xpc) sign --preserve-metadata=entitlements "${xpc}" ;;
        *) sign "${xpc}" ;;
    esac
done
[ -e "${B}/Autoupdate" ] && sign "${B}/Autoupdate"
[ -d "${B}/Updater.app" ] && sign "${B}/Updater.app"
sign "${FRAMEWORK}"

codesign --verify --strict --verbose=2 "${FRAMEWORK}"
