# Signing certificate expiry reminder

Workflow: `.github/workflows/cert-expiry.yml`. Scripts: `scripts/ci/cert-expiry.sh`,
`scripts/ci/remind-expiry.sh`. Tests: `DeFeedbackHostTests/CertExpiryTests.swift`. Part of issue #3.

## Model

The Developer ID certificate that signs releases expires, and when it does releases can no longer be
signed. Every Monday (14:00 UTC), and whenever run by hand, the `cert-expiry` workflow reads the
certificate's expiry date from the `DEVELOPER_ID_CERT_P12` secret and, when **15 days or fewer** are
left, opens a GitHub issue labelled `certificate-expiry`, assigned to the repository owner, so GitHub
emails them. Later runs update that issue instead of opening another. An expired certificate gets an
"expired" issue.

The work is split across two jobs so no job has more access than it needs:

| Job | Sees | Does |
|---|---|---|
| `check` (environment `release`) | the certificate secrets | reads the expiry, outputs only the whole days left and the date |
| `remind` | no secrets; `issues: write` | opens or updates the issue |

## Rules

| Id | Rule | Test |
|----|------|------|
| C1 | The expiry is read from the `.p12` and only the whole days left (negative once expired) and the date (`YYYY-MM-DD`, UTC) are reported. | `reportsDaysAndDate` |
| C2 | Neither the secret, its password nor the certificate is ever printed. | `neverPrintsTheSecret` |
| C3 | An empty or undecodable secret, a wrong password or a file with no certificate fails with a clear message and reports no numbers (exit 2). | `unreadableSecretsFailClearly` |
| C4 | An expired certificate still reports its numbers (negative days) but fails (exit 1), so the reminder can say it expired. | `expiredCertificateStillReports` |
| C5 | While more than the threshold days are left, nothing is opened or changed. | `noReminderAboveThreshold` |
| C6 | At or below the threshold exactly one `certificate-expiry` issue is opened, assigned to the owner, with the date and days in its title. | `opensOneIssue` |
| C7 | A later run updates the open issue (title and text) and does not open a second one. | `updatesTheExistingIssue` |
| C8 | An expired certificate gets an "expired on …" title; bad arguments are rejected without calling `gh`. | `expiredWording`, `badArgumentsAreRejected` |
| C9 | The workflow runs weekly and by hand; only `check` sees the secrets (as environment values); `remind` has `issues: write` and no secrets. | `workflowSplitsSecretsFromIssues` |

## Renewing the certificate

1. In the Apple Developer site (Certificates, IDs & Profiles) create a new **Developer ID Application**
   certificate, download it and install it in Keychain Access (with its private key, which stays on
   the Mac that made the request).
2. Export it with its private key as a `.p12` with a password, and base64 encode it
   (`base64 -i cert.p12`).
3. Replace the `DEVELOPER_ID_CERT_P12` and `DEVELOPER_ID_CERT_PASSWORD` secrets of the `release`
   environment (see `docs/release.md`). Nothing else changes: the DMG script finds the identity by the
   team id in the project, not by a name stored in a variable.
4. Run the **Release** workflow as a dry run to confirm signing and notarization still work.
5. Run **cert-expiry** by hand; it should report the new date. Close the reminder issue.

Builds already signed and notarized with a timestamp stay valid after the certificate expires; only
new signing stops.

## Testing it for real

After this is merged: Actions › **cert-expiry** › Run workflow with `threshold_days` set to `9999`.
Expect a green run and one issue titled "Developer ID certificate expires on … (N days left)",
assigned to the owner, labelled `certificate-expiry`. Close it afterwards. The first scheduled run is
the next Monday at 14:00 UTC.

## Notes

- GitHub disables scheduled workflows in a public repository after 60 days without activity; a
  commit or a manual run turns them back on.
- Apple also emails the account holder before a Developer ID certificate expires. This reminder is
  the project's own, so it reaches the owner even if that email is missed.
- Not covered: the notary API key (App Store Connect keys don't expire unless revoked) and the
  Sparkle signing key (it never expires; losing it is the risk, so keep an offline backup).
