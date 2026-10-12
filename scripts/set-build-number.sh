#!/bin/sh
# Stamps the built product's Info.plist with:
#   CFBundleVersion  the number of commits reachable from HEAD, e.g. 142. App Store safe,
#                    and increases with every commit as long as releases come from one
#                    branch whose history isn't rewritten.
#   GitCommit        the short commit hash, e.g. 8da0029, shown in the About window.
#
# Run from a Run Script build phase placed after Resources, with
# $(TARGET_BUILD_DIR)/$(INFOPLIST_PATH) as an input file. Build settings can't
# be changed from a script phase, so this edits the processed Info.plist
# directly; Xcode code-signs the product only after every build phase has run,
# so the edit is covered by the signature.
set -eu

PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"

if ! COMMIT_COUNT="$(git -C "${SRCROOT}" rev-list --count HEAD 2>/dev/null)"; then
    # Not a git checkout (e.g. a source tarball): keep CURRENT_PROJECT_VERSION.
    echo "warning: git unavailable; leaving CFBundleVersion as ${CURRENT_PROJECT_VERSION}."
    exit 0
fi
GIT_COMMIT="$(git -C "${SRCROOT}" rev-parse --short HEAD)"

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${COMMIT_COUNT}" "${PLIST}"
# GitCommit isn't a standard key, so it may not exist yet; replace it either way.
/usr/libexec/PlistBuddy -c "Delete :GitCommit" "${PLIST}" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :GitCommit string ${GIT_COMMIT}" "${PLIST}"

echo "Set CFBundleVersion to ${COMMIT_COUNT}, GitCommit to ${GIT_COMMIT}"
