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
