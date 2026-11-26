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
