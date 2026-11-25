#!/bin/sh
# Reads the expiry date of the Developer ID certificate stored as a base64 .p12 secret and reports
# ONLY the whole days left and the date. Used by the weekly cert-expiry workflow.
#
# Usage (secrets only through the environment, never arguments):
#   P12_BASE64=<base64 .p12> P12_PASSWORD=<password> scripts/ci/cert-expiry.sh
#
# Output on stdout (nothing else, never the secret, the password or the certificate):
#   expires_in_days=N      whole days left; negative once expired
#   expires_on=YYYY-MM-DD  the date (UTC)
# When $GITHUB_OUTPUT is set the same values are appended as `days=` and `expires=`.
#
# Exit codes: 0 valid; 1 already expired (the numbers are still printed, so a reminder can say so);
#             2 unreadable: empty secret, bad base64, wrong password or no certificate (no numbers).
# Runs on macOS (BSD date, the system openssl that reads Apple's .p12 format).
# CERT_EXPIRY_NOW (epoch seconds) replaces "now"; tests use it.
set -eu

fail() { echo "error: $*" >&2; exit 2; }

[ -n "${P12_BASE64:-}" ] || fail "P12_BASE64 is empty (is the secret set for this environment?)"
[ -n "${P12_PASSWORD:-}" ] || fail "P12_PASSWORD is empty"

umask 077
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cert-expiry.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

printf '%s' "${P12_BASE64}" | base64 -D > "${WORK}/cert.p12" 2>/dev/null || fail "P12_BASE64 is not valid base64"
[ -s "${WORK}/cert.p12" ] || fail "P12_BASE64 decoded to an empty file"

/usr/bin/openssl pkcs12 -in "${WORK}/cert.p12" -passin env:P12_PASSWORD -nokeys -clcerts \
    -out "${WORK}/cert.pem" >/dev/null 2>&1 || fail "could not open the .p12 (wrong password, or not a .p12)"
[ -s "${WORK}/cert.pem" ] || fail "no certificate found in the .p12"

END="$(/usr/bin/openssl x509 -in "${WORK}/cert.pem" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
[ -n "${END}" ] || fail "could not read the certificate's expiry date"
END_EPOCH="$(TZ=UTC date -j -f "%b %e %T %Y %Z" "${END}" +%s 2>/dev/null)" || fail "could not parse the expiry date '${END}'"

NOW="${CERT_EXPIRY_NOW:-$(date +%s)}"
DIFF=$((END_EPOCH - NOW))
if [ "${DIFF}" -ge 0 ]; then
    DAYS=$((DIFF / 86400))
else
    DAYS=$(( -((-DIFF + 86399) / 86400) ))      # round away from zero: expired is always at most -1
fi
ON="$(TZ=UTC date -j -f "%s" "${END_EPOCH}" +%Y-%m-%d)"

echo "expires_in_days=${DAYS}"
echo "expires_on=${ON}"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    { echo "days=${DAYS}"; echo "expires=${ON}"; } >> "${GITHUB_OUTPUT}"
fi

if [ "${DIFF}" -lt 0 ]; then
    echo "error: the certificate expired on ${ON}" >&2
    exit 1
fi
