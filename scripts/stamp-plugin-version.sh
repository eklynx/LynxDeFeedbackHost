#!/bin/sh
# Writes a version into the Stream Deck plugin's manifest, in the working copy only (nothing is committed).
# The release workflow runs it before the app is archived, so the plugin packed into the app carries the
# release's version and the app can tell when the installed plugin is older (issue #64).
#
# Usage: stamp-plugin-version.sh <X.Y.Z.N> [manifest]
#   <X.Y.Z.N>  four dot-separated numbers; from `compute-version.sh` (plugin_version).
#   [manifest] default: streamdeck/com.eklynx.sound.defeedback.sdPlugin/manifest.json under the repo root.
#
# Changes only the top-level "Version" (one tab of indent); the nested "Version" of the Node.js runtime is
# left alone. Exits non-zero, changing nothing, for a malformed version, a missing manifest or a manifest
# with no top-level "Version". Spec: docs/versioning-spec.md (V14, V15).
set -eu

die() { echo "error: $*" >&2; exit 1; }

VERSION="${1:?usage: stamp-plugin-version.sh <X.Y.Z.N> [manifest]}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="${2:-${ROOT}/streamdeck/com.eklynx.sound.defeedback.sdPlugin/manifest.json}"

case "${VERSION}" in
    *[!0-9.]*|.*|*.|*..*) die "version must be four dot-separated numbers (got '${VERSION}')" ;;
esac
[ "$(printf '%s' "${VERSION}" | tr -cd . | wc -c | tr -d ' ')" = "3" ] \
    || die "version must be four dot-separated numbers (got '${VERSION}')"
[ -f "${MANIFEST}" ] || die "${MANIFEST} not found"

TAB="$(printf '\t')"
grep -q "^${TAB}\"Version\": \"[0-9.]*\"," "${MANIFEST}" || die "no top-level \"Version\" in ${MANIFEST}"

TMP="$(mktemp "${TMPDIR:-/tmp}/manifest.XXXXXX")"
trap 'rm -f "${TMP}"' EXIT
sed "s/^${TAB}\"Version\": \"[0-9.]*\",/${TAB}\"Version\": \"${VERSION}\",/" "${MANIFEST}" > "${TMP}"
cat "${TMP}" > "${MANIFEST}"
echo "Stamped ${MANIFEST} with ${VERSION}"
