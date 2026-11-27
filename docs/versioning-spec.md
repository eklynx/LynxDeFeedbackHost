# Versioning: spec

Source of truth in code: `scripts/compute-version.sh`. Tests: `DeFeedbackHostTests/VersionScriptTests.swift`
(rules V1–V10). Origin: GitHub issue #3.

## Model

Versions come from **git tags only**. There is no version file and nothing is committed back, so a
release creates no bump commits and no merge conflicts. Three different values are derived, because
Apple and Sparkle constrain what each can hold:

| Value | Example | Used for |
|---|---|---|
| Marketing version (`marketing_version`) | `0.1.3` | `CFBundleShortVersionString`. Always plain `X.Y.Z`: Apple's field can't hold a suffix. |
| Full version (`full_version`) | `0.1.3` or `0.1.3-20261125030000.ab12cd3` | Names artifacts, tags, release titles and update messages. |
| Build number (`build_number`) | `20261125030000` | `CFBundleVersion` and `sparkle:version`. Sparkle orders builds by it, so it must rise across every workflow; the UTC build time does. |

Three kinds of build: a **release** (started by us), a **pre-release** (started by us, not tested enough for a
release) and a **nightly** (automatic, when `main` changed). Nightlies carry a `nightly-` tag and pre-releases a
`vX.Y.Z-<label>.<N>` tag, never a plain `vX.Y.Z` tag, so neither can move the release number.

## Rules

| Id | Rule | Test |
|----|------|------|
| V1 | The latest version is the highest tag by number, not text (`0.10.0` is newer than `0.9.0`). | `latestTagIsNumeric` |
| V2 | Both `vX.Y.Z` and bare `X.Y.Z` tags count (the first releases were tagged without the `v`). New tags are written with the `v`. | `bareAndPrefixedTags` |
| V3 | A release bumps the patch part by default; `VERSION_BUMP=minor` or `major` bumps that part and resets the lower ones. | `releaseBumps` |
| V4 | A nightly is the latest version with patch + 1, followed by `-<UTC stamp>.<7-char hash>`; its tag is `nightly-<full version>`. The bump input is ignored. | `nightlyVersion` |
| V5 | Nightly tags, pre-release tags (`v1.1.0-beta.1`) and other non-`vX.Y.Z` tags never count as the latest version. | `nightlyAndPrereleaseTagsIgnored` |
| V6 | With no version tag at all, a release is `1.0.0` itself and a nightly is `1.0.1-…`. | `noTags` |
| V7 | `marketing_version` is plain `X.Y.Z`; `build_number` is digits only (the timestamp); `tag` is `vX.Y.Z` or `nightly-<full>`. | `outputShapes` |
| V8 | An unknown `VERSION_KIND`, `VERSION_BUMP` or a non-numeric `VERSION_TIMESTAMP` exits non-zero with a message and prints nothing. | `badInputs` |
| V9 | A shallow clone with no tags fails with a message to fetch tags, instead of quietly returning `1.0.0`. | `shallowCloneWithoutTagsFails` |
| V10 | `--github-output` appends the same keys to `$GITHUB_OUTPUT` (without overwriting); without that variable it fails. | `githubOutput` |
| V11 | A pre-release (`VERSION_KIND=prerelease`, label `VERSION_LABEL`, default `beta`) leads to the next release: the latest version bumped by `VERSION_BUMP`, then `-<label>.<N>`. N is one more than the highest existing `v<X.Y.Z>-<label>.<N>` tag (numeric: beta.10 follows beta.9); another label or version starts at 1. | `firstPrerelease`, `prereleaseNumbering`, `prereleaseWithNoTags` |
| V12 | A pre-release's marketing version stays plain `X.Y.Z`, its tag is `v<full version>`, its channel `prerelease`, its build number the UTC stamp; pre-release and nightly tags never move the latest release. | `firstPrerelease`, `prereleaseTagsDontMoveTheRelease` |
| V13 | The label is lowercase letters only; anything else exits non-zero with a message and prints nothing. | `prereleaseLabelIsValidated` |
| V14 | `plugin_version` is `X.Y.Z.<commit count>` (the marketing version plus `git rev-list --count HEAD`), so it rises on every build, nightlies included. `VERSION_COMMIT_COUNT` overrides the count (digits only); a shallow clone without it fails with a message to fetch the full history. | `pluginVersionRisesWithCommits`, `commitCountOverride`, `shallowCloneFails` |
| V15 | `scripts/stamp-plugin-version.sh <X.Y.Z.N>` writes that version into the Stream Deck manifest's top-level `Version` only, in the working copy. A malformed version, a missing manifest or one without a top-level `Version` exits non-zero and changes nothing. | `stampsOnlyTheTopLevelVersion`, `malformedVersionIsRefused`, `unusableManifestIsAnError` |
| V16 | The release workflow stamps `plugin_version` before the archive, and `scripts/ci/verify-release.sh` fails the release if the plugin packed in the app has a different version. Checked by the release run itself; not unit-tested. | (release run) |

## Usage

```sh
scripts/compute-version.sh                                   # next release (patch bump)
VERSION_BUMP=minor scripts/compute-version.sh                # next minor release
VERSION_KIND=nightly scripts/compute-version.sh              # next nightly
VERSION_KIND=prerelease VERSION_BUMP=minor scripts/compute-version.sh   # next beta of the next minor release
scripts/compute-version.sh --github-output                   # in a workflow: later steps read steps.<id>.outputs.*
```

Checkouts must include the tags: use `actions/checkout` with `fetch-depth: 0`.

## Notes

- The plugin version is not committed. The manifest in the repository keeps a plain `0.x.y.z` for local builds;
  CI stamps the real one into its checkout. An installed plugin that is newer than the one in a local build is
  never downgraded (the app only updates when the installed plugin is older).
- The build number is passed to `scripts/set-build-number.sh` as `BUILD_NUMBER` so the app, the
  appcast and the artifact names all carry the same value.
- Gotcha: because a nightly is patch + 1, a nightly built after `v1.0.0` is `1.0.1-…`. If the next
  release is a minor bump (`1.1.0`), the earlier `1.0.1-…` nightlies sort lower, which is correct.
- Not covered here: the release, nightly and publishing workflows that call this script (separate
  PRs for issue #3).
