# Making a release

Workflow: `.github/workflows/release.yml` (Actions › **Release** › Run workflow). Rules:
`docs/release-spec.md`. Part of issue #3.

## One-time setup

1. **Create the environment.** Settings › Environments › New environment, name it exactly
   `release`. Under *Deployment branches and tags* choose *Selected branches and tags* and add
   `main`, so nothing else can ever read the secrets. (Optionally add yourself as a required
   reviewer to approve each run.)
2. **Add these secrets to that environment** (Environment secrets, not repository secrets):

   | Secret | What it is | How to get it |
   |---|---|---|
   | `DEVELOPER_ID_CERT_P12` | Your *Developer ID Application* certificate with its private key, base64 | Keychain Access › My Certificates › right-click the certificate › Export as `.p12` with a password, then `base64 -i cert.p12 \| pbcopy` |
   | `DEVELOPER_ID_CERT_PASSWORD` | The password you set when exporting | |
   | `NOTARY_KEY_P8` | The App Store Connect API key file, pasted as text | App Store Connect › Users and Access › Integrations › App Store Connect API › generate a key (Developer access is enough) and download `AuthKey_XXXX.p8` (it can be downloaded once). Paste the whole file contents |
   | `NOTARY_KEY_ID` | That key's ID | Same page |
   | `NOTARY_ISSUER_ID` | The issuer ID shown at the top of that page | Same page |
   | `SPARKLE_ED_PRIVATE_KEY` | The private half of the Sparkle update signing key | `generate_keys --account DeFeedbackHost -x <file>` from Sparkle's tools, then paste the file contents. Keep an offline backup as well |

3. Delete the exported `.p12` and `.p8` files from your machine once they are stored (keep an
   offline backup of the certificate and keys somewhere safe).

## Running a release

- Actions › Release › **Run workflow**, branch `main`, pick the bump (`patch` by default), and
  leave *dry run* off for a real release.
- **First time, or after changing any signing setup: tick *dry run*.** It does everything except
  publish, and attaches the DMG to the run so you can try it.
- The version is computed from git tags (`docs/versioning-spec.md`); you never type one.

## Nightly builds

A nightly is built every night at 03:00 UTC when `main` has changed (Actions › **Nightly**, which can
also be run by hand). It is published as a GitHub pre-release and to the **Nightly** update channel,
and only the newest 7 are kept. Rules, the manual checklist and recovery: `docs/nightly-spec.md`.
It uses the same `release` environment and secrets as a release.

## Pre-releases

A pre-release (a build we start by hand that is not tested enough for a full release) is made with
Actions › **Pre-release**; it goes to the **Pre-release** update channel and the newest 10 are kept.
Version, rules and checklist: `docs/prerelease-spec.md`. It uses the same `release` environment and
secrets as a release.

## Renewing the certificate

The `cert-expiry` workflow opens an issue when the certificate is close to expiry. The renewal steps
are in `docs/cert-expiry.md`.

## When something fails

- **Notarization not accepted:** the log shows Apple's verdict. Get the details with
  `xcrun notarytool log <submission-id> --key AuthKey_XXXX.p8 --key-id <id> --issuer <issuer>`.
- **A step failed before "Create the release":** nothing was published; fix and run again.
- **The Release exists but the appcast push failed:** the DMG is public but no update is offered
  yet. Check out `gh-pages`, run `scripts/publish-update.sh --dmg <the released DMG> --version <v> --build <n> --channel release --site-dir <gh-pages checkout>`
  (with `SPARKLE_ED_PRIVATE_KEY` set), then commit and push `appcast.xml`. The workflow refuses
  to run again for that version because the tag exists.
- **To redo a release completely:** delete the GitHub Release and the tag, remove its item from
  `appcast.xml` on `gh-pages`, then run the workflow again.
