# Debug and tuning settings

Every setting that can be read or changed from the command line, with its purpose and how to set and
remove it. All keys live in the app's defaults domain, `com.eklynx.sound.DeFeedbackHost`.
Tests: `DebugSettingsDocTests` (fails if a key exists in code but is missing here).

```
DOMAIN=com.eklynx.sound.DeFeedbackHost

defaults read   $DOMAIN                       # everything the app has stored (includes Sparkle's own keys)
defaults read   $DOMAIN <Key>                 # one key
defaults write  $DOMAIN <Key> -bool true      # also: -int 128, -float 30, -string 9.9.9
defaults delete $DOMAIN <Key>                 # remove one key (back to its default; see per-key notes)
```

> Don't `defaults delete $DOMAIN` on its own: that wipes all of the app's settings.
> Quit the app before editing keys marked **on relaunch**; **live** keys apply to a running app.

## Debug builds only

Compiled out of release builds (enforced by `UpdateTests.simulationIsDebugOnly`).

| Key | Type | Applies | Purpose |
|---|---|---|---|
| `Updates.simulateVersion` | string | on relaunch | Makes every update probe report that version as available, with no network and no Sparkle. Lets you see the banner, Settings status, Update Now, menu item and `GET /api/update` without publishing a release. Update Now only opens the releases page. Checking must still be turned on in Settings. |

```
defaults write  $DOMAIN Updates.simulateVersion -string 9.9.9     # then relaunch the Debug build
defaults delete $DOMAIN Updates.simulateVersion                   # back to real checking, then relaunch
curl -s http://localhost:8787/api/update                          # {"available":true,"version":"9.9.9",...}
```

## Update checking (all builds)

Rules in `docs/updates-spec.md`.

| Key | Type | Default | Applies | Purpose |
|---|---|---|---|---|
| `Updates.enabled` | bool | `false` | on relaunch | Background update checking (opt-in). Same as the Settings toggle. |
| `Updates.checkInterval` | int, seconds | `86400` | on relaunch | How often to check: one of `3600`, `21600`, `86400`, `604800`. Other values snap to the nearest. |
| `Updates.channel` | string | `release` | on relaunch | Which builds to be offered: `release` (default), `prerelease` (adds not-fully-tested builds) or `nightly` (adds every build). Unknown values mean `release`. Same as the Settings picker. Changing it in Settings clears the known update and re-checks at once. |
| `Updates.lastChecked` | float, epoch seconds | none | n/a | Written by the app (shown as "Last checked"). Don't set it; delete it to clear. |

```
defaults write  $DOMAIN Updates.enabled -bool true
defaults write  $DOMAIN Updates.checkInterval -int 21600          # every 6 hours
defaults write  $DOMAIN Updates.channel -string nightly         # follow the nightly builds
defaults delete $DOMAIN Updates.channel                            # back to release builds only
defaults delete $DOMAIN Updates.enabled                            # off again (the default)
defaults delete $DOMAIN Updates.checkInterval                      # back to daily
defaults delete $DOMAIN Updates.lastChecked                        # forget the last check time
```

## Host settings (all builds)

Details and rules in `docs/cli-settings-spec.md`.

| Key | Type | Default | Applies | Purpose |
|---|---|---|---|---|
| `Host.autoRunOnStartup` | bool | `false` | live | Start the plugin host automatically on launch. |
| `Host.newInstancesStartMuted` | bool | `false` | live | New instances start muted. |
| `Host.newInstancesStartBypassed` | bool | `false` | live | New instances start bypassed. |
| `Host.parallelRendering` | bool | `false` | live, once stopped | Render instances in parallel. Held back while the host runs. |
| `Host.bufferSize` | int, frames | app default | live, once stopped | Must be an offered size (32 to 1024). Held back while the host runs. |

```
defaults write  $DOMAIN Host.bufferSize -int 128
defaults write  $DOMAIN Host.autoRunOnStartup -bool true
defaults delete $DOMAIN Host.autoRunOnStartup      # re-created from the app's current value on the next launch
```

Deleting a `Host.*` key does not reset it to its default: the app re-creates it. Write the value you want.

## Launch and crash-restart timings (all builds)

Details and rules in `docs/launch-and-restart-spec.md`. Useful for testing the stale-holder takeover
without waiting 15 seconds. Out-of-range values are clamped, never rejected.

| Key | Type | Default | Applies | Purpose |
|---|---|---|---|---|
| `Lifecycle.heartbeatInterval` | float, seconds | `2` | on relaunch | How often the running copy proves it is responsive (0.5 to 60). |
| `Lifecycle.staleAfter` | float, seconds | `15` | on relaunch | Silence before a holder counts as hung (at least 3 x heartbeat). |
| `Lifecycle.strikesBeforeKill` | int | `3` | on relaunch | Supervised launches that find the lock held before a hung holder may be killed (1 to 20). |

```
defaults write  $DOMAIN Lifecycle.staleAfter -float 30
defaults write  $DOMAIN Lifecycle.heartbeatInterval -float 1
defaults delete $DOMAIN Lifecycle.staleAfter                       # back to 15 s
```

## Environment variables and build settings

Not defaults keys. For release tooling, set in the shell (or CI), not in the app.

| Name | Used by | Purpose |
|---|---|---|
| `SKIP_NOTARIZATION=YES` | `scripts/create-dmg.sh`, Notorize DMG phase | Build a signed but un-notarized DMG (fast local runs). |
| `NOTARY_KEYCHAIN_PROFILE` | same | `notarytool` keychain profile (default `DeFeedbackHost-Notary`). |
| `SPARKLE_ED_PRIVATE_KEY` | `scripts/publish-update.sh` | Private Sparkle key for CI. Without it the key is read from the login keychain. |
| `SPARKLE_KEYCHAIN_ACCOUNT` | same | Keychain account of the Sparkle key (default `DeFeedbackHost`). |
| `SPARKLE_BIN` | same | Directory containing Sparkle's `sign_update`. |
| `GITHUB_REPO` | same | `owner/name` for download URLs (default `eklynx/LynxDeFeedbackHost`). |
| `SPARKLE_PUBLIC_ED_KEY` (build setting) | `SparkleInfo.plist` | Public half of the signing key, baked into `SUPublicEDKey`. |

## Set by the test host (don't set by hand)

`XCTestConfigurationFilePath` (environment): present when unit tests run hosted in the app. The app
skips launch policy and uses an inert update engine so tests never touch the real lock, Sparkle or the network.
