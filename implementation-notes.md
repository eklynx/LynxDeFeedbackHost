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
- **Signing key** is a dedicated one under keychain account `DeFeedbackHost` (a different, pre-existing Sparkle key was in the keychain and deliberately not reused). Both halves are in 1Password: vault `Dev - Lynx DeFeedback Host`, item `Sparkle EdDSA signing key (DeFeedbackHost updates)`. All secrets for this project live in that vault.

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
