#!/bin/sh
# Keeps nightly builds (or pre-releases) to the newest N: picks the old ones, and removes their items
# from the Sparkle appcast so the feed never points at a deleted download.
#
# Usage:
#   gh release list --json tagName,createdAt --jq '.[]|[.tagName,.createdAt]|@tsv' \
#       | scripts/ci/prune-builds.sh select --kind nightly --keep 7       # prints the tags to delete
#   scripts/ci/prune-builds.sh feed --kind nightly <appcast.xml> <tag>... # removes those items
#
# --kind is `nightly` (tags nightly-*, appcast channel `nightly`) or `prerelease` (tags
# v<X.Y.Z>-<label>.<N>, e.g. v0.2.0-beta.1, appcast channel `prerelease`).
#
# `select` reads `tag<TAB>createdAt` lines on stdin and prints the tags OF THAT KIND beyond the
# newest N by date, oldest last. Releases and tags of the other kind are never listed.
#
# `feed` removes only items that are on that kind's channel AND whose download URL is under
# /releases/download/<tag>/ for a tag of that kind, so release items, the other kind's items, or a
# wrong argument can't remove anything else. It leaves the file untouched (byte for byte) when
# nothing matches.
#
# Order matters for the caller: push the changed feed first, delete the GitHub Releases after.
set -eu

die() { echo "error: $*" >&2; exit 1; }

# Is $1 a tag of kind $2?
is_kind_tag() {
    case "$2" in
        nightly) case "$1" in nightly-*) return 0 ;; *) return 1 ;; esac ;;
        prerelease) printf '%s\n' "$1" | grep -E -q '^v[0-9]+\.[0-9]+\.[0-9]+-[[:lower:]]+\.[0-9]+$' ;;
        *) return 1 ;;
    esac
}

COMMAND="${1:-}"
[ $# -gt 0 ] && shift

take_kind() {
    [ "${1:-}" = "--kind" ] || die "--kind nightly|prerelease is required"
    KIND="${2:-}"
    case "${KIND}" in nightly|prerelease) ;; *) die "--kind must be nightly or prerelease (got '${KIND}')" ;; esac
}

case "${COMMAND}" in
    select)
        take_kind "$@"; shift 2
        KEEP=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --keep) KEEP="${2:?--keep needs a number}"; shift 2 ;;
                *) die "unknown option: $1" ;;
            esac
        done
        case "${KEEP}" in ''|*[!0-9]*) die "--keep must be a whole number of 1 or more" ;; esac
        [ "${KEEP}" -ge 1 ] || die "--keep must be 1 or more (refusing to delete every build)"
        TAB="$(printf '\t')"
        # Only tags of this kind, newest first by createdAt; everything after the first KEEP is old.
        while IFS="${TAB}" read -r tag created rest; do
            [ -n "${tag}" ] && [ -n "${created}" ] || continue
            is_kind_tag "${tag}" "${KIND}" && printf '%s\t%s\n' "${tag}" "${created}"
        done | sort -t "${TAB}" -k2,2r | tail -n +"$((KEEP + 1))" | cut -f1
        ;;

    feed)
        take_kind "$@"; shift 2
        FEED="${1:?usage: prune-builds.sh feed --kind K <appcast.xml> <tag>...}"
        shift
        [ -f "${FEED}" ] || die "${FEED} not found"
        [ $# -gt 0 ] || { echo "removed 0 item(s) (no tags given)"; exit 0; }
        for tag in "$@"; do
            is_kind_tag "${tag}" "${KIND}" || die "refusing to remove '${tag}': only ${KIND} tags may be pruned with --kind ${KIND}"
        done
        FEED="${FEED}" KIND="${KIND}" python3 -I - "$@" <<'PY'
import os, re, sys

path = os.environ["FEED"]
channel = f"<sparkle:channel>{os.environ['KIND']}</sparkle:channel>"
tags = sys.argv[1:]
text = open(path, encoding="utf-8").read()
removed = 0

def drop(match):
    global removed
    item = match.group(0)
    if channel not in item:
        return item                      # only this kind's channel is ever eligible
    for tag in tags:
        if f"/releases/download/{tag}/" in item:
            removed += 1
            return ""
    return item

new = re.sub(r"[ \t]*<item>.*?</item>\n", drop, text, flags=re.S)
if removed:
    open(path, "w", encoding="utf-8").write(new)
print(f"removed {removed} item(s)")
PY
        ;;

    *) die "usage: prune-builds.sh select --kind K --keep N | feed --kind K <appcast.xml> <tag>..." ;;
esac
