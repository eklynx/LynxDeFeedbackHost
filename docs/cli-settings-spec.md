# CLI-settable host settings specification

Five host settings are individual `UserDefaults` keys in the `com.eklynx.sound.DeFeedbackHost` domain so they can be read and set with `defaults`. Code: `HostPreferences` and `SettingsStore` in `DeFeedbackHost/SettingsStore.swift`; live apply in `AudioHost.applyExternalPreferences`. Tests: `HostPreferencesTests` in `DeFeedbackHostTests/SettingsStoreTests.swift`.

| Key | Type | Default | Notes |
|---|---|---|---|
| `Host.autoRunOnStartup` | bool | false | Start the plugin host automatically on launch |
| `Host.newInstancesStartMuted` | bool | false | |
| `Host.newInstancesStartBypassed` | bool | false | |
| `Host.parallelRendering` | bool | false | Locked while running |
| `Host.bufferSize` | int | `PluginConfiguration.defaultBufferSize` | Must be an offered size; locked while running |
| `Host.shutdownEnabled` | bool | false | Accept the system shutdown command (`docs/shutdown-spec.md`). Read on every command, applies immediately |
| `Host.shutdownTestMode` | bool | false (`UserDefaultsShutdownSettings.defaultTestMode`, spec SH1) | When true a shutdown command is only logged, the Mac stays up |
| `Host.shutdownPhrase` | string | `shutdown now` | Exact, case-sensitive safety phrase. An empty value reads as the default; the settings screen refuses to save an empty one. Code: `UserDefaultsShutdownSettings`. Tests: `ShutdownSettingsTests` |

```
defaults read   com.eklynx.sound.DeFeedbackHost Host.bufferSize
defaults write  com.eklynx.sound.DeFeedbackHost Host.bufferSize -int 128
defaults write  com.eklynx.sound.DeFeedbackHost Host.autoRunOnStartup -bool true
defaults delete com.eklynx.sound.DeFeedbackHost Host.autoRunOnStartup   # re-created from the app's value next launch
```

## Rules
| Id | Rule | Test |
|---|---|---|
| P1 | Saving writes each setting to its own key; the `HostSettings` blob no longer contains them | `savingWritesEachPreferenceToItsOwnKey`, `theBlobNoLongerHoldsThem` |
| P2 | An old blob that still has them migrates into the keys on first load | `anOldBlobMigratesIntoTheKeys` |
| P3 | A fresh install creates all five keys so `defaults read` works | `aFreshInstallCreatesDiscoverableDefaults` |
| P4 | An individual key wins over the blob | `anIndividualKeyBeatsTheBlob` |
| P5 | Bools accept `-bool`, 0/1, true/false/yes/no; ints accept `-int` or a numeric string | `cliStyleValuesAreUnderstood` |
| P6 | Invalid/unknown values are ignored, never fatal | `invalidValuesAreIgnoredNotFatal` |
| P7 | An in-app save never overwrites a CLI edit the app hasn't applied; in-app changes are still written | `savingNeverClobbersAnEditItHasNotSeen`, `anInAppChangeIsWritten` |
| P8 | A running app applies edits live; buffer size and parallel rendering wait until the host stops | `aRunningHostAppliesExternalEdits` |
| P9 | `SettingsStore.clear` also removes the keys | `clearingRemovesTheKeysToo` |

## Not CLI-settable (still in the `HostSettings` blob)
Device UIDs/names and sample rates, selected instance, plugin identity, per-instance settings, web server settings. Web password is in the Keychain and stays there.

## Implementation notes
- `HostSettings` still carries the five fields in memory (so the rest of the app and its tests are unchanged); only persistence changed. It now has an explicit `CodingKeys` and `encode(to:)` that omits them, while `init(from:)` still reads them from old blobs for migration.
- Deleting a key doesn't reset it to a default: the next load re-creates it from the legacy/in-memory value. Delete the key and relaunch to see it re-created; set an explicit value to change behaviour.
- Edits made while the host is running to `Host.bufferSize`/`Host.parallelRendering` are held back (the UI locks them too) and applied from `stop()`.
- Fixed a regression I introduced mid-change: corrupt blob data must still load as pristine defaults (existing test caught it).
