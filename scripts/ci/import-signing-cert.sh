#!/bin/sh
# Imports a Developer ID certificate into a TEMPORARY keychain for a CI job, and removes it again.
#
# Usage:
#   import-signing-cert.sh import     # create + unlock the keychain, import the .p12, add to search list
#   import-signing-cert.sh cleanup    # delete the keychain and restore the search list
#
# Environment:
#   CERT_P12_BASE64    the .p12 file, base64 encoded (import only; a secret)
#   CERT_PASSWORD      the .p12 password (import only; a secret)
#   KEYCHAIN_PATH      keychain file to use. Default: ${RUNNER_TEMP:-$TMPDIR}/release-signing.keychain-db
#   NO_SEARCH_LIST     set to 1 to leave the user's keychain search list alone (used by tests)
#
# The keychain password is random, kept only in a 0600 file next to the keychain, and never printed.
# Nothing here prints the certificate, its password or the keychain password.
set -eu

die() { echo "error: $*" >&2; exit 1; }

COMMAND="${1:-}"
BASE="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
KEYCHAIN="${KEYCHAIN_PATH:-${BASE%/}/release-signing.keychain-db}"
STATE="${KEYCHAIN}.state"          # holds the keychain password and the previous search list

list_keychains() { security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//'; }

case "${COMMAND}" in
    import)
        [ -n "${CERT_P12_BASE64:-}" ] || die "CERT_P12_BASE64 is empty (is the secret set for this environment?)"
        [ -n "${CERT_PASSWORD:-}" ] || die "CERT_PASSWORD is empty"
        [ ! -e "${KEYCHAIN}" ] || die "${KEYCHAIN} already exists; run cleanup first"

        umask 077
        PASSWORD="$(openssl rand -hex 24)"
        P12="$(mktemp "${BASE%/}/cert.XXXXXX")"
        trap 'rm -f "${P12}"' EXIT
        printf '%s' "${CERT_P12_BASE64}" | base64 -D > "${P12}"

        # Remember the current search list so cleanup can put it back exactly.
        { printf '%s\n' "${PASSWORD}"; list_keychains; } > "${STATE}"

        security create-keychain -p "${PASSWORD}" "${KEYCHAIN}"
        security set-keychain-settings -lut 21600 "${KEYCHAIN}"      # stay unlocked for 6 hours
        security unlock-keychain -p "${PASSWORD}" "${KEYCHAIN}"
        security import "${P12}" -f pkcs12 -k "${KEYCHAIN}" -P "${CERT_PASSWORD}" \
            -T /usr/bin/codesign -T /usr/bin/security >/dev/null
        # Let codesign use the key without a prompt (there is nobody to click Allow).
        security set-key-partition-list -S apple-tool:,apple: -s -k "${PASSWORD}" "${KEYCHAIN}" >/dev/null

        if [ "${NO_SEARCH_LIST:-0}" != "1" ]; then
            # Our keychain first, then the existing ones. One parameter per line, because keychain
            # paths may contain spaces and word splitting would break them.
            list_keychains > "${STATE}.list"
            set -- "${KEYCHAIN}"
            while IFS= read -r line; do
                [ -n "${line}" ] && set -- "$@" "${line}"
            done < "${STATE}.list"
            rm -f "${STATE}.list"
            security list-keychains -d user -s "$@"
        fi
        echo "Imported the signing certificate into a temporary keychain."
        ;;

    cleanup)
        if [ -f "${STATE}" ] && [ "${NO_SEARCH_LIST:-0}" != "1" ]; then
            tail -n +2 "${STATE}" > "${STATE}.list"
            set --
            while IFS= read -r line; do
                [ -n "${line}" ] && set -- "$@" "${line}"
            done < "${STATE}.list"
            rm -f "${STATE}.list"
            [ $# -gt 0 ] && { security list-keychains -d user -s "$@" || true; }
        fi
        security delete-keychain "${KEYCHAIN}" 2>/dev/null || true
        rm -f "${STATE}" "${KEYCHAIN}"
        echo "Removed the temporary signing keychain."
        ;;

    *) die "usage: import-signing-cert.sh import|cleanup" ;;
esac
