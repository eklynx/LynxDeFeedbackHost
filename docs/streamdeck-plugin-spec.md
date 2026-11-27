# Stream Deck plugin status (issue #64)

Contract and source of truth: `DeFeedbackHost/StreamDeckPlugin/StreamDeckPluginChecking.swift`.
Tests: `DeFeedbackHostTests/StreamDeckPluginTests.swift`.

## Scope

The app ships a Stream Deck plugin; Stream Deck keeps its own installed copy, which goes stale when the app is
updated. The app does two things about that:

1. **Auto-update (on by default).** At launch, if the plugin is installed and older than the packaged one, and the
   setting `Host.streamDeckAutoUpdate` (a toggle on the Stream Deck tab) is on, the app replaces it using Elgato's
   `streamdeck` CLI: `streamdeck stop <uuid>`, overwrite `~/Library/Application Support/com.elgato.StreamDeck/Plugins/<uuid>.sdPlugin`
   from the packaged `.streamDeckPlugin`, then `streamdeck restart <uuid>` (uuid `com.eklynx.sound.defeedback`).
   It only runs while the Stream Deck app is running. If the CLI isn't found (PATH, then Homebrew, `/usr/local`, npm
   user prefixes, Volta, every nvm Node version) or any step fails, the folder is left alone (see SP14 for the one
   exception: a failed restart after a successful swap) and the warning below shows with the reason.
2. **Warning / error.** With the setting off, or when the update didn't work, the app reports an out-of-date plugin
   as a warning and one below the minimum compatible version as an error. The reports use the shared warnings
   pipeline (`Warnings/AppWarning.swift`): main-window banner, web page and `/api/status`, plus rows on the
   Settings › StreamDeck tab. A new `severity` (`warning` | `error`) was added to every warning.

The Install/Update button in the settings tab (opens the plugin in Stream Deck, which asks for confirmation) stays.

## Rules

| Id | Rule | Test |
|----|------|------|
| SP1 | A plugin version is one to four dot-separated non-negative integers, compared numerically part by part, missing parts counting as 0. Anything else is not a version. | `versionComparison`, `invalidVersions` |
| SP2 | The installed version comes from `<Stream Deck>/Plugins/com.eklynx.sound.defeedback.sdPlugin/manifest.json`, the packaged one from the manifest inside the bundled `.streamDeckPlugin` zip (`/usr/bin/unzip -p`). Missing, malformed or unreadable is unknown. The manifest we ship parses and is not below the minimum. | `installedVersionFromManifest`, `packagedVersionFromZip`, `repositoryManifestParses` |
| SP3 | Plugin not installed, or no check finished yet: no warning. | `notInstalledNeverWarns` |
| SP4 | Installed older than packaged: one warning `streamDeckPlugin.outOfDate`, severity `warning`, naming both versions. | `outOfDateWarns` |
| SP5 | Installed older than `StreamDeckPluginStatus.minimumCompatibleVersion`: one warning `streamDeckPlugin.incompatible`, severity `error`, even when the packaged version is unknown. It replaces out-of-date. Raise the minimum only when the app/plugin protocol breaks (when `WebControlService.protocolVersion` is bumped). | `incompatibleIsAnError` |
| SP6 | Installed equal to or newer than packaged, or packaged unknown: no warning. | `currentNeverWarns` |
| SP7 | `/api/status` carries the plugin warning (`kind: streamDeckPlugin`), every warning has a `severity` (default `warning`), and `openapi.yaml` documents both. | `statusCarriesSeverity`, `openAPIDocumentsSeverity` |
| SP8 | `refresh()` runs at launch, whenever the app becomes active and when the Stream Deck tab appears. Installing the new plugin clears the warning at the next refresh. Refreshes never overlap; one that arrives mid-check runs once more. | `refreshClearsAfterUpdate`, `overlappingRefreshIsQueued` |
| SP9 | Under XCTest the locator is inert, so tests never read the real Stream Deck folder. | `inertLocatorNeverWarns` |
| SP11 | `Host.streamDeckAutoUpdate` is on for a fresh install, accepts a bool or `yes/no/true/false/1/0` strings, and a typo reads as the default. | `settingDefaultsOn` |
| SP12 | At launch (`StreamDeckPluginService.start()`, once) an installed plugin older than the packaged one (including an incompatible one, when the packaged version is known) is handed to the installer, then re-checked; success shows nothing. Never for a plugin that isn't installed, is current or newer, or has no known packaged version; `refresh()` never installs. | `launchUpdatesOutOfDatePlugin`, `launchUpdatesIncompatiblePlugin`, `noInstallWhenNothingToUpdate` |
| SP13 | With the setting off nothing is installed; the warning (or error) shows. | `settingOffOnlyWarns` |
| SP14 | The CLI installer: preconditions (Stream Deck running, packaged zip, CLI found, plugin installed) touch nothing; the zip is unpacked to a scratch folder first; `stop` must succeed before the installed folder is replaced; then `restart`. A failed stop or unpack leaves the folder untouched; a failed restart after the swap reports "updated, restart Stream Deck". The CLI is found on PATH or the usual npm locations and run with its own folder first on PATH (it's a Node script). | `replacesInstalledPlugin`, `appFacingInstaller`, `preconditionsTouchNothing`, `stopFailureLeavesFolder`, `badZipStopsEarly`, `restartFailureIsReported`, `findsFirstExecutable`, `defaultSearchOrder` |
| SP16 | The packaged plugin only looks older than the installed one if its manifest version rises. The release, nightly and pre-release builds stamp `plugin_version` (changes only when the plugin code changes) into the manifest before the archive, and the release run fails if the plugin in the app differs. Local builds keep the repository's manifest and never downgrade an installed plugin. | docs/versioning-spec.md V14 to V19 (`PluginVersionOutputTests`, `PluginVersionStampTests`) |
| SP17 | An installed plugin newer than the packaged one (e.g. a nightly with the lower `X.Y.Z` after a pre-release) is `.newerThanPackaged`: one warning (`streamDeckPlugin.newerThanPackaged`) telling the user to press Install/Update Stream Deck Plugin in Settings › StreamDeck. It is never replaced automatically. | `newerThanPackagedWarns`, `noInstallWhenNothingToUpdate` |
| SP15 | A failed update (`.failed(reason)`) is tried once per launch, keeps the warning/error and adds the reason to its message; `.notAvailable` keeps it without a reason. | `failureKeepsWarning` |
| SP10 | The banner adds to the main window's required height instead of shrinking the gallery. | `bannerAddsToRequiredHeight` |

## Manual checklist (needs a real Stream Deck install)

1. Install the plugin from Settings › StreamDeck, relaunch the app: no plugin warning.
   (Auto-update needs Elgato's CLI: `npm install -g @elgato/cli`.)
2. Turn "Update the plugin automatically" off, lower the installed manifest `Version`, relaunch the app: a warning in the main window, on the web page and on the StreamDeck tab,
   naming both versions.
3. Turn it on and relaunch with Stream Deck running: the plugin is stopped, replaced and restarted without a
   prompt, and the warning is gone. Check the Stream Deck keys still work afterwards.
4. Repeat with Stream Deck not running, and with the CLI uninstalled: nothing is replaced and the warning says why.
5. Lower the installed manifest `Version` below the minimum with the setting off: the message is a red error.
