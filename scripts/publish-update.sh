#!/bin/sh
# Signs a notarized DMG for Sparkle, adds it to appcast.xml, and (optionally) uploads it to a
# GitHub Release. Non-interactive on purpose: a GitHub Action can call it unchanged later.
#
# Usage:
#   scripts/publish-update.sh --dmg build/DeFeedbackHost-0.2.0.dmg --app <path/to/DeFeedbackHost.app> \
#       [--site-dir build/site] [--upload]
#   scripts/publish-update.sh --dmg <dmg> --version 0.2.0 --build 123 [...]   # no app bundle at hand
#
# Options:
#   --dmg <path>       The notarized, stapled DMG (required).
#   --app <path>       App bundle to read CFBundleShortVersionString / CFBundleVersion from.
#   --version <v>      Version shown to users (sparkle:shortVersionString). Required without --app.
#                      Releases: X.Y.Z. Nightlies: the full version X.Y.Z-<stamp>.<hash>.
#   --build <n>        Build number (sparkle:version = CFBundleVersion = UTC yyyyMMddHHmmss).
#   --channel <c>      release (default), prerelease or nightly. Non-release items get a
#                      <sparkle:channel> tag so only users who opted in are offered them.
#   --tag <t>          GitHub release tag. Default v<version>, or nightly-<version> for nightly.
#   --site-dir <dir>   Directory served by GitHub Pages (default: build/site). An existing
#                      appcast.xml in it is updated; the new release goes first.
#   --upload           `gh release create/upload` the DMG to the tag (needs `gh` auth). Pre-release
#                      and nightly releases are marked as GitHub pre-releases, never "latest".
#   --min-os <v>       sparkle:minimumSystemVersion (default 27.0, the deployment target).
#
# Signing key (private half of the key whose public half is the SPARKLE_PUBLIC_ED_KEY build
# setting; create once with Sparkle's `generate_keys`):
#   SPARKLE_ED_PRIVATE_KEY   the base64 private key (CI secret). Piped to sign_update on stdin,
#                            never written to disk or a command line.
#   (unset)                  falls back to the login-keychain key for SPARKLE_KEYCHAIN_ACCOUNT.
#   SPARKLE_KEYCHAIN_ACCOUNT keychain account of the key (default DeFeedbackHost).
# To use the key in CI, export it once with `generate_keys --account DeFeedbackHost -x <file>` and
# store the file contents as the SPARKLE_ED_PRIVATE_KEY secret. Keep an offline backup of it too.
# Other environment:
#   SPARKLE_BIN   directory containing sign_update (default: the SPM artifact in derived data).
#   GITHUB_REPO   owner/name for download URLs (default eklynx/LynxDeFeedbackHost).
#   RELEASE_NOTES  text for the new GitHub Release (with --upload). Unset: GitHub generates the notes.
#                 CI sets it for nightlies ("Not a release.").
#   RELEASE_TARGET  commit the new tag should point at (with --upload). CI sets it to the commit it
#                 built, so the tag lands on the tested code even if main moved meanwhile. Unset: the
#                 repository's default branch head.
#
# Publishing the feed: commit the contents of --site-dir to the `gh-pages` branch (Pages source).
# The app's SUFeedURL is https://eklynx.github.io/LynxDeFeedbackHost/appcast.xml.
set -eu

GITHUB_REPO="${GITHUB_REPO:-eklynx/LynxDeFeedbackHost}"
DMG=""; APP=""; VERSION=""; BUILD=""; UPLOAD=NO; MIN_OS="27.0"; CHANNEL="release"; TAG=""
SITE_DIR="build/site"

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --dmg) DMG="${2:?}"; shift 2 ;;
        --app) APP="${2:?}"; shift 2 ;;
        --version) VERSION="${2:?}"; shift 2 ;;
        --build) BUILD="${2:?}"; shift 2 ;;
        --site-dir) SITE_DIR="${2:?}"; shift 2 ;;
        --min-os) MIN_OS="${2:?}"; shift 2 ;;
        --channel) CHANNEL="${2:?}"; shift 2 ;;
        --tag) TAG="${2:?}"; shift 2 ;;
        --upload) UPLOAD=YES; shift ;;
        -h|--help) sed -n '2,43p' "$0"; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

case "${CHANNEL}" in
    release|prerelease|nightly) ;;
    *) die "--channel must be release, prerelease or nightly (got '${CHANNEL}')" ;;
esac
[ -f "${DMG}" ] || die "--dmg is required and must exist"
if [ -n "${APP}" ]; then
    PLIST="${APP}/Contents/Info.plist"
    VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PLIST}")}"
    BUILD="${BUILD:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${PLIST}")}"
fi
[ -n "${VERSION}" ] && [ -n "${BUILD}" ] || die "need --app, or both --version and --build"

