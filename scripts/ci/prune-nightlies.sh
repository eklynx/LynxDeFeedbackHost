#!/bin/sh
# Keeps the nightly builds to the newest N: picks the old ones, and removes their items from the
# Sparkle appcast so the feed never points at a deleted download.
#
# Usage:
#   gh release list --json tagName,createdAt --jq '.[]|[.tagName,.createdAt]|@tsv' \
#       | scripts/ci/prune-nightlies.sh select --keep 7        # prints the tags to delete
#   scripts/ci/prune-nightlies.sh feed <appcast.xml> <tag>...  # removes those items from the feed
#
# `select` reads `tag<TAB>createdAt` lines on stdin and prints the `nightly-*` tags beyond the
# newest N by date, oldest last. Tags that don't start with `nightly-` are never listed.
#
# `feed` removes only items that are on the `nightly` channel AND whose download URL is under
# /releases/download/<tag>/ for a tag starting `nightly-`, so release and pre-release items can't be
# removed by a wrong argument. It leaves the file untouched (byte for byte) when nothing matches.
#
# Order matters for the caller: push the changed feed first, delete the GitHub Releases after.
set -eu

die() { echo "error: $*" >&2; exit 1; }

COMMAND="${1:-}"
[ $# -gt 0 ] && shift

case "${COMMAND}" in
    select)
        KEEP=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --keep) KEEP="${2:?--keep needs a number}"; shift 2 ;;
                *) die "unknown option: $1" ;;
            esac
        done
        case "${KEEP}" in ''|*[!0-9]*) die "--keep must be a whole number of 1 or more" ;; esac
        [ "${KEEP}" -ge 1 ] || die "--keep must be 1 or more (refusing to delete every nightly)"
        TAB="$(printf '\t')"
        awk -F"${TAB}" '$1 ~ /^nightly-/ && NF >= 2' \
            | sort -t "${TAB}" -k2,2r \
            | tail -n +"$((KEEP + 1))" \
            | cut -f1
        ;;

    feed)
        FEED="${1:?usage: prune-nightlies.sh feed <appcast.xml> <tag>...}"
        shift
        [ -f "${FEED}" ] || die "${FEED} not found"
        [ $# -gt 0 ] || { echo "removed 0 item(s) (no tags given)"; exit 0; }
        for tag in "$@"; do
            case "${tag}" in nightly-*) ;; *) die "refusing to remove '${tag}': only nightly-* tags may be pruned" ;; esac
        done
        FEED="${FEED}" python3 -I - "$@" <<'PY'
import os, re, sys

path = os.environ["FEED"]
tags = sys.argv[1:]
text = open(path, encoding="utf-8").read()
removed = 0

def drop(match):
    global removed
    item = match.group(0)
    if "<sparkle:channel>nightly</sparkle:channel>" not in item:
        return item                      # only the nightly channel is ever eligible
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

    *) die "usage: prune-nightlies.sh select --keep N | feed <appcast.xml> <tag>..." ;;
esac
