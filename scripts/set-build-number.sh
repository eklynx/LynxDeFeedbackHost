#!/bin/sh
# Stamps the built product's Info.plist with:
#   CFBundleVersion  the build number: $BUILD_NUMBER when set (CI passes one value to the build
#                    and to the appcast), otherwise the UTC build time as yyyyMMddHHmmss, e.g.
#                    20261125030000. Sparkle orders builds by this number, so it must rise across
#                    every build channel (release, pre-release, nightly) and every workflow; a
#                    timestamp does, a per-workflow run number or a commit count does not.
#   GitCommit        the short commit hash, e.g. 8da0029, shown in the About window.
#
# The marketing version (CFBundleShortVersionString) stays a plain X.Y.Z build setting.
#
# Run from a Run Script build phase placed after Resources, with
# $(TARGET_BUILD_DIR)/$(INFOPLIST_PATH) as an input file. Build settings can't
# be changed from a script phase, so this edits the processed Info.plist
# directly; Xcode code-signs the product only after every build phase has run,
# so the edit is covered by the signature.
set -eu

PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"

BUILD="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M%S)}"
case "${BUILD}" in
    ''|*[!0-9]*) echo "error: build number must be digits only, got '${BUILD}'" >&2; exit 1 ;;
esac

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD}" "${PLIST}"

if GIT_COMMIT="$(git -C "${SRCROOT}" rev-parse --short HEAD 2>/dev/null)"; then
    # GitCommit isn't a standard key, so it may not exist yet; replace it either way.
    /usr/libexec/PlistBuddy -c "Delete :GitCommit" "${PLIST}" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :GitCommit string ${GIT_COMMIT}" "${PLIST}"
    echo "Set CFBundleVersion to ${BUILD}, GitCommit to ${GIT_COMMIT}"
else
    # Not a git checkout (e.g. a source tarball): no hash to show.
    echo "warning: git unavailable; GitCommit left as is."
    echo "Set CFBundleVersion to ${BUILD}"
fi
