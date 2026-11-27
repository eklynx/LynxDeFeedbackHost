# System shutdown: spec

Source of truth in code: `DeFeedbackHost/Shutdown/ShutdownSettings.swift` and
`DeFeedbackHost/Shutdown/SystemShutdown.swift` (contract), `ShutdownPhrase.swift` (phrase rules).
API contract: `openapi.yaml` (`POST /api/shutdown`, status `shutdown` object). Origin: GitHub issue
#29, split into #30 (API), #31 (system), #32 (web page), #33 (Stream Deck). Tests are named below;
each sub-issue adds the tests for its own rules.

## Model

The app can shut down the Mac it runs on, on request from the web page or a Stream Deck key. That
is hard to undo, so every path has a safety mechanism:

- The **shutdown phrase** (an app setting, default `shutdown now`) must travel with the command.
  It is accident protection, not a secret, and is published in plain text in the status payload.
- The web page makes the user type the phrase. The Stream Deck makes the user hold the shutdown
  key and tap a changing **magic key** several times in a row.
- **Test mode** runs every check and every client flow but does not shut the Mac down.

## Rules

### Settings and phrase (#31)

| Id | Rule | Test |
|----|------|------|
| SH1 | Defaults of a fresh install: shutdown disabled; test mode **off** (opt-in; it was on while the feature was built). | `settingsDefaults` |
| SH2 | The phrase defaults to `shutdown now`, is never empty (an empty or missing stored value reads as the default) and the settings screen refuses to save an empty one. | `phraseNeverEmpty` |
| SH3 | Phrase matching is exact everywhere: case-sensitive, no trimming. | `phraseMatchesExactly` |
| SH4 | The settings are individual `UserDefaults` keys, scriptable with `defaults write` (`Host.shutdownEnabled`, `Host.shutdownTestMode`, `Host.shutdownPhrase`). | `settingsAreDefaultsKeys` |
| SH5 | The Automation (System Events) permission is reported as a warning only while shutdown is enabled and test mode is off. | `automationWarnsOnlyWhenNeeded` |

### API (#30)

| Id | Rule | Test |
|----|------|------|
| SH6 | Checks run in order: disabled (409), malformed body (400), wrong phrase (403). The first failure decides the response and nothing is shut down. | `shutdownCheckOrder` |
| SH7 | All checks passed: 202 with the status snapshot plus `test: false`, after `SystemShutdown.perform()` was called once. | `shutdownAccepted` |
| SH8 | Test mode: the same checks and a 202 with `test: true`; the computer is not shut down and the app records that it would have. | `shutdownInTestMode` |
| SH9 | If `perform()` throws, the response is 500 with a readable message. | `shutdownFailureIs500` |
| SH10 | `GET /api/status` and the `status` event carry `shutdown {enabled, testMode, phrase}`. `OpenAPIConformanceTests` covers the schema. | `statusCarriesShutdown` |

### Web page (#32)

| Id | Rule | Test |
|----|------|------|
| SH11 | The "Shutdown" section is at the bottom of the page and hidden while `shutdown.enabled` is false. | manual checklist |
| SH12 | Clicking it reveals the phrase, a text box and a Shutdown button; the button is disabled until the text matches the phrase exactly (SH3). | `webPhraseMatch` |
| SH13 | A matching phrase and a click sends `POST /api/shutdown` with the phrase. A 202 with `test: true` is shown as a test, not as shutting down; errors are shown with the server's message. | manual checklist |

### Stream Deck (#33)

