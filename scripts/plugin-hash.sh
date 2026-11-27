#!/bin/sh
# Prints a hash of the Stream Deck plugin's code as committed at HEAD (issue #64, spec: docs/versioning-spec.md V17).
# Two commits with the same hash ship the same plugin, whatever version number its manifest carries, so the
# release build can keep the plugin's version when the plugin didn't change.
#
# Usage: scripts/plugin-hash.sh        (run inside the git repository)
#
# Counts every tracked file under streamdeck/ except editor settings (.idea/, .vscode/, .gitignore). In the
# manifest the top-level "Version" line (one tab of indent) is replaced by a fixed text first, so changing the
# version number alone doesn't change the hash. Reads HEAD from git, not the working copy, so a stamped manifest
# can't change the answer. Prints one sha256, nothing else.
set -eu

die() { echo "error: $*" >&2; exit 1; }
git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"

TAB="$(printf '\t')"
{
    git ls-tree -r HEAD -- streamdeck | while IFS="${TAB}" read -r meta path; do
        case "${path}" in
            streamdeck/.idea/*|streamdeck/.vscode/*|streamdeck/.gitignore) continue ;;
            streamdeck/*.sdPlugin/manifest.json)
                content="$(git show "HEAD:${path}" | sed "s/^${TAB}\"Version\": \"[0-9.]*\",/${TAB}\"Version\": \"-\",/" | shasum -a 256 | cut -d' ' -f1)"
                printf '%s %s\n' "${content}" "${path}" ;;
            *)
                # `<mode> blob <object id>`: the blob id already identifies the content.
                set -- ${meta}
                printf '%s %s\n' "$3" "${path}" ;;
        esac
    done
} | LC_ALL=C sort | shasum -a 256 | cut -d' ' -f1
