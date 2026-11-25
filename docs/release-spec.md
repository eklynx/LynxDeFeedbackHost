# Release workflow: spec

Source of truth in code: `.github/workflows/release.yml`, `scripts/create-dmg.sh`,
`scripts/notarytool-submit.sh`, `scripts/ci/import-signing-cert.sh`, `scripts/ci/verify-release.sh`,
`scripts/publish-update.sh`. Tests: `DeFeedbackHostTests/ReleaseScriptTests.swift`. Origin: issue #3
(delivered in several PRs). Setup and how to run: `docs/release.md`. Version numbers: `docs/versioning-spec.md`.

## Model

A release is started by hand (Actions › Release › Run workflow) and does, in order:

```text
guard (main only, tag must not exist) -> unit tests
  -> version from tags (compute-version.sh)
  -> archive (the install-only run-script phases sign with Developer ID, build the DMG, notarize)
  -> verify (stapled, Gatekeeper accepts, the app inside has the expected version and build number)
  -> dry run? stop here and keep the DMG with the run
  -> otherwise: tag vX.Y.Z + GitHub Release with the DMG, then the Sparkle appcast item on gh-pages
```

Signing and notary secrets live only in the `release` environment (limited to `main`) and are
removed from the runner at the end of the job even when a step fails.

## Rules

| Id | Rule | Test |
|----|------|------|
| R1 | A release is manual only (no pull request, push or schedule trigger), runs only from `main`, refuses a tag that already exists, runs one at a time, and its secrets come from the `release` environment. | `workflowIsManualAndGuarded` |
| R2 | The version and build number come from `compute-version.sh`; the app inside the DMG must report exactly them, or the release stops before publishing. | `verify-release.sh` (checked on the first real run) |
| R3 | The DMG is Developer ID signed, notarized and stapled before anything is published. Notarization counts only if Apple's status is `Accepted`; anything else fails the run. | `notaryRejectionFails`; `verify-release.sh` |
| R4 | Notarization uses the App Store Connect API key when `NOTARY_KEY_PATH`, `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID` are all set, otherwise the keychain profile (default `DeFeedbackHost-Notary`). Setting only some of the three is an error. | `notaryUsesApiKey`, `notaryUsesProfile`, `notaryRejectsPartialKey` |
| R5 | The certificate is imported into a temporary keychain with a random password; secrets are only ever passed as environment values (never on a command line or printed); the keychain, its password file and the decoded certificate are removed, also after a failure; missing secrets fail with a clear message. | `certificateImportAndCleanup`, `importNeedsSecrets`, `secretsOnlyInEnv` |
| R6 | A dry run builds, signs, notarizes and verifies, keeps the DMG as a run artifact, and publishes nothing: no tag, no GitHub Release, no appcast change. | `dryRunPublishesNothing` |
| R7 | The tag is created on the commit that was tested (`gh release create --target`), even if `main` moved while the release ran. | `publishTagsOnTestedCommit` |
| R8 | The appcast gets one new item on the release channel, and the `gh-pages` push retries after rebasing so a parallel appcast publish can't clobber it. | `UpdateScriptTests.publishTagsChannels` (channel item); push retry checked on the first real run |

## Manual checklist (needs the real secrets)

1. Add the secrets (see `docs/release.md`).
2. Run the workflow with **dry run** on. Expect a green run and a DMG attached to it; open it, the
   app should launch without a Gatekeeper warning on another Mac.
3. Run it for real (patch). Expect the tag, the GitHub Release with the DMG, and a new item in
   https://eklynx.github.io/LynxDeFeedbackHost/appcast.xml.
4. Install the previous build, enable update checking, and confirm it offers the new version
   (`docs/updates-spec.md` manual checklist).

## Notes

- The Xcode "Notorize DMG" phase now just runs `scripts/create-dmg.sh` (it used to hold an inline
  copy of it), so Xcode, a terminal and CI run the same code.
- If the appcast push fails after the Release was created, the Release exists without a feed
  entry. Recovery is in `docs/release.md`.
