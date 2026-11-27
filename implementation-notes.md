# Implementation notes: launch / single-instance / crash restart

Plan: `~/.claude/plans/vivid-sprouting-sonnet.md`. Spec: `docs/launch-and-restart-spec.md`.

## Decisions not in the spec
- **Restart setting = supervisor agent status**, not a stored preference (same pattern the old launch toggle used). One source of truth; no SettingsStore change (the plan listed one).
- **"Relaunch Now" banner** added: enabling *Restart after a crash* while running unsupervised would otherwise leave requirement 2 unmet until the next launch. Quits normally; a detached `sh` waits 2 s then `launchctl kickstart`s the supervisor.
- **Heartbeat** (lock-file mtime touched every 2 s by a main-run-loop timer) added so the stale-holder kill can tell a *hung* process from a healthy one. Without it the 3-strike kill could kill a legitimate manual instance.
- **SIGTERM is handled as a normal quit** (exit 0). By default it kills by signal, which the supervisor would restart.
- Early exits use `exit()` not `NSApp.terminate`, so exit codes are exact and nothing half-started needs saving.
- **Fail open** if the lock file can't be created (a possible duplicate beats an app that won't start).

## Changes from the old code
- `AppDelegate` was dead code (never installed); now installed via `@NSApplicationDelegateAdaptor` and is the sole owner of `AudioHost`/`WebControlService`. `ContentView` no longer loads state (it did, which would have double-loaded).
- Plist `KeepAlive` dropped the redundant `Crashed:true` (`SuccessfulExit:false` already covers signals/crashes). Hard-coded `Program` replaced by `BundleProgram`; `/Applications` requirement and its tests removed. Added `AssociatedBundleIdentifiers` so Login Items shows the app.
- Old single agent (`com.eklynx.sound.DeFeedbackHost`) is no longer shipped. **Existing installs keep a stale registration** that can't be removed from inside the app (its plist is gone). Run `launchctl bootout gui/$(id -u)/com.eklynx.sound.DeFeedbackHost` or remove it in System Settings › Login Items once.
- `LSMultipleInstancesProhibited` kept; harmless belt-and-braces for LaunchServices launches.

## Tradeoffs / things to know
- Manual launch with restart on briefly "flickers": the Finder-launched process hands off and exits; the launchd copy shows the window.
- `launchctl kickstart` of an already-running job fails, so a second launch falls through to the lock and activates the running copy.
- Moving the app requires toggling the settings off/on to re-register.
- Not verified here: real launchd behaviour (needs a signed build and approval in Login Items) — see the manual checklist in the spec.

## Status
- App builds. New unit tests written (`LifecycleTests.swift`). `StaleHolderPolicy.verdict` implemented (manual never kills; unknown heartbeat = healthy; kill only after 3 strikes + stale + verified same app) with tests.

## Tunables and test hosting
- Heartbeat interval, stale threshold and strike count are now individual UserDefaults keys (`Lifecycle.*`, see spec). All other settings are still one JSON blob (`HostSettings`), so they are **not** individually CLI-settable; left as is.
- `ThrottleInterval` can't be a UserDefaults value (launchd reads the plist).
- Unit tests are hosted inside the app, so with a real copy running (e.g. an Xcode debug session) the single-instance guard made the test host exit 0 before the runner connected. The launch policy is now skipped under XCTest (`XCTestConfigurationFilePath`). Side effect worth knowing: a running copy no longer blocks `xcodebuild test`.


# Implementation notes: application updates (Sparkle, issue #7)

Spec: `docs/updates-spec.md`. Contract: `DeFeedbackHost/Updates/UpdateChecking.swift`. Branch `7-check-for-application-updates` (created with `gh issue develop 7`).

## Decisions not in the spec
- **The issue body, not just the comment, is the spec.** It requires: opt-in (default off), startup + every X, in-app and web message with a releases link, "Update Now" in Settings, menu item, and **no automatic download/install**. I first missed the body, so an early plan assumed auto-check on; corrected before any code.
- **Sparkle never schedules.** `SUEnableAutomaticChecks`, `SUAutomaticallyUpdate` and `SUAllowsAutomaticUpdates` are all false. Our own timer (`UpdateService`) calls `checkForUpdateInformation()`, a silent probe that shows no UI. Only a click calls `checkForUpdates()`. This is what satisfies "don't initiate any update process".
- **Interval presets** (1 h / 6 h / 1 day (default) / 1 week) rather than free text: every value is valid. `defaults write … Updates.checkInterval -int <seconds>` snaps to the nearest preset. Keys: `Updates.enabled`, `Updates.checkInterval`, `Updates.lastChecked`.
- **Menu "Check for Updates…" works even with the setting off** (user asked); it becomes "Update Now…" while an update is known. Settings also has a "Check Now" button.
- **Web is read-only**: `GET /api/update` (+ HEAD) and a banner on the page, polled every 5 min. No install over the network. Documented in `openapi.yaml`; the existing conformance tests cover the route.
- **`SparkleUpdateEngine` is the only file importing Sparkle**, behind an `UpdateEngine` protocol, and is created lazily on first probe so a second launch that exits, or a user who never opts in, never starts Sparkle. Under XCTest an inert engine is used.
- **Missing signing key is a soft state**: with an empty `SUPublicEDKey` the engine reports "Updates aren't configured in this build" instead of letting Sparkle show its "contact the developer" alert. "Update Now" then falls back to opening the releases page.
- **Relaunch hook**: `updaterWillRelaunchApplication` releases the instance lock (`InstanceLock.release()`) before Sparkle quits. Called synchronously via `MainActor.assumeIsolated` because the process is about to exit.