if [ -z "${SPARKLE_BIN:-}" ]; then
    SPARKLE_BIN="$(ls -d "${CLAUDE_WORK:-/nonexistent}"/derived/*/SourcePackages/artifacts/sparkle/Sparkle/bin \
        "$HOME"/Library/Developer/Xcode/DerivedData/*/SourcePackages/artifacts/sparkle/Sparkle/bin 2>/dev/null | head -n 1)"
fi
SIGN_UPDATE="${SPARKLE_BIN:-}/sign_update"
[ -x "${SIGN_UPDATE}" ] || die "sign_update not found; set SPARKLE_BIN to Sparkle's bin directory"

# Signature only (-p). The key comes from the environment or, failing that, the keychain.
if [ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
    SIGNATURE="$(printf '%s' "${SPARKLE_ED_PRIVATE_KEY}" | "${SIGN_UPDATE}" --ed-key-file - -p "${DMG}")"
else
    SIGNATURE="$("${SIGN_UPDATE}" --account "${SPARKLE_KEYCHAIN_ACCOUNT:-DeFeedbackHost}" -p "${DMG}")"
fi
[ -n "${SIGNATURE}" ] || die "signing failed"

LENGTH="$(stat -f%z "${DMG}")"
DMG_NAME="$(basename "${DMG}")"
if [ -z "${TAG}" ]; then
    if [ "${CHANNEL}" = "nightly" ]; then TAG="nightly-${VERSION}"; else TAG="v${VERSION}"; fi
fi
URL="https://github.com/${GITHUB_REPO}/releases/download/${TAG}/${DMG_NAME}"
NOTES="https://github.com/${GITHUB_REPO}/releases/tag/${TAG}"

mkdir -p "${SITE_DIR}"
FEED="${SITE_DIR}/appcast.xml"

VERSION="${VERSION}" BUILD="${BUILD}" CHANNEL="${CHANNEL}" URL="${URL}" NOTES="${NOTES}" SIGNATURE="${SIGNATURE}" \
LENGTH="${LENGTH}" MIN_OS="${MIN_OS}" FEED="${FEED}" python3 -I - <<'PY'
import os, email.utils
from xml.sax.saxutils import escape, quoteattr

e = os.environ
channel = ""
if e['CHANNEL'] != 'release':
    channel = f"      <sparkle:channel>{escape(e['CHANNEL'])}</sparkle:channel>\n"

item = f"""    <item>
      <title>Version {escape(e['VERSION'])}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <link>{escape(e['NOTES'])}</link>
{channel}      <sparkle:version>{escape(e['BUILD'])}</sparkle:version>
      <sparkle:shortVersionString>{escape(e['VERSION'])}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(e['MIN_OS'])}</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>{escape(e['NOTES'])}</sparkle:releaseNotesLink>
      <enclosure url={quoteattr(e['URL'])} length="{e['LENGTH']}" type="application/octet-stream" sparkle:edSignature={quoteattr(e['SIGNATURE'])}/>
    </item>
"""

head = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Lynx DeFeedback Host</title>
"""
tail = "  </channel>\n</rss>\n"

existing = []
if os.path.exists(e["FEED"]):
    body = open(e["FEED"], encoding="utf-8").read()
    # Keep earlier releases, but drop any previous entry for this same build number.
    for chunk in body.split("<item>")[1:]:
        chunk = "    <item>" + chunk.split("</item>")[0] + "</item>\n"
        if f"<sparkle:version>{e['BUILD']}</sparkle:version>" not in chunk:
            existing.append(chunk)

open(e["FEED"], "w", encoding="utf-8").write(head + item + "".join(existing) + tail)
PY

echo "Wrote ${FEED} (version ${VERSION}, build ${BUILD}, channel ${CHANNEL})"

if [ "${UPLOAD}" = "YES" ]; then
    if gh release view "${TAG}" --repo "${GITHUB_REPO}" >/dev/null 2>&1; then
        gh release upload "${TAG}" "${DMG}" --repo "${GITHUB_REPO}" --clobber
    else
        set -- "${TAG}" "${DMG}" --repo "${GITHUB_REPO}" --title "${TAG}"
        if [ -n "${RELEASE_NOTES:-}" ]; then set -- "$@" --notes "${RELEASE_NOTES}"; else set -- "$@" --generate-notes; fi
        if [ -n "${RELEASE_TARGET:-}" ]; then set -- "$@" --target "${RELEASE_TARGET}"; fi
        if [ "${CHANNEL}" != "release" ]; then set -- "$@" --prerelease --latest=false; fi
        gh release create "$@"
    fi
fi

PAGES_URL="https://${GITHUB_REPO%%/*}.github.io/${GITHUB_REPO#*/}/appcast.xml"
echo "Next: publish ${SITE_DIR} to the gh-pages branch so ${PAGES_URL} serves it."