| Id | Rule | Test |
|----|------|------|
| SH14 | The shutdown action is key-only. Holding it starts an attempt; releasing it before success ends the attempt with nothing sent. | `sequenceReleaseFails` |
| SH15 | While held, one other key action of ours on the same Stream Deck as the held key (SH23) is the magic key (red). Tapping it (press and release) while still holding the shutdown key makes the plugin pick the next magic key at random, different from the current one; keys may be re-used across the sequence. | `sequenceAdvances`, `sequenceNeverRepeatsCurrent` |
| SH16 | After X magic taps in a row the attempt succeeds and the plugin sends the shutdown command with the phrase. X is a setting of the shutdown action, default 5, clamped to at least 5. | `sequenceSucceedsAfterX`, `xIsClamped` |
| SH17 | Pressing any other key of ours fails the attempt. Keys that are not ours and dials are ignored. A screen or folder change while held fails the attempt. There is no time limit. | `sequenceWrongKeyFails`, `sequenceIgnoresForeignInput`, `sequencePageChangeFails` |
| SH18 | A magic tap does not run that key's normal action. | `magicTapSuppressesAction` |
| SH19 | With fewer than 2 eligible key actions on the same Stream Deck as the shutdown key (SH23), that shutdown key shows a large orange X and holds do nothing. | `tooFewKeysShowsX` |
| SH20 | When shutdown is disabled the key is grey and ignores holds. | `disabledKeyIgnoresHold` |
| SH21 | Success, failure and test results flash a checkmark or alert on the shutdown key, then every key returns to normal. A rejected phrase (empty, or different from the app's) shows the alert. A failed attempt may be restarted by holding again. | `resultFlashThenReset` |
| SH22 | The phrase the plugin sends is the shutdown action's global setting, typed in by the user. | `phraseComesFromGlobalSetting` |
| SH23 | Magic keys are only mute, bypass or strength KEY actions (never the shutdown key, never dials) that are on the **same Stream Deck device** as the shutdown key being held, and that the Stream Deck app still shows. Keys on another device are never magic and do not count towards the minimum in SH19; each shutdown key is judged on its own device. Each magic key pick writes one debug-level log line (key, tap number, holder, device, number of eligible keys), and the plugin runs at debug log level, so a sequence that stops advancing can be diagnosed from the plugin log. | `magicKeysStayOnTheHoldersDevice`, `tooFewKeysIsPerDevice`, `keysNotShowingAreNeverMagic`, `magicPicksAreLogged` |
| SH24 | The status snapshot reads the shutdown settings through a one-second cache (all three values from one snapshot), so the status loop does not read the defaults several times a second. The shutdown command never uses the cache: it reads the live settings, so a value changed a moment ago is never acted on in its old form. | `statusReadsAreServedFromTheCacheForAWhile`, `aChangeShowsUpWithinTheMaximumAge`, `aClockThatMovesBackwardsRefreshes`, `theCommandIgnoresTheCacheAndReadsTheLiveSettings` |

### Automation priming (#62)

macOS lists an app under Privacy › Automation only after it has sent an Apple event to System Events, so the permission could not be granted before the first real shutdown. Code: `Permissions/AutomationPriming.swift`.

| Id | Rule | Test |
|----|------|------|
| SH25 | While shutdown is enabled and test mode is off, the app sends one harmless, read-only System Events event (`get name`, never a shutdown) at launch, when shutdown is turned on and when test mode is turned off, so the Automation prompt appears and the app is listed ahead of time. | `primesWhenShutdownIsPossible` |
| SH26 | Nothing is sent while shutdown is disabled or test mode is on (same condition as SH5). | `doesNotPrimeWhenNotNeeded` |
| SH27 | A refused or failed event is not an error; the Automation warning (SH5) reports it. | `failureIsNotAnError` |

## Manual checklist (real shutdown, not automatable)

1. Turn test mode **on** in Settings (it is off by default). Run the web flow and the Stream Deck flow; both succeed and report a
   test, and the Mac stays up.
2. Wrong phrase from the web page is refused (403 message); disabled setting hides the web
   section and greys the key.
3. Real shutdown: set test mode **off** (the default for a fresh install), enable shutdown, grant the
   Automation prompt (it appears as soon as shutdown is enabled with test mode off, not at the first shutdown), and shut down once for real.
4. Web page (SH11, SH13): with shutdown disabled the Shutdown section is absent; enabled, it is
   collapsed at the bottom and opens on click. The button stays disabled for any near-miss (other
   case, extra space) and enables on the exact phrase. In test mode the section shows a "test mode"
   badge and a send says it was a TEST and the computer is not shutting down. A wrong phrase (change
   it in settings while the page is open) shows the server's message and the section stays usable.
   The text box clears after each send.
