# Application updates: spec

Source of truth in code: `DeFeedbackHost/Updates/UpdateChecking.swift` (contract), implemented by
`UpdateService`, `UpdateScheduler`, `UpdatePreferences` and `SparkleUpdateEngine`.
Tests: `DeFeedbackHostTests/UpdateTests.swift` (rules U1–U16). Origin: GitHub issue #7.

## Model

Update checking is **opt-in**. Sparkle is only the feed reader and installer. It never schedules or
installs on its own. Background checks are silent probes (`checkForUpdateInformation`); only a user
click starts Sparkle's install flow. The feed (`appcast.xml`) is hosted on GitHub Pages; DMGs are
GitHub Release assets.

## Rules

| Id  | Rule | Test |
|-----|------|------|
| U1  | Checking is off by default; a fresh install has `Updates.enabled == false` and the default interval is 1 day. | `defaultsAreOptIn` |
| U2  | With the setting off, `start()` makes no probe and arms no timer. | `offMeansNoProbe` |
| U3  | With the setting on, `start()` probes once immediately (startup check). | `startupProbeWhenEnabled` |
| U4  | Turning the setting on probes immediately; turning it off stops all further probes. | `enablingProbesNow`, `disablingStopsProbes` |
| U5  | While enabled, probes repeat every chosen interval (a failed probe follows `UpdateScheduler`). | `probesRepeatEveryInterval` |
| U6  | The interval is one of 1 h / 6 h / 1 day / 1 week; stored values snap to the nearest preset, junk falls back to 1 day. | `intervalSnapsToPreset` |
| U7  | A probe that finds a newer version sets `availableVersion`; "up to date" clears it. | `foundUpdateIsRecorded`, `upToDateClears` |
| U8  | A failed probe records the error but keeps a previously found update. | `failureKeepsKnownUpdate` |
| U9  | `checkForUpdates()` (menu) works with the setting off; `installNow()` does nothing when no update is known. | `manualCheckWorksWhenDisabled`, `installNowNeedsKnownUpdate` |
| U10 | Probes never start Sparkle's install flow; only `checkForUpdates()`/`installNow()` do. | `probesNeverInstall` |
| U11 | Scheduler delays are never below the 60 s floor, and a successful probe waits the full interval; a failed one retries after 15 min, capped at the interval. | `schedulerFloorAndSuccessDelay`, `failureRetriesSooner` |
| U12 | `GET /api/update` reports `{enabled, available, version, releasesURL}`; it never triggers a check. | `webPayload…` |
| U13 | `/api/update` is documented in `openapi.yaml` (route conformance). | `OpenAPIConformanceTests.everyRouteIsDocumented` |
| U14 | The built Info.plist sets `SUEnableAutomaticChecks` and `SUAutomaticallyUpdate` to false and an https `SUFeedURL`. | `sparkleNeverActsOnItsOwn` |
| U15 | The Sparkle-facing engine is inert under XCTest, so tests never start Sparkle or touch the network. | `inertEngineNeverCallsSparkle` |
| U16 | Debug builds only: `defaults write … Updates.simulateVersion -string 9.9.9` makes every probe report that version (no network/Sparkle); the code is compiled out of release builds. | `simulatedEngineReportsVersion`, `simulationIsDebugOnly` |

## Manual checklist (not automatable)

1. **Release build**: Archive, notarize, run `scripts/publish-update.sh` for version N, install N-1.
2. Settings › General › Updates: turn on, see "Version N is available", main window banner, and the
   web page banner (`http://<host>:8787/`, link goes to the Releases page).
3. **Update Now** opens Sparkle's window; nothing downloads before clicking Install.
4. App menu › **Check for Updates…** works with the setting off.
5. **Relaunch under supervision**: with "Restart after crash" on, update; the new copy launches
   once (no duplicate, no handoff loop) and `launchctl print gui/$UID/com.eklynx.sound.DeFeedbackHost.supervisor`
   shows it running.
6. Offline: setting on, network off — status shows "Couldn't check", no alert, app unaffected.

## Notes

- Without `SPARKLE_PUBLIC_ED_KEY` set, the engine reports "not configured" instead of starting
  Sparkle; release builds must set it (see `scripts/publish-update.sh --help`).
- `sparkle:version` in the appcast is `CFBundleVersion` (git commit count);
  `sparkle:shortVersionString` is the marketing version.
