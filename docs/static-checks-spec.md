# Static checks in CI: lint, code scanning, dependency updates (issue #3)

Source of truth for `.swiftlint.yml`, the `swiftlint` job in
`.github/workflows/ci.yml`, `.github/workflows/codeql.yml` and `.github/dependabot.yml`. Each rule
is pinned by a test in `DeFeedbackHostTests/StaticChecksTests.swift`.

| # | Rule |
|---|------|
| S1 | Pull requests and pushes to `main` run SwiftLint with `--strict` and **no baseline**: any finding fails. |
| S2 | The SwiftLint release is pinned (version and SHA-256 of the download, verified before it runs), so a new SwiftLint release cannot turn CI red by itself. Raising the pin is a normal PR that also fixes any findings the new release reports. |
| S3 | The `swiftlint` job is a dependency of `ci-ok`, the one required check, so a lint failure blocks merging. |
| S4 | `.swiftlint.yml` skips generated and third-party code (`build`, `streamdeck`) and the test targets, and there is no `.swiftlint.baseline.json`: findings are fixed, not recorded. |
| S5 | `codeql.yml` analyzes Swift (manual build), JavaScript/TypeScript and the GitHub Actions workflows, with `security-events: write` only on the analyze job. |
| S6 | CodeQL is **disabled** (issue #34): no `push`, `pull_request` or `schedule` trigger is active, only `workflow_dispatch`, because CodeQL cannot analyze Swift 6.4 or trace an Xcode 27 build. |
| S7 | Dependabot checks `github-actions`, `npm` (`/streamdeck`) and `swift` (the Xcode project's Sparkle package) every week. |
| S8 | Minor and patch updates of each ecosystem are grouped into one PR; a major update is its own PR. |

## Keeping it clean
The code has no baseline: it was paid down to zero in issue #41 (the old baseline recorded 160
findings), so a new finding fails the PR that introduces it. Fix it there. Never add a
`swiftlint:disable` to get past CI without saying why in a comment next to it.

## Updating the SwiftLint pin
Change `SWIFTLINT_VERSION` and `SWIFTLINT_SHA256` in `ci.yml` (the checksum is `shasum -a 256` of
that release's `portable_swiftlint.zip`), run the new version locally with `swiftlint lint --strict`, and fix any findings the old one
did not report in the same PR.

## Enabling CodeQL (issue #34)
Re-check the changelog (https://github.blog/changelog/2026-10-19-codeql-changes-for-macos-27-xcode-27-and-swift-6-4),
run the workflow by hand, and when the `swift` job is green uncomment the three triggers in
`codeql.yml`; then change rule S6 and its test.

## Sparkle updates from Dependabot
A Sparkle bump changes what the release signs (nested code). Before merging one, run the Release
workflow as a dry run.