## Changes from the plan
- **Embed Frameworks phase removed.** A hand-written embed phase referencing the package product failed ("Sparkle-product" not found); Xcode embeds `Sparkle.framework` into `Contents/Frameworks` by itself. Verified in the built app.
- **Sparkle keys live in `DeFeedbackHost/Updates/SparkleInfo.plist`**, wired with `INFOPLIST_FILE`, merged with the generated plist. Xcode silently ignores custom `INFOPLIST_KEY_SU*` build settings (verified: they never reached Info.plist). The file is excluded from the target's resources via the existing exception set.
- `SUPublicEDKey` comes from the `SPARKLE_PUBLIC_ED_KEY` build setting (set to the DeFeedbackHost key's public half).
- **Signing key** is a dedicated one under keychain account `DeFeedbackHost` (a different, pre-existing Sparkle key was in the keychain and deliberately not reused). The private half must be backed up offline by the maintainer; losing it means existing installs can never verify an update.

## Things to know / tradeoffs
- **Pre-existing, not touched:** `DeFeedbackHost/Info.plist` (with `LSMultipleInstancesProhibited`) is not actually used by the build (the key is absent from the built app, and the file lands in Resources). I did not point `INFOPLIST_FILE` at it because enabling that key would change launch behavior.
- **Signing**: notarization needs Sparkle's nested code signed with Developer ID. New `scripts/sign-sparkle.sh` signs XPC services, `Autoupdate`, `Updater.app`, then the framework, inside-out; called from `scripts/create-dmg.sh` and the inline "Notorize DMG" phase before the app is signed. The "Create DMG" (dev identity) phase is unchanged. Smoke-tested with an ad-hoc identity only: a real Developer ID + notarization run is still needed. `scripts/notorize-dmg.sh` (misspelled duplicate) left alone.
- **`scripts/publish-update.sh`** signs the DMG (`SPARKLE_ED_PRIVATE_KEY` env var for CI, else login keychain), writes/merges `appcast.xml` (newest first, same build replaced), optional `--upload` to a GitHub Release. Tested with a throwaway key and a dummy file. It does not push `gh-pages`; that is left to you or the future Action.
- `sparkle:version` = `CFBundleVersion` = git commit count (set by `set-build-number.sh`); `shortVersionString` = marketing version. Releases must be built from a commit count higher than the previous release.
- **Failed-probe retry policy** is `UpdateScheduler.delay(after:interval:)`; a 60 s floor prevents a request storm.
- UI tests (the default template) can't launch an unsigned build, so I ran `-only-testing:DeFeedbackHostTests`.

- **Debug-only simulation** (`Updates.simulateVersion`, `SimulatedUpdateEngine`) is wrapped in `#if DEBUG`; verified absent from the Release binary. All defaults keys and release env vars are documented in `docs/debug-settings.md`, with a test that fails if a key is added in code but not documented.
- **Main-window banner** sits in a top `safeAreaInset` so it adds to the window's required height; the earlier version squeezed the gallery and cut off mute/bypass (regression test U17). The pre-existing error banner still lives inside the fixed 900 pt and could do the same; left alone.

## Status
Implemented and unit-tested (17 new tests, rules U1–U15). **Not yet done:** enable GitHub Pages (source: `gh-pages`), and run the manual checklist in `docs/updates-spec.md` (notarized update, relaunch under launchd supervision).

# Permissions at startup, generic warnings (issue #14)

## Decisions not in the spec
- **Generic `warnings` in the status payload** (your request): `AppWarning` / `WarningSource` live in a tiny `Warnings/` namespace; `UpdateService` and `PermissionService` both conform, and `WebControlService` just concatenates its `warningSources`. The page's old `/api/update` poll and `#update-banner` are replaced by one banner rendered from `status.warnings` (so it also updates live over SSE). `GET /api/update` still exists, unchanged, for other clients.
- **Login Items is report-only.** Registering the agents at launch would silently switch "launch at login" and "restart after a crash" on for every install, so it only warns when an agent the user turned on is `requiresApproval`.
- **Local Network** is probed with a short `NWBrowser` for `_defeedbackhost._tcp` (Bonjour). That raises the prompt at launch and reports "policy denied" (-65570) as denied. The same probe is the re-check, because the system offers no passive status. A probe that times out (prompt unanswered) is `.unknown` and never warns.
- **Re-check trigger** is `didBecomeActive`, which covers "granted in System Settings, switched back".
- `NSBonjourServices` went into `Updates/SparkleInfo.plist` (the merged plist: arrays can't be `INFOPLIST_KEY_*`). The file name is now slightly misleading; renaming would churn the project file for no behavior change.

## Things to know / tradeoffs
- The Microphone prompt now appears at launch rather than at first Run. `AudioHost.ensureMicrophoneAccess` is untouched and still guards starting the engine.
- The web warning for Local Network is mostly seen from the host machine itself: a client that can reach the page at all already got through the permission.
- This branch is off `main`; the update-channels work (#3 branch) also touches `UpdateService`, `WebControlService` and `openapi.yaml`, so whichever merges second needs a small rebase (the update warning's link should then use `releaseNotesURL`).
- Real prompts can't be unit-tested; the manual checklist in `docs/permissions-spec.md` covers them.

## Status
Implemented and unit-tested (rules P1–P9). The manual checklist with real system prompts has not been run.

# CI/CD part 1: version script and PR checks (issue #3)

## Decisions not in the spec
- **Draft reuse:** the unmerged `origin/actions` branch had a full draft CI. This PR takes only its app build/test job and the `ci-ok` gate; SwiftLint, Stream Deck, OpenAPI lint, CodeQL and Dependabot are left for a later PR so this one stays small and the SwiftLint baseline / Spectral config (which I can't verify locally) don't hold it up. The draft's default runner `macos-latest` became the hosted `xcode-27` image (macOS 27 + Xcode 27), keeping its `RUNNER_LABEL` / `XCODE_PATH` overrides.
- **Tags:** the three existing releases are bare (`0.1.2`), while the versioning notes use `vX.Y.Z`. The script reads both (so the next release is `0.1.3`) and every new tag has the `v`. Re-tagging the old ones was not needed.
- **Shallow clones fail loudly.** The notes' original script silently fell back to 1.0.0 without tags; this one exits with "fetch the tags" instead.
- **Numeric tag order:** the `v` is stripped first, then tags are sorted with `sort -t. -k1,1nr -k2,2nr -k3,3nr`, so mixed bare and `v` tags compare by number only. (I didn't rely on `git tag --sort=-v:refname` for the mixed case.)
- **Script tests are Swift Testing** that run the real script in throwaway git repos (the repo's existing pattern for script tests), so they run in the same CI job as everything else.

## Things to know / tradeoffs
- The workflow can only be proven by running it on GitHub. The hosted image may differ from this Mac (headless audio, package resolution, unsigned build); the PR's own run is the check and may need follow-up commits.
- **Six tests skip on hosted CI.** The first hosted run built the app and ran everything on Xcode 27.1 / macOS 27; six tests failed only because the DeFeedback Audio Unit isn't installed there (three read the real plugin's identity, three are host logic that hits the "plugin missing" state). They now carry `.requiresPlugin` and are skipped, not failed. Three of them are logic tests that a simulated plugin and devices could run: issue #19.
- The `set-build-number.sh` change (timestamp / `BUILD_NUMBER`) is in the update-channels PR (#17); this PR doesn't depend on it.
- `ci-ok` only protects `main` once it is set as a required check; that is a repository setting, not a file.


# Update channels (issue #3, app side)

## Decisions not in the spec
- **Channels are cumulative and "release" is the absence of a tag** (Sparkle's own model: an untagged item reaches everyone, a tagged one only users who list that name). `UpdateChannel.sparkleChannels` feeds `allowedChannels(for:)`; unknown stored values fall back to release so a typo can't opt anyone into nightlies.
- **The channel is passed to the engine on every call** (`probe(channel:)`, `presentUpdate(channel:)`) instead of living in the engine, so the fake in tests records exactly what the service asked for.
- **Switching channel clears the known update and re-probes** when checking is on. An update found on nightly may not exist on release, so keeping it would show a banner for something the new channel wouldn't offer.
- **Release notes link** is the item's own page (`SUAppcastItem.infoURL`, else `releaseNotesURL`, else the Releases list). `/api/update` keeps `releasesURL` and adds `releaseNotesURL` and `channel`, so existing clients keep working.
- **Build number** changed from commit count to UTC build time (or `$BUILD_NUMBER`), because it must rise across separate release and nightly workflows. The git hash still goes in `GitCommit` and, for nightlies, in the version string.

## Things to know / tradeoffs
- **Sparkle never downgrades**: moving from Nightly back to Release keeps the installed build until a newer release appears.
- The new build numbers (14 digits) are far above the old commit counts, so nothing already built can outrank them. No release had been published yet.
- **Not in this PR** (pipeline PR): `compute-version.sh`, marketing version from tags, the Release/Nightly/appcast workflows, keeping the last 7 nightlies (GitHub releases and feed items), a pre-release trigger, runner and secrets. `publish-update.sh` only adds items; pruning is still to do.
- The script tests run the real shell scripts with a stub `sign_update`, so they need `/usr/bin/python3` (already required by the publish script).

## Status
Implemented and unit-tested (rules U18–U24). The real-feed check (nightly, pre-release and release items against each channel) is in the manual checklist in `docs/updates-spec.md`.

# CI/CD part 3: release workflow (issue #3)

## Decisions not in the spec
- **Notarization uses an App Store Connect API key** (your choice) through the new `scripts/notarytool-submit.sh`; the old keychain profile still works locally when no API key variables are set, and half a key is an error rather than a silent fallback. The script also requires Apple's status to be `Accepted`, because `notarytool submit --wait` on its own isn't a trustworthy pass/fail.
- **One DMG script.** The Xcode "Notorize DMG" phase held an inline copy of `scripts/create-dmg.sh`; it now just runs the script, so Xcode, a terminal and CI can't drift apart.
- **The archive does the signing.** CI archives unsigned (`CODE_SIGNING_ALLOWED=NO`) and the install-only run-script phases sign the DMG copy with Developer ID, as they already did locally. No Apple Development certificate or provisioning is needed on the runner.
- **Secrets only in the `release` environment** (limited to `main`), only ever as `env:` values; a test fails if a secret shows up anywhere else in the workflow. A temporary keychain with a random password holds the certificate and is deleted even on failure.
- **Dry run** stops before any publishing and keeps the DMG as a run artifact, so the very first run can be done with nothing at stake.
- **Release first, appcast second.** The GitHub Release (and its DMG URL) must exist before the feed points to it, so a failed appcast push leaves a public DMG without an update offer, not an update offer with a dead link. Recovery is in `docs/release.md`.

## Things to know / tradeoffs
- A test caught a real bug in my first import script: `security import` guesses the file format from the extension and my temp file had none ("Unknown format"). It now passes `-f pkcs12`.
- Not verified: the workflow itself (needs the six secrets), the archive-time signing on a hosted runner, and notarization with the API key. The dry run is the first real test. I did not run a local archive because it would sign with your real Developer ID and could raise keychain prompts.
- Needs the update-channels work (#17): `BUILD_NUMBER` in `set-build-number.sh` and `--channel` in `publish-update.sh`. It is merged, and this branch is rebased on it; `RELEASE_TARGET` (rule R7) was added to `publish-update.sh` here.
- The hosted runner needs Node for the Stream Deck plugin the archive packs; the job installs `@elgato/cli` and builds `streamdeck/` first.



# CI/CD: fixing the DMG step of the release dry run (issue #3)

## What happened
The first release dry run failed in the "Create DMG" phase of the archive with `hdiutil: create failed - No such file or directory` (and a deprecation warning for that form of `hdiutil`). The signing, notarization and verify steps never ran.

## What I found and did
- **Could not reproduce it.** On the hosted runner every way of making a DMG worked when tried on its own (`hdiutil create` with and without a filesystem choice, and `diskutil image create from`), and a pull-request run of the *real* archive packed the DMG fine, with both DMG phases using plain `hdiutil create`. So the failure was not a deterministic bug in the staged folder or paths; it looks like a one-off failure of the tool on the runner. I have not proven that.
- **Made it survive and explain itself:** new `scripts/make-dmg.sh` tries `hdiutil` up to 3 times, then prints what is needed to diagnose a real fault and falls back to `diskutil image create from` (the replacement Apple names). Both DMG phases use it.
- **A proof on every pull request:** a `dmg-smoke` job archives the app like a release and packs an UNSIGNED DMG (`ALLOW_UNSIGNED_DMG=YES`, which exists only for this and refuses to be the default), then verifies and mounts it. It is part of `ci-ok`.

## Things to know
- If the release fails here again, the log now shows the attempt count, the staged folder and which fallback ran, which is the evidence that was missing.
- The unsigned image is never publishable: it is not signed, not notarized, and `create-dmg.sh` says so.
- Still unproven: signing with the Developer ID, notarization with the API key and the verify step. They have not run yet.
\n

# CI/CD: certificate expiry reminder (issue #3)

## Decisions not in the spec
- **Same shape as the reminder in your other project:** a weekly `check` job that sees the secrets and reports only a number and a date, and a `remind` job with `issues: write` and no secrets that opens or updates one issue (label `certificate-expiry`, assigned to the owner so GitHub emails them). Threshold 15 days, as you chose; with the current certificate (expires 2027-02-01) the first issue opens on Mon 2027-01-18.
- **Simpler check:** it reads the certificate straight from the `.p12` with the system `openssl` and does no keychain work, because the only question is the date. It runs on macOS because the `.p12` Apple's export makes needs the system (LibreSSL) `openssl` and BSD `date`.
- **Expired is not silent:** the check exits 1 but still prints the numbers, so the reminder job (which runs when it has a date) opens an "expired on …" issue instead of staying quiet.
- **`CERT_EXPIRY_NOW`** lets tests move "now" instead of generating certificates with odd lifetimes.
- **`remind-expiry.sh` is plain `sh`** (not bash with indirect variables), so it runs the same under the tests and on the runner.

## Things to know / tradeoffs
- Scheduled workflows only run from the default branch, so nothing happens until this merges; the first run is the next Monday 14:00 UTC. A manual run with `threshold_days` = `9999` is the real test (it opens one issue, which you then close).
- GitHub switches off scheduled workflows in a public repo after 60 days without activity.
- A test of mine failed once because the stub `gh` logged the multi-line issue body across several lines; the script was right. The stub now logs one line per call.
- It only watches the Developer ID certificate. The notary API key doesn't expire unless revoked, and the Sparkle key never expires.

## Status
Implemented and unit-tested (rules C1–C9). Not run on GitHub yet: the scheduled and manual runs need this on `main`.

# CI/CD: nightly builds, shared build, pruning (issue #3)

## Decisions not in the spec
- **One shared build.** The release steps moved into `build-and-publish.yml` (a reusable workflow with `kind` = release | nightly); `release.yml` is now a thin manual caller and `nightly.yml` the scheduled one. The signing/notary secrets are still read only inside the shared build's job, which sets `environment: release`; a test fails if either caller mentions a secret. GitHub's docs say a called job that declares an environment uses that environment's secrets; the dry runs are the proof.
- **Skip rule** compares `main` with the newest `nightly-*` tag (ordered by the 14-digit stamp in its name, not by commit date) and with the newest release tag (numeric order, bare or `v`). A release made at the current commit therefore doesn't get a twin nightly.
- **The DMG is named with the full version** through an optional `DMG_VERSION`, so several nightlies of the same patch don't share a file name.
- **Feed first, releases second** when pruning, so the appcast never points at a deleted download. If the feed push fails, nothing is deleted.
- **Pruning is conservative:** it can only name `nightly-*` tags and only removes items on the `nightly` channel; a test passes a release tag and a nightly-tagged URL on a non-nightly item to prove they survive.
- **Failures:** a failed scheduled run relies on GitHub's own failed-run email, as chosen. No issue is opened.

## Things to know / tradeoffs
- Releases and nightlies share one concurrency group. GitHub keeps only one waiting run per group, so two runs queued behind a running build could replace each other. Not a practical problem with one nightly a day and manual releases.
- A nightly's version is based on the latest release tag (patch + 1), so after `v0.1.3` it is `0.1.4-<stamp>.<hash>`.
- Not run on GitHub yet: the shared build for a release (refactored, so it needs a dry run), a nightly dry run, a real nightly, and a prune with more than 7 nightlies.

## Status
Implemented and unit-tested (rules N1–N10). The real runs are in the manual checklist in `docs/nightly-spec.md`.

# CI/CD: secrets reaching the shared build (issue #3)

## What happened
The first Release dry run through the shared build (`build-and-publish.yml`) passed the guard and the unit tests, then failed at "Import the signing certificate" because the certificate secret was **empty** inside the called workflow. The job sets `environment: release`, and GitHub's docs say that is enough to read that environment's secrets, but in practice the secrets did not arrive.

## What I changed
Callers of the shared build now pass `secrets: inherit` (one line in `release.yml` and `nightly.yml`). One third-party write-up reports that environment secrets of a called job are empty unless the caller does this, which matches what we saw; I could not confirm it against GitHub's own docs, which say `environment:` alone works. A test pins that both callers pass it.

## Not proven yet
That `secrets: inherit` is enough. The next Release dry run is the test. If the secret is still empty, the fallback is to stop using a reusable workflow for the job that needs the secrets and use a composite action (its steps run inside the caller's own job, which can set `environment: release` itself).

# CI/CD: pre-releases (issue #3)

## Decisions not in the spec
- **Automatic version numbers, as chosen:** `compute-version.sh` gets `VERSION_KIND=prerelease` with `VERSION_BUMP` and `VERSION_LABEL`. The base is the release the build leads to (latest release bumped, exactly as a release is), and N counts up per base and label from the existing tags, numerically (beta.10 follows beta.9). Nobody types a version, so no typos and no skipped or duplicated numbers.
- **Kept the newest 10, as chosen,** by generalising the nightly pruning: `prune-nightlies.sh` became `prune-builds.sh --kind nightly|prerelease`, and the prune job moved into a reusable `prune-builds.yml` that `nightly.yml` and `prerelease.yml` both call. A kind is required, and a tag or appcast item of another kind can never be selected or removed.
- **A pre-release does not stop a nightly** (your choice), so the nightly skip rule is unchanged and a test pins it.
- **The label check lists the letters** (`abc...z`) instead of using `[a-z]`: in this shell's locale the range also matched capitals and `Beta` was accepted. Found by running the script by hand, then covered by a test.
- **Stacked on the nightly PR (#23)** because the pre-release workflow reuses that PR's shared build.

## Things to know / tradeoffs
- Pre-releases can only be built from `main` (the `release` environment and the guard are limited to it), so "a beta of a feature branch" is not possible without widening that rule.
- After `v0.2.0` is released the earlier `0.2.0-beta.N` stay until pruned; they sort lower by build time, which is correct.
- Not run on GitHub yet: a nightly dry run (the pruning moved into a shared workflow), a pre-release dry run, a real pre-release, and a prune with more than 10 pre-releases.

## Status
Implemented and unit-tested (rules PRE1–PRE9 and V11–V13). The real runs are in the manual checklist in `docs/prerelease-spec.md`.

# CI/CD: pruning orders by publish time (issue #3)

## What I found
After the first real nightly, `gh release list` showed `createdAt` 00:48:47Z for a release published at 01:07:52Z: for a release, GitHub's `createdAt` is the **date of the commit the tag points at**, not when the release was made. The prune workflow ordered by `createdAt`, so builds made from the same commit (a forced nightly re-run, or two betas without new commits) would tie, and the wrong one could be pruned. Nothing had been pruned yet (fewer than 7 nightlies exist), so no build was lost.

## What I changed
The prune workflow now passes `publishedAt` (the real time). A draft has no `publishedAt` and is never selected. Tests pin the ordering with same-time-commit builds and that the workflow doesn't mention `createdAt`.


# CI/CD: static checks: SwiftLint, CodeQL, Dependabot (issue #3)

## Decisions not in the spec
- **SwiftLint fails only on new findings.** The draft's baseline (17 Oct) was stale, so I regenerated it with SwiftLint 0.65.1: 160 findings (155 warnings, 5 errors) across 19 files are recorded, and the baseline was checked to give 0 findings from a copy of the repo in another directory (paths are relative).
- **SwiftLint is pinned, not brew-installed.** The job downloads `portable_swiftlint.zip` of one release and verifies its SHA-256. A new SwiftLint therefore can't turn `main` red by adding rules; raising the pin is a PR.
- **The lint job joins `ci-ok`** (the required check from the branch protection), so it blocks merging.
- **CodeQL is in place but disabled, as asked** (issue #34): only `workflow_dispatch` is live; the push, pull request and schedule triggers are commented out, with a test pinning that. The matrix is Swift (manual build), JavaScript/TypeScript and Actions. I replaced the draft's older action SHA with the current v4 commit.
- **Dependabot also covers Swift packages** (Sparkle), added to the draft's Actions and npm; minor/patch updates are grouped per ecosystem.
- **Left out of the draft:** the Stream Deck typecheck job and the OpenAPI (Spectral) lint. Not requested; the DMG job already builds the plugin, and Spectral would likely report many findings.

## Things to know / tradeoffs
- The baseline is a debt list, 160 entries long. Regenerating it hides violations, so only do that after fixing some.
- The lint job needs a macOS runner (same label as the build) because the pinned binary is the macOS one.
- Not run on GitHub yet: the lint job and the first Dependabot run (after merge).

## Status
Implemented and unit-tested (rules S1–S8).

# Lint cleanup: WebControlService split (issue #41)

## What I changed
`WebControlService.swift` (965 lines, class body 640, two functions at complexity 22 and 30) is now split by responsibility instead of by moving code into extension files:

```text
Web/
├── WebErrorStrings.swift          the error messages, moved as is
├── WebRequestValidation.swift     body checks that need no host; a failed check throws WebRejection
├── WebInstanceChanges.swift       parse-then-apply for PATCH /api/instances/{id}
├── WebStatusPayload.swift         the status / update / instance JSON, reads the host only
├── WebRoutes.swift                the route table (replaces the 22-way switch)
├── WebControlService+Commands.swift   the command handlers
└── WebControlService.swift        state, lifecycle, status stream
```
Validation uses `throws` (a `WebRejection` carries the response) instead of the old `CheckedValue` enum that every call site had to `switch` on; that is what removes most of the complexity. Nothing is applied until every field has passed, same fixed order as before.

## How I kept behaviour the same
- First wrote `WebHandlerTests` (41 tests: routes, 405 table, every status code and error order of the command endpoints, nothing applied on a later bad field) and ran them on the OLD code. They passed there and still pass on the new code.
- `OpenAPIConformanceTests` read the Swift source as text; they now read `WebStatusPayload.swift` (`func status(`) and `WebRoutes.swift`.

## Things to know
- **A quirk kept as it was:** `HEAD /index.html` is refused (405) although the `Allow` header lists HEAD; only `/` serves HEAD. A test pins it so a fix is a deliberate change.
- **Another quirk kept:** `{"running": 1}` counts as `true` (a JSON number bridges to Bool). Not pinned; worth tightening separately.
- **Test seams (debug builds only) in `AudioHost`:** `setHardwareForTesting` and `addBareInstanceForTesting`, so handler tests need no audio hardware or plugin. The first sets a flag that stops the host querying or changing real devices on behalf of the fake ones.
- **Not covered by the new tests** (need a running host or the real plugin): the "stop the host first" 409s, a successful add, Strength values.
- **A bug I introduced and fixed on the way:** my first route table wrapped handlers in a helper named like the `respond` enum case and recursed forever (a test run ballooned to several GB). The table now uses plain named functions. I also ran the tests under a memory kill-switch after that.

## Status
Baseline: 21 -> 13 findings (all of WebControlService's gone). Left: AudioHost, HTTPMessage, ContentView, PluginInstance, AudioIO, HTTPServer.

# Lint cleanup: HTTP parser and server split (issue #41, PR A)

## What I changed
```text
Web/
├── HTTPMessage.swift         HTTPHeaders / HTTPRequest / HTTPResponse (reason phrases are now a table)
├── HTTPRequestParser.swift   moved out of HTTPMessage; parse() is a list of small stages
├── HTTPServer.swift          listener, lifecycle, accept
├── HTTPConnection.swift      one connection: read, parse, dispatch, write, idle timer (moved as is)
└── HTTPStream.swift          the SSE hand-off (moved as is)
```
- `parse` was one 73-line function at complexity 17. Each check is now its own function (`headerBlockEnd`, `headerLines`, `requestLine`, `headerFields`, `refuseTransferEncoding`, `declaredBodyLength`) that returns what it found or throws a private `Refusal` carrying the response. `parse` catches it once. Typed throws (`throws(Refusal)`) keeps the catch from needing a fallback branch.
- `defaultReason` was a 16-case switch (complexity 17); it is now a `[Int: String]` lookup with the same "Status N" fallback.
- `HTTPServer.swift` (488 lines) lost `HTTPConnection` and `HTTPStream`, which moved untouched. No access levels changed.

## How I kept behaviour the same
- First added `HTTPParserCharacterizationTests` (pins which refusal wins when a request is wrong two ways, every message, the exact size caps, padded and zero Content-Length, the reason table) and ran it on the OLD code: all passed there and still pass.
- The full `DeFeedbackHostTests` run is green.

## Things to know
- No socket-level test exists for `HTTPConnection`/`HTTPServer`; the split there is a pure move, so the compiler plus the existing suite is the evidence.
- A malformed request that is wrong in two ways still reports the earlier problem; the order is now documented in the parser's header comment.

## Status
Baseline: 13 -> 9 findings. Left: AudioHost (4), ContentView (2), PluginInstance (2), AudioIO (1).

# Lint cleanup: PluginInstance and ContentView (issue #41, PR B)

## What I changed
```text
DeFeedbackHost/
├── PluginInstance.swift     the class and its error (461 -> 338 lines)
├── InstanceName.swift       InstanceName + InstanceNameError, moved as is
├── PluginUI.swift           PluginUI + UncheckedBox (were file-private, now internal)
├── ParameterSnapshot.swift  the lock-free AU-value holder, moved as is (was file-private)
├── WatchedParameter.swift   address + range of a watched parameter, owns the percent <-> AUValue maths
├── ContentView.swift        layout, banners, removal dialog (450 -> 136 lines)
├── EngineControlBar.swift   pickers, buffer/parallel/run row, instance stepper
├── LoadReadout.swift        pure text/colour/help for the engine readout + the StatusReadout view
└── InstanceGallery.swift    chooser, chevrons, empty and missing-plugin states
```
- `WatchedParameter` replaced a private struct inside the class and took the two conversion functions with it, which is what got the class body under 250. `WebControlTests` calls them as `WatchedParameter.percentFromAUValue` / `auValueFromPercent` now; the assertions are unchanged.
- `EngineControlBar` reports "remove the shown instance" through a closure; the confirmation state and dialog stay in `ContentView`.
- `LoadReadout.help` takes `parallelRendering` as a parameter where the old private method read `host`.

## How I kept behaviour the same
- The readout text and colours were copied verbatim into `LoadReadout` first, pinned with `LoadReadoutTests` (waiting state, NOT REALTIME, colour thresholds, per-worker help lines, percent rounding, the denied-microphone banner rule), and only then did the view start calling them.
- Full `DeFeedbackHostTests` is green (`DmgScriptTests/makesARealImage` is the known hdiutil flake and passed on rerun).

## Things to know
- **Not verified visually.** SwiftUI layout has no unit test here, and I did not launch the app unattended (it grabs audio devices and the web port). Layout values were copied unchanged, but please look at the window once.
- The real-time pieces (`ParameterSnapshot`, the parameter observer) were moved or left alone, not changed.

## Status
Baseline: 9 -> 5 findings. Left: AudioHost (4), AudioIO (1).

# Lint cleanup: AudioHost split, step C1 (issue #41, PR C1)

AudioHost is being split in four stacked PRs (launch agents + persistence, instance list, engine session, device selection). `AudioHost` keeps its whole public API as a facade; logic moves into owned collaborators.

## What I changed in C1
```text
DeFeedbackHost/
├── AudioHost.swift                       forwards to the two collaborators below
└── Host/
    ├── AudioHostError.swift              moved as is
    ├── EngineDiagnostics.swift           was AudioHost.Diagnostics (`typealias Diagnostics = EngineDiagnostics` keeps the name)
    ├── LaunchAgents/LaunchAgentSettings.swift   login + supervisor agent settings, errors via `onError`
    └── Persistence/SettingsPersistence.swift    dirty flag, autosave, save-on-quit, `defaults write` handling,
                                                 behind a documented `PersistableHost` protocol
```
- `AudioHost.init` gained two defaulted parameters (`launchAgents`, `supervision`) so launch-agent behaviour can be tested with fakes. Defaults are the real implementations.
- `currentSettings()` is now internal (was private) because `SettingsPersistence` asks the host for it through `PersistableHost`.
- External-preference handling is split: the diff and "counts as saved" bookkeeping live in `SettingsPersistence`; the five `if external != current` assignments live in `AudioHost.apply(_:includingLockedWhileRunning:)`.

## How I kept behaviour the same
- First wrote `HostPersistenceCharacterizationTests` (15 tests: no save while restoring, no write when nothing changed, external edits ignored/applied/counted as saved, every launch-agent message and status path) and ran them on the OLD code. One of my first guesses was wrong (the very first save after startup does write, because first-run device selection changes the settings); I fixed the test to say that. All pass before and after.
- Full `DeFeedbackHostTests` is green.

## Things to know
- **The baseline entries for AudioHost remain**, with smaller numbers: class body 910 -> 800 lines, file 1370 -> 1144. The file-length limit needs the instance-list PR; the class-body limit needs all four. After C1-C3 I expect to still be roughly 70 counted lines over, so C4 will also move `startBlockedReason` and the restore helpers.
- `AudioHost.Diagnostics` is now a typealias of `EngineDiagnostics`; every existing use compiles unchanged.

## Status
Baseline entries unchanged in number (5); AudioHost's numbers shrank. Next: C2 instance list.

# Lint cleanup: AudioHost split, step C2 (issue #41, PR C2)

## What I changed in C2
`Host/Instances/InstanceList.swift` now owns the instance list: `instances`, the selected index, add / remove / rename / validate / lookup, restore from settings (`restoredNames` moved with it; its test call is renamed), the engine slot activate/retire, and paging. It talks back through a documented `InstanceListHost` protocol (channel counts, new-instance mute/bypass defaults, plugin installed, the live engine, running sample rate, `errorMessage`, `settingsChanged`). `AudioHost` forwards every member it had, so no caller changed. `settingsChanged()` and a new `liveEngine` accessor became internal to satisfy the protocol.

## How I kept behaviour the same
- Wrote `InstanceListCharacterizationTests` for what `WebInstanceListTests` didn't cover (channel defaults, the refusal messages, the 32 cap, paging bounds, which instance stays selected after a removal, stale saved selection) and ran them on the OLD code. Every other instance behaviour already had tests (removal by id, rename rules, lookup by id/name, restored names).
- Full `DeFeedbackHostTests` green (the hdiutil flake passed on rerun).

## Things to know
- **A quirk I kept and pinned:** `showNextInstance()` on an empty list sets the index to -1. The window never offers the chevron then.
- **A correction to my own plan:** SwiftLint's `file_length` is a *warning at 400 lines* and an error at 1000, and it counts comments and blank lines. I had been aiming at 1000. To clear the baseline entry `AudioHost.swift` has to get under 400 lines in total, not just the class body under 350. After C1-C4 I expect the forwarding properties to need their own file per collaborator (`AudioHost+Instances.swift` etc.): extensions are fine for pure forwarding to a collaborator, since the logic and the coupling already live in the extracted type.
- State after C2: class body 800 -> 672 counted lines, file 1144 -> 971 lines.

## Status
Baseline entries unchanged in number (5); AudioHost's numbers keep shrinking. Next: C3 engine session (needs your hear-test), then C4 device selection.

# Lint cleanup: AudioHost split, step C3 (issue #41, PR C3)

## What I changed in C3
```text
Host/Engine/
├── EngineSession.swift   owns the engine, the AUHAL I/O and runningSampleRate; start / teardown / diagnostics
└── StartPreflight.swift  the checks before any hardware call, as pure functions of EngineStartSettings
```
`startAudio()` (complexity 13, 63 lines) is gone: `EngineSession.start()` is a list of small steps in the original order: preflight devices -> microphone access -> bring both devices to one sample rate -> buffer sizes -> build engine -> parallel setting -> activate instances -> prime with silence -> start I/O. The two refusal checks that need no hardware (`devices`, `sampleRate`) are `StartPreflight`; the rest are private steps. `AudioHost` keeps `start()`, `stop()`, `toggleRunning()`, `isRunning`, and forwards `runningSampleRate`, `diagnostics` and `liveEngine`. `EngineSessionHost` is the one-method protocol the session uses to read the host's choices.

## How I kept behaviour the same
- **Every hardware call, argument and error is the old one, moved.** The `AudioIO.start(...)` call is unchanged (you wanted to look at AudioIO first).
- **Same read timing.** The old code read the selected rates *after* the microphone prompt, and the buffer size / parallel setting later still. `EngineSession` asks the host for fresh settings at each of those points instead of capturing everything up front, so a change made while the prompt is open is seen exactly as before.
- **Handles kept the moment they exist.** `engine` is set when the engine is built and `io` before `io.start`, so `teardown()` after a failure cleans up the same things as before.
- `EngineSessionCharacterizationTests` pin what `start()` does before touching hardware and what a stopped host reports; run on the old code first. `StartPreflightTests` pin the refusals and their order (they could not be tested before because they were interleaved with hardware calls). Full `DeFeedbackHostTests` green.

## Things to know
- **Not verified by a machine:** everything after the microphone check (sample-rate switching, buffer sizes, building the engine, starting the I/O, teardown while running) needs a real device and the microphone prompt. The checklist on the pull request is for you.
- `EngineSession.start()` returns quietly if the host has gone (it can't: the host owns the session).
- State after C3: class body 672 -> 564 counted lines, file 971 -> 836 lines. The `startAudio` complexity and function-length baseline entries are gone.

## Status
Baseline 5 -> 3 entries (AudioHost class body and file length, AudioIO).

# Lint cleanup: AudioHost split, step C4 (issue #41, PR C4)

## What I changed in C4
```text
Host/
├── Devices/
│   ├── DeviceSelection.swift        devices, chosen UIDs, remembered names/rates, sample rates, refresh from the system
│   ├── BufferSizeRanges.swift       what each device accepts; `devicesRejecting(...)`
│   ├── DeviceSelection+Testing.swift  debug-only fake-hardware seam
│   └── AudioHost+Devices.swift      forwarding members (host.selectedInputDeviceUID, ...) + the `ratesMatch` / `menuSelection` statics
├── Instances/AudioHost+Instances.swift     forwarders to InstanceList (moved out of the class body)
├── LaunchAgents/AudioHost+Launch.swift     forwarders to LaunchAgentSettings (moved)
├── Persistence/AudioHost+Persistence.swift currentSettings(), apply(_:), reconcile... (what PersistableHost asks of the host)
└── AudioHost+Testing.swift                 debug-only seams
```
`DeviceSelection` keeps the `didSet` chain intact: choosing a device remembers its name, re-reads capabilities, tells the host (`deviceSelectionDidChange()` clears a pending auto-restart), then marks settings changed. `AudioHost.refreshDevices()` is now: refresh the list, stop if a device was lost, refresh capabilities if stopped, resume if devices returned.

## How I kept behaviour the same
- First wrote `DeviceSelectionCharacterizationTests` (selection, remembered names, unavailable devices, rate remembered after clearing, `canStart`, every `startBlockedReason` text, buffer-size gate with unknown ranges) using simulated hardware, and ran them on the OLD code. They pass before and after.
- Full `DeFeedbackHostTests` green; a Release build also succeeds (the debug seams are `#if DEBUG`).
- Compared the old `AudioHost` members with the new tree: every one still exists, except `loginAgentStatus` / `supervisorAgentStatus`, which nothing outside the host used and which are now `LaunchAgentSettings.loginStatus` / `.supervisorStatus`.

## Things to know
- **Extension files, and why:** SwiftLint counts a file's lines (limit 400) and the class body (limit 250 warning / 350 error) separately. Pure forwarding members and the protocol-glue (`currentSettings()` etc.) live in `AudioHost+*.swift` next to the collaborator they belong to. The logic and the state are in the extracted types; the extensions are the facade only. Stored properties (`launch`, `instanceList`, `session`, `persistence`, `deviceSelection`) stay in the class, so some lost `private` to be reachable from those files.
- Final sizes: `AudioHost.swift` 1370 -> 390 lines, class body 910 -> about 200 counted lines. No new warnings; no `swiftlint:disable`.
- Auto-resume (`stopIfDeviceLost`, `resumeIfDevicesReturned`) and `startBlockedReason` stayed in `AudioHost`; they coordinate several collaborators.

## Status
Baseline: 1 entry left, `AudioIO.start` (7 parameters). When that is fixed, delete `.swiftlint.baseline.json`, drop `--baseline` from CI, and close #41.

# Runner choice on every Mac workflow (issue #3)

## What I changed
Every workflow that needs a Mac now takes the same optional `runner` input on a manual run: `release.yml`, `prerelease.yml`, `nightly.yml` and `cert-expiry.yml` gained it (`ci.yml` and `codeql.yml` already had it). `build-and-publish.yml`, which the three release workflows call, takes it as a `workflow_call` input and uses it for both its jobs. The rule is the same everywhere: `inputs.runner`, then the `RUNNER_LABEL` variable, then the hosted default (`xcode-27`, or `macos-latest` for cert-expiry). `docs/ci.md` describes it.

## Behaviour
- The input is JSON, e.g. `["self-hosted","macOS","ARM64"]` for the registered runner EKVM, and defaults to empty, so a run that doesn't pass it behaves exactly as before. Scheduled, push and pull-request runs have no input at all.
- The Linux jobs (nightly's decide, prune, cert-expiry's issue job) stay on `ubuntu-24.04`.

## Things to know
- **Try it with `dry_run` first.** The publish job reads the signing, notary and Sparkle secrets from the `release` environment and creates a temporary keychain; I did not check that those steps clean up on a machine that keeps its state between runs.
- A job aimed at an offline runner waits in the queue (the job's `timeout-minutes` doesn't count queue time), so only pass the self-hosted label when the Mac is up.
- Not done, on purpose: automatically choosing the runner depending on whether the Mac is online. That is still being decided.
