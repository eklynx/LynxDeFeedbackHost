#!/bin/sh
# Opens (or updates) ONE GitHub issue when the signing certificate is close to expiry. The issue is
# assigned to the repository owner, so GitHub emails them. Used by the weekly cert-expiry workflow.
#
# Usage:
#   scripts/ci/remind-expiry.sh --days N --expires YYYY-MM-DD --threshold DAYS --repo OWNER/NAME --assignee USER
#
# Holds no secret: the days and date come from scripts/ci/cert-expiry.sh, and only the gh CLI with a
# token that may write issues is needed. At most one reminder issue is open at a time: later runs
# update it. Nothing happens while more than --threshold days are left.
set -eu

DAYS=""; EXPIRES=""; THRESHOLD=""; REPO=""; ASSIGNEE=""
LABEL="certificate-expiry"

die() { echo "remind-expiry.sh: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --days|--expires|--threshold|--repo|--assignee)
            [ $# -ge 2 ] || die "$1 needs a value"
            case "$1" in
                --days) DAYS="$2" ;; --expires) EXPIRES="$2" ;; --threshold) THRESHOLD="$2" ;;
                --repo) REPO="$2" ;; --assignee) ASSIGNEE="$2" ;;
            esac
            shift 2 ;;
        *) die "unknown option: $1" ;;
    esac
done

[ -n "${DAYS}" ] || die "--days is required"
[ -n "${EXPIRES}" ] || die "--expires is required"
[ -n "${THRESHOLD}" ] || die "--threshold is required"
[ -n "${REPO}" ] || die "--repo is required"
[ -n "${ASSIGNEE}" ] || die "--assignee is required"
echo "${DAYS}" | grep -E -q '^-?[0-9]+$' || die "--days must be a whole number"
echo "${THRESHOLD}" | grep -E -q '^[0-9]+$' || die "--threshold must be a whole number"
echo "${EXPIRES}" | grep -E -q '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || die "--expires must be YYYY-MM-DD"
command -v gh >/dev/null 2>&1 || die "the gh CLI is not installed"

if [ "${DAYS}" -gt "${THRESHOLD}" ]; then
    echo "the certificate expires on ${EXPIRES}, in ${DAYS} days: more than ${THRESHOLD}, no reminder"
    exit 0
fi

if [ "${DAYS}" -lt 0 ]; then
    TITLE="Developer ID certificate expired on ${EXPIRES}"
    LEAD="The Developer ID Application certificate **expired on ${EXPIRES}**. New releases cannot be signed until it is replaced."
else
    TITLE="Developer ID certificate expires on ${EXPIRES} (${DAYS} days left)"
    LEAD="The Developer ID Application certificate expires on **${EXPIRES}**, in **${DAYS} days**. Release signing stops working then; builds already signed with a timestamp stay valid."
fi
BODY="${LEAD}

To renew, follow **Renewing the certificate** in [docs/cert-expiry.md](../blob/main/docs/cert-expiry.md): create a new Developer ID Application certificate, export it with its private key as a .p12, and replace the \`DEVELOPER_ID_CERT_P12\` and \`DEVELOPER_ID_CERT_PASSWORD\` secrets of the \`release\` environment. Then run a release as a dry run to confirm.

This issue is kept up to date by the \`cert-expiry\` workflow and can be closed once the certificate is renewed."

gh label create "${LABEL}" --repo "${REPO}" --color B60205 --description "The signing certificate is close to expiry" >/dev/null 2>&1 || true
EXISTING="$(gh issue list --repo "${REPO}" --label "${LABEL}" --state open --json number --jq '.[0].number' 2>/dev/null || true)"
if [ -n "${EXISTING}" ]; then
    gh issue edit "${EXISTING}" --repo "${REPO}" --title "${TITLE}" --body "${BODY}" >/dev/null || die "could not update issue #${EXISTING}"
    echo "updated issue #${EXISTING}: ${TITLE}"
else
    gh issue create --repo "${REPO}" --title "${TITLE}" --body "${BODY}" --label "${LABEL}" --assignee "${ASSIGNEE}" >/dev/null || die "could not create the issue"
    echo "opened an issue: ${TITLE}"
fi
