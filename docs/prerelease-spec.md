# Pre-releases: spec

Source of truth in code: `.github/workflows/prerelease.yml`, the shared `.github/workflows/build-and-publish.yml`
and `.github/workflows/prune-builds.yml`, `scripts/compute-version.sh`, `scripts/ci/prune-builds.sh`,
`scripts/publish-update.sh`. Tests: `DeFeedbackHostTests/PrereleaseScriptTests.swift` and
`VersionScriptTests.swift`. Origin: GitHub issue #3. Versions: `docs/versioning-spec.md`. The other builds:
`docs/release-spec.md`, `docs/nightly-spec.md`.

## Model

A **pre-release** is a build we start by hand with features or fixes that are developed but not tested
enough for a full release. It is signed and notarized like a release and published as a GitHub
**pre-release** (never "latest") plus an appcast item on the `prerelease` update channel: only users who
chose Pre-release (or Nightly) in Settings are offered it. The newest 10 are kept.

```text
prerelease.yml (Run workflow: bump, label, dry_run, keep)
  build   build-and-publish.yml kind=prerelease   (guard, tests, sign, notarize, verify, release, appcast)
  prune   prune-builds.yml kind=prerelease        keep the newest 10: appcast first, then releases + tags
```

Version example: the latest release is `v0.1.2`; with `bump = minor` and `label = beta` the first
pre-release is `0.2.0-beta.1` (tag `v0.2.0-beta.1`), then `0.2.0-beta.2`, ... until `v0.2.0` is released.
The app's own version is plain `0.2.0`; the build number is the UTC time stamp, so Sparkle orders
pre-releases correctly against nightlies and releases.

## Rules

| Id | Rule | Test |
|----|------|------|
| PRE1 | A pre-release is started by hand only (no pull request, push or schedule), from `main`, one build at a time (it shares the release's concurrency group), and the caller reads no secret. | `prereleaseWorkflowIsManualAndShared` |
| PRE2 | Its version is the next release's `X.Y.Z` plus `-<label>.<N>`; N counts up per release and label (numerically) and restarts at 1 for another label or release. | `firstPrerelease`, `prereleaseNumbering`, `prereleaseWithNoTags` |
| PRE3 | Its tag is `v<full version>`, its channel `prerelease`, its marketing version plain `X.Y.Z`, its build number the UTC stamp. | `firstPrerelease` |
| PRE4 | Pre-release tags never count as the latest release (so they can't move release numbers), and a pre-release does not stop that night's nightly. | `prereleaseTagsDontMoveTheRelease`, `nightlyIgnoresPrereleaseTags` |
| PRE5 | It is published as a GitHub pre-release, not latest, with generated notes, and an appcast item on the `prerelease` channel whose version text is the full version. | `prereleaseIsPublishedAsAPrerelease` |
| PRE6 | The label is lowercase letters only; an existing tag is refused by the shared build's guard. | `prereleaseLabelIsValidated` |
| PRE7 | Only the newest `keep` (default 10) pre-releases are kept, ordered by date; the older ones are removed from `appcast.xml` and that is pushed BEFORE their GitHub Releases and tags are deleted. `keep` must be 1 or more. | `selectPrereleasesBeyondTheNewest`, `selectValidatesItsArguments`, `feedRemovesNamedPrereleases`, `feedBeforeReleases` (nightly spec) |
| PRE8 | Pruning pre-releases only ever touches `v<X.Y.Z>-<label>.<N>` tags and items on the `prerelease` channel: releases, nightlies and anything else are never listed or removed, a wrong tag is refused, and nothing changes after a refusal. | `selectKeepsKindsApart`, `feedProtectsEverythingElse` |
| PRE9 | A dry run builds, signs and notarizes but publishes and prunes nothing; prune runs only after a successful build. | `prereleaseDryRunAndPrune` |

## Running it

Actions › **Pre-release** › Run workflow, branch `main`. Choose which release it leads to (`bump`,
default minor) and a `label` (default `beta`; `rc` etc. also work). **Tick dry run the first time.**
It needs the same `release` environment and secrets as a release (`docs/release.md`).

## Manual checklist (needs the real secrets)

1. Run **Nightly** with force and dry run ticked: proves the pruning that this change moved into a shared workflow.
2. Run **Pre-release** with dry run ticked: expect a green run, a DMG named `DeFeedbackHost-X.Y.Z-beta.1.dmg`
   attached to it, and the prune job saying nothing is removed.
3. Run it for real: expect the tag `vX.Y.Z-beta.1`, a GitHub **pre-release** (not latest), a `prerelease`
   item in the appcast, an app set to **Pre-release** being offered it, and an app set to **Release** not.
4. After more than 10 exist, a run's prune job removes only the oldest pre-releases (releases, tags and
   appcast items), leaving releases and nightlies alone.

## Notes

- The appcast shows the full version (`0.2.0-beta.1`), so two betas of the same release are told apart.
- When `v0.2.0` is released, the earlier `0.2.0-beta.N` pre-releases sort lower by build time and stay
  until pruned.
- A pre-release can only be built from `main`: the `release` environment (and so the signing secrets)
  is limited to `main`.
