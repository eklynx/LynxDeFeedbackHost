#!/bin/sh
# Computes the version of the next build from git tags. The tags are the single source of truth:
# no version file, nothing committed back, so no bump commits and no merge conflicts.
#
# Usage:
#   scripts/compute-version.sh [--github-output]
#
# Environment (all optional):
#   VERSION_KIND       release (default) | nightly | prerelease
#   VERSION_BUMP       patch (default) | minor | major. Release and prerelease: which release it is.
#   VERSION_LABEL      prerelease only: the label, lowercase letters (default beta).
#   VERSION_TIMESTAMP  UTC build time, yyyyMMddHHmmss. Default: now. Set it to make runs repeatable.
#   VERSION_SHA        short commit hash. Default: `git rev-parse --short=7 HEAD`.
#   PLUGIN_LEDGER      path of the ledger of plugin versions already shipped (lines `<plugin hash> <version>`).
#                      Default: none, so every plugin is new. See plugin_version.
#
# Output, one key=value per line (and appended to $GITHUB_OUTPUT with --github-output):
#   marketing_version  plain X.Y.Z. Apple's CFBundleShortVersionString can't hold a suffix.
#   full_version       X.Y.Z for a release, X.Y.Z-<timestamp>.<sha> for a nightly,
#                      X.Y.Z-<label>.<N> for a prerelease (N counts up per X.Y.Z and label).
#                      Names artifacts, tags and update messages.
#   build_number       the timestamp. Becomes CFBundleVersion (BUILD_NUMBER for set-build-number.sh)
#                      and sparkle:version, which Sparkle orders builds by: it must rise across
#                      every workflow, and a timestamp does.
#   tag                vX.Y.Z for a release, nightly-<full_version> for a nightly,
#                      v<full_version> (e.g. v0.2.0-beta.1) for a prerelease.
#   plugin_version     the version stamped into the Stream Deck plugin's manifest (scripts/stamp-plugin-version.sh).
#                      If the ledger already has the plugin's hash (plugin_hash), that version: the plugin
#                      didn't change, so it keeps its version. Otherwise X.Y.Z.N, N one more than the highest
#                      4th number the ledger has for this X.Y.Z (0 if none).
#   plugin_hash        scripts/plugin-hash.sh: the plugin's code, ignoring its manifest version number.
#   channel            release | nightly | prerelease (the update channel the build goes to).
#   base_tag           the tag this version was derived from; empty when there was none.
#
# Rules:
#   * The latest version is the highest tag of the form vX.Y.Z or X.Y.Z (old releases were tagged
#     without the "v"), compared numerically (0.10.0 is newer than 0.9.0).
#   * Nightly tags and pre-release tags (v1.2.0-beta.1) never count, so nightlies can't move the
#     release number.
#   * Release: the latest version bumped by VERSION_BUMP. Nightly: the latest with patch + 1, plus
#     the suffix. With no tag at all the release is 1.0.0 and a nightly is 1.0.1-...
#   * Prerelease: the release it leads to (the latest bumped by VERSION_BUMP, exactly as a release),
#     then -<label>.<N>, where N is one more than the highest existing v<X.Y.Z>-<label>.<N> tag. A
#     different label or version starts again at 1.
#   * The tags must be present. A shallow clone without them fails loudly instead of quietly
#     falling back to 1.0.0: fetch with `fetch-depth: 0`.
set -eu

die() { echo "error: $*" >&2; exit 1; }

GITHUB_OUTPUT_FLAG=NO
while [ $# -gt 0 ]; do
    case "$1" in
        --github-output) GITHUB_OUTPUT_FLAG=YES; shift ;;
        -h|--help) sed -n '2,46p' "$0"; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

KIND="${VERSION_KIND:-release}"
BUMP="${VERSION_BUMP:-patch}"
case "${KIND}" in release|nightly|prerelease) ;; *) die "VERSION_KIND must be release, nightly or prerelease (got '${KIND}')" ;; esac
LABEL="${VERSION_LABEL:-beta}"
if [ "${KIND}" = "prerelease" ]; then
    # An explicit list, not [a-z]: in some locales that range also matches capital letters.
    case "${LABEL}" in ''|*[!abcdefghijklmnopqrstuvwxyz]*) die "VERSION_LABEL must be lowercase letters only (got '${LABEL}')" ;; esac
fi
case "${BUMP}" in patch|minor|major) ;; *) die "VERSION_BUMP must be patch, minor or major (got '${BUMP}')" ;; esac

