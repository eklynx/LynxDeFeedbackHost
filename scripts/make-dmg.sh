#!/bin/sh
# Packs a folder into a compressed disk image (UDZO), and says why when that fails.
#
# Usage: make-dmg.sh <source folder> <output.dmg> <volume name>
#
# `hdiutil create` is what this repo used first, and Apple has deprecated that form in favour of
# `diskutil image create from`. A hosted CI runner once failed it with only "No such file or
# directory" and worked on the next try, so: hdiutil is tried up to 3 times (MAKE_DMG_RETRY_DELAY
# seconds apart, default 5); if it still fails this prints what is needed to diagnose it (the staged
# folder, dangling symlinks, sizes, free space, path lengths) and retries with diskutil. A release
# should not die on one flaky tool run.
set -eu

die() { echo "error: $*" >&2; exit 1; }

SRC="${1:?usage: make-dmg.sh <source folder> <output.dmg> <volume name>}"
OUT="${2:?usage: make-dmg.sh <source folder> <output.dmg> <volume name>}"
VOLUME="${3:?usage: make-dmg.sh <source folder> <output.dmg> <volume name>}"

[ -d "${SRC}" ] || die "source folder ${SRC} does not exist"
OUT_DIR="$(dirname "${OUT}")"
mkdir -p "${OUT_DIR}"
rm -f "${OUT}"

DELAY="${MAKE_DMG_RETRY_DELAY:-5}"
STATUS=0
for attempt in 1 2 3; do
    if hdiutil create -volname "${VOLUME}" -srcfolder "${SRC}" -format UDZO -ov "${OUT}"; then
        exit 0
    fi
    STATUS=$?
    echo "warning: hdiutil create failed (attempt ${attempt} of 3, exit ${STATUS})" >&2
    rm -f "${OUT}"
    [ "${attempt}" -lt 3 ] && sleep "${DELAY}"
done

{
    echo "warning: hdiutil create failed 3 times (last exit ${STATUS}); details:"
    echo "--- source folder ${SRC}:"
    ls -la "${SRC}" || true
    echo "--- dangling symlinks inside it:"
    find "${SRC}" -type l ! -exec test -e {} \; -print 2>/dev/null | head -20 || true
    echo "--- size (KB): $(du -sk "${SRC}" 2>/dev/null | cut -f1)"
    echo "--- output folder ${OUT_DIR}:"
    ls -ld "${OUT_DIR}" || true
    df -h "${OUT_DIR}" | tail -1 || true
    echo "--- path lengths: source ${#SRC}, output ${#OUT}"
    echo "retrying with: diskutil image create from"
} >&2

rm -f "${OUT}"
diskutil image create from "${SRC}" "${OUT}" --format UDZO --volumeName "${VOLUME}" \
    || die "could not create ${OUT} with hdiutil or diskutil"
[ -f "${OUT}" ] || die "${OUT} was not created"
