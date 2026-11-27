# Nightly builds: spec

Source of truth in code: `.github/workflows/nightly.yml`, the shared `.github/workflows/build-and-publish.yml`,
`.github/workflows/prune-builds.yml` (shared with the pre-release), `scripts/ci/should-build-nightly.sh`, `scripts/ci/prune-builds.sh`, `scripts/compute-version.sh`,
`scripts/publish-update.sh`. Tests: `DeFeedbackHostTests/NightlyScriptTests.swift` and
`ReleaseScriptTests.swift`. Origin: GitHub issue #3. Versions: `docs/versioning-spec.md`. Release:
`docs/release-spec.md`.

## Model

Every night at 03:00 UTC, if `main` has new commits since the last nightly or release, a **nightly**
is built, Developer ID signed, notarized and published as a GitHub **pre-release**, with an appcast item
on the `nightly` update channel (only users who chose Nightly in Settings are offered it). Only the
newest 7 nightlies are kept. A nightly and a release use the very same build (`build-and-publish.yml`);
only the version, the tag, the channel and the release notes differ.

```text
nightly.yml (03:00 UTC, or Run workflow)
  decide   should-build-nightly.sh: main moved since the newest nightly / release tag?  (force overrides)
  build    build-and-publish.yml kind=nightly   (guard, tests, sign, notarize, verify, release, appcast)
  prune    prune-builds.yml kind=nightly: keep the newest N (7): take the older ones out of
           appcast.xml and push it, THEN delete their GitHub Releases and tags
```

## Rules

| Id | Rule | Test |
|----|------|------|
| N1 | The nightly runs daily at 03:00 UTC and by hand, never for a pull request, only from `main`, and never at the same time as a release (one shared concurrency group). | `nightlyTriggers` |
| N2 | A nightly is skipped when `main` is at the commit of the newest `nightly-*` tag or of the newest release tag; it is built when there is no earlier nightly or release, or `main` has new commits. A shallow clone without tags fails instead of guessing. | `firstNightlyBuilds`, `sameCommitAsNightlySkips`, `sameCommitAsReleaseSkips`, `newCommitsBuild`, `shallowCloneFails`, `decisionGoesToGithubOutput` |
| N3 | `force` builds even when nothing changed. | `forceBuilds` |
| N4 | A nightly is the latest release version with patch + 1, plus `-<UTC stamp>.<7-char hash>`; its tag is `nightly-<full version>`, its channel `nightly`, its marketing version plain `X.Y.Z` and its build number the stamp. | `nightlyVersionShape` |
| N5 | A nightly is published as a GitHub pre-release, never "latest", with the fixed note "Automatic nightly build of main at <commit>. Not a release." followed by the changes since the previous nightly (V20 to V22); a release gets the changes since the previous release. | `nightlyReleaseNotes`, `changelogSinceThePreviousBuild` |
| N6 | The DMG is named with the full version (`DeFeedbackHost-0.1.4-<stamp>.<hash>.dmg`); without `DMG_VERSION` the marketing version is used as before. | `dmgNamedWithTheFullVersion` |
| N7 | Only the newest `keep` (default 7) nightlies are kept, ordered by date. The older ones are removed from `appcast.xml` and that is pushed BEFORE their GitHub Releases and tags are deleted, so the feed never points at a deleted file. `keep` must be 1 or more. | `selectKeepsTheNewest`, `selectRefusesBadKeep`, `feedRemovesNamedNightlies`, `feedBeforeReleases` |
| N8 | Pruning only ever touches `nightly-*` releases and items on the `nightly` channel: releases, pre-releases and any other tag are never listed or removed, a wrong argument is refused, and a feed with nothing to remove is left byte for byte unchanged. | `selectIgnoresOtherTags`, `feedProtectsReleases` |
| N9 | A dry run builds, signs, notarizes and verifies but publishes and prunes nothing (it only prints what pruning would remove); pruning runs only after a successful build and never sees the signing secrets. | `dryRunAndPruneRules` |
| N10 | Release and nightly are thin callers of one shared build; neither caller reads a secret, and the release behaves as before. | `sharedBuild`, `workflowIsManualAndGuarded` |

## Running it

- Actions › **Nightly** › Run workflow. Tick **force** to build when nothing changed, **dry run** to
  publish nothing, and set **keep** to change how many nightlies stay (default 7).
- A failed scheduled run is reported by GitHub's failed-run email (the person who last edited the
  schedule). One missed night is harmless; the next run builds whatever `main` is by then.

## Manual checklist (needs the real secrets)

1. Run **Release** with *dry run* ticked: proves the shared build still works for releases.
2. Run **Nightly** with *force* and *dry run* ticked: expect a green run, a DMG named with the full
   version attached to it, and the prune job saying nothing is removed.
3. Run **Nightly** with *force* once for real: expect a GitHub pre-release `nightly-…` (not marked
   latest), an item with `<sparkle:channel>nightly</sparkle:channel>` in the appcast, an app set to
   **Nightly** being offered it, and an app set to **Release** not offered it.
4. After more than 7 nightlies exist, a run's prune job removes only the oldest ones (their releases,
   tags and appcast items), and the release and pre-release items are untouched.

## Notes

- The nightly version is based on the latest release tag, so a nightly after `v0.1.3` is
  `0.1.4-<stamp>.<hash>`. When `v0.1.4` is released, those nightlies sort lower, which is correct.
- Releases and nightlies share one concurrency group because both push `gh-pages`. GitHub keeps one
  waiting run per group, so two runs queued behind a running build can replace each other; in
  practice a daily nightly and a manual release don't collide.