STAMP="${VERSION_TIMESTAMP:-$(date -u +%Y%m%d%H%M%S)}"
case "${STAMP}" in ''|*[!0-9]*) die "VERSION_TIMESTAMP must be digits only (got '${STAMP}')" ;; esac

git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
SHA="${VERSION_SHA:-$(git rev-parse --short=7 HEAD)}"

TAGS="$(git tag --list | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' || true)"

BASE_TAG=""
if [ -z "${TAGS}" ]; then
    if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
        die "no version tags found in a shallow clone; fetch the tags (actions/checkout with fetch-depth: 0)"
    fi
    LATEST="1.0.0"
    NO_TAGS=YES
else
    NO_TAGS=NO
    LATEST="$(printf '%s\n' "${TAGS}" | sed 's/^v//' | sort -t. -k1,1nr -k2,2nr -k3,3nr | head -n 1)"
    # Name the real tag, preferring the v form when both exist.
    if printf '%s\n' "${TAGS}" | grep -qx "v${LATEST}"; then BASE_TAG="v${LATEST}"; else BASE_TAG="${LATEST}"; fi
fi

OLD_IFS="${IFS}"; IFS=.
set -- ${LATEST}
IFS="${OLD_IFS}"
MAJOR="$1"; MINOR="$2"; PATCH="$3"

if [ "${KIND}" = "nightly" ]; then
    PATCH=$((PATCH + 1))
elif [ "${NO_TAGS}" = "NO" ]; then
    case "${BUMP}" in
        major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
        minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
        patch) PATCH=$((PATCH + 1)) ;;
    esac
fi
# (Release with no tags at all: 1.0.0 itself, unbumped.)

MARKETING="${MAJOR}.${MINOR}.${PATCH}"
if [ "${KIND}" = "nightly" ]; then
    FULL="${MARKETING}-${STAMP}.${SHA}"
    TAG="nightly-${FULL}"
elif [ "${KIND}" = "prerelease" ]; then
    # One more than the highest existing v<MARKETING>-<LABEL>.<N>.
    HIGHEST="$(git tag --list | awk -v p="v${MARKETING}-${LABEL}." \
        'index($0, p) == 1 { n = substr($0, length(p) + 1); if (n ~ /^[0-9]+$/ && n + 0 > max) max = n + 0 } END { print max + 0 }')"
    FULL="${MARKETING}-${LABEL}.$((HIGHEST + 1))"
    TAG="v${FULL}"
else
    FULL="${MARKETING}"
    TAG="v${MARKETING}"
fi

# The plugin's version: reuse the one the ledger has for this exact plugin code, else the next for this X.Y.Z.
PLUGIN_HASH="$(sh "$(dirname "$0")/plugin-hash.sh")"
PLUGIN_VERSION=""
LEDGER="${PLUGIN_LEDGER:-}"
if [ -n "${LEDGER}" ] && [ -f "${LEDGER}" ]; then
    PLUGIN_VERSION="$(awk -v h="${PLUGIN_HASH}" '$1 == h { print $2; exit }' "${LEDGER}")"
    case "${PLUGIN_VERSION}" in ''|*[!0-9.]*) PLUGIN_VERSION="" ;; esac
fi
if [ -z "${PLUGIN_VERSION}" ]; then
    NEXT=0
    if [ -n "${LEDGER}" ] && [ -f "${LEDGER}" ]; then
        NEXT="$(awk -v p="${MARKETING}." 'index($2, p) == 1 { n = substr($2, length(p) + 1); if (n ~ /^[0-9]+$/ && n + 1 > top) top = n + 1 } END { print top + 0 }' "${LEDGER}")"
    fi
    PLUGIN_VERSION="${MARKETING}.${NEXT}"
fi

emit() {
    echo "$1=$2"
    if [ "${GITHUB_OUTPUT_FLAG}" = "YES" ]; then
        [ -n "${GITHUB_OUTPUT:-}" ] || die "--github-output needs the GITHUB_OUTPUT environment variable"
        echo "$1=$2" >> "${GITHUB_OUTPUT}"
    fi
}

emit marketing_version "${MARKETING}"
emit full_version "${FULL}"
emit build_number "${STAMP}"
emit plugin_version "${PLUGIN_VERSION}"
emit plugin_hash "${PLUGIN_HASH}"
emit tag "${TAG}"
emit channel "${KIND}"
emit base_tag "${BASE_TAG}"
