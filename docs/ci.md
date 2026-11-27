# Continuous integration

Workflow: `.github/workflows/ci.yml`. Part of issue #3 (the release, nightly and publishing
workflows come in later PRs).

## What runs

On every pull request to `main` and every push to `main`:

1. **Build & unit tests** (`app-build-test`): builds the app unsigned and runs
   `DeFeedbackHostTests` on macOS. UI tests are excluded: they can't launch an unsigned build.
   Failures upload the `.xcresult` and the log as the `test-results` artifact.
2. **`ci-ok`**: a single gate that fails if any job above failed, was cancelled or was skipped.
   Require **this** check in branch protection (Settings › Branches); adding jobs later only
   means adding them to its `needs`.

Six tests need the real DeFeedback Audio Unit (and some need audio hardware), which hosted
runners don't have. They are tagged `.requiresPlugin` (`DeFeedbackHostTests/TestTraits.swift`):
they run on a Mac that has the plugin and show as **skipped** on hosted CI. Simulating the
plugin and devices so the host-logic ones can run in CI is tracked in #19.

Superseded pull-request runs are cancelled. Creating and notarizing DMGs and publishing updates
are the release workflow's job, not this one.

## Choosing the runner

Default: GitHub's hosted **`xcode-27`** image (macOS 27, Xcode 27, Apple silicon), because the app
targets macOS 27. Change it without editing the workflow, in Settings › Secrets and variables ›
Actions › Variables:

| Variable | Example | Meaning |
|---|---|---|
| `RUNNER_LABEL` | `"xcode-27"` or `["self-hosted","macOS"]` | JSON `runs-on` value. Default `"xcode-27"`. |
| `XCODE_PATH` | `/Applications/Xcode_27.app` | Optional: `xcode-select` this Xcode before building. |

A manual run (Actions › CI › Run workflow) can override the runner and include the UI tests.

Every workflow that needs a Mac takes the same optional `runner` input on a manual run (CI, CodeQL,
Release, Pre-release, Nightly, cert-expiry). It is JSON, for example `"xcode-27"` or
`["self-hosted","macOS","ARM64"]`. Precedence: the `runner` input, then the `RUNNER_LABEL` variable,
then the hosted default (`xcode-27`; `macos-latest` for cert-expiry). Scheduled, push and
pull-request runs have no input, so they keep using the variable or the default. Try a new runner
with `dry_run` on first: the release jobs read signing and notary secrets from the `release`
environment.

## Releases, pre-releases and nightlies

All three call one shared build (`build-and-publish.yml`): `release.yml` (manual), `prerelease.yml`
(manual) and `nightly.yml` (daily 03:00 UTC). Nightlies and pre-releases keep only the newest few
through a shared `prune-builds.yml`. See `docs/release.md`, `docs/release-spec.md`,
`docs/prerelease-spec.md` and `docs/nightly-spec.md`.

## Static checks

SwiftLint runs on every PR (new findings only, against a baseline; part of `ci-ok`), Dependabot
opens weekly update PRs for Actions, npm and Swift packages, and a CodeQL workflow exists but is
disabled until it supports Xcode 27 (issue #34). See `docs/static-checks-spec.md`.

## Certificate expiry reminder

A weekly workflow (`cert-expiry`) checks when the Developer ID certificate expires and opens a
reminder issue when 15 days or fewer are left. See `docs/cert-expiry.md`.

## Versions

Version numbers come from git tags via `scripts/compute-version.sh`; see
`docs/versioning-spec.md`. CI checks out full history (`fetch-depth: 0`) so tags are present.
