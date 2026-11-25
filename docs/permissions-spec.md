# Permissions and warnings: spec

Source of truth in code: `DeFeedbackHost/Permissions/PermissionChecking.swift` (contract) and
`DeFeedbackHost/Warnings/AppWarning.swift`. Tests: `DeFeedbackHostTests/PermissionTests.swift`
(P1–P8) and `MainWindowSizingTests` (P9). Origin: GitHub issue #14.

## Model

The app needs three things the system makes the user approve: **Microphone** (audio input),
**Local Network** (the web control page) and **Login Items** (launch at login, restart after a
crash). At launch the app asks for what has never been asked, so the prompts come before they are
needed instead of when a settings tab is first opened. Anything not allowed is shown as a warning
in the main window, in Settings › General › Permissions, and on the web page. The warning goes
away on its own when the permission is granted, including from System Settings while the app runs
(re-checked whenever the app becomes active).

Warnings are generic (`AppWarning`): the web page shows one list, `warnings` in `GET /api/status`
and the `status` event, with the "update available" notice and permission problems in it.

## Rules

| Id | Rule | Test |
|----|------|------|
| P1 | At launch, `start()` requests only permissions that are not determined, once, in the order microphone, local network, login items. Denied ones are never re-asked. | `startRequestsOnlyUndetermined` |
| P2 | An unknown state (not yet checked, or the system couldn't say) never produces a warning. | `unknownNeverWarns` |
| P3 | A denied or not-yet-asked permission produces one warning with a stable id (`permission.<name>`); a granted one produces none. | `deniedProducesWarning` |
| P4 | `refresh()` re-checks without asking; a grant made later clears the warning. Before `start()` it does nothing. Checks never overlap: a refresh that arrives mid-check runs once, right after it. | `refreshClearsAfterGrant`, `refreshDuringCheckIsQueued` |
| P5 | Login Items is never registered by the app at launch. It is denied only when an agent the user turned on still awaits approval. | `loginItemsReportsOnly` |
| P6 | Local Network maps from the Bonjour probe: "policy denied" `-65570` is denied; `.ready` counts as granted only after a short settle period with no denial (it arrives before the user answers the prompt); no decision before the timeout is unknown. The probe delivers its result even though nothing else holds it. | `localNetworkMapping`, `probeDeliversResult`, `readyThenDeniedIsDenied`, `silentProbeIsUnknown` |
| P6b | Microphone maps from `AVAuthorizationStatus` (restricted counts as denied). | `microphoneMapping` |
| P7 | Under XCTest the checkers are inert, so a test can never raise a real prompt. | `inertCheckersNeverWarn` |
| P8 | `/api/status` carries every warning source in one `warnings` list (update and permission); a cleared condition disappears from the next payload. `OpenAPIConformanceTests` covers the schema. | `statusCarriesWarnings` |
| P10 | A denied microphone shows one bar: the app's "microphone access denied" error banner is hidden while the permissions banner already reports it, and the stale error is cleared once access is granted. | `microphoneErrorNotDuplicated` |
| P9 | The permissions banner adds to the main window's required height instead of shrinking the gallery. | `permissionsBannerAddsToRequiredHeight` |

## Manual checklist (real system prompts, not automatable)

1. **Fresh permissions**: `tccutil reset Microphone com.eklynx.sound.DeFeedbackHost`, then
   `tccutil reset All com.eklynx.sound.DeFeedbackHost` for Local Network. Launch. Both the
   Microphone and the Local Network prompts appear at launch, and neither appears when opening
   Settings › Web Host.
2. **Deny each**: the main window shows a banner row with **Open System Settings**, Settings ›
   General › Permissions shows "Not allowed", and the web page shows a warning.
3. **Grant while running**: allow it in System Settings and switch back to the app. The banner,
   the Settings row and the web warning all clear without a restart.
4. **Login Items**: turn on "Launch at login" but don't approve it in System Settings; the warning
   appears. Turn the setting off; it clears.
5. **Local Network prompt ignored**: leave the prompt unanswered. No false warning appears
   (unknown); it resolves after answering and returning to the app.

## Notes

- Local Network has no status API. The check browses for the Bonjour type `_defeedbackhost._tcp`
  (listed under `NSBonjourServices` in the merged Info.plist); the first browse raises the prompt.
  The plist is `DeFeedbackHost/Updates/SparkleInfo.plist` (arrays can't be `INFOPLIST_KEY_*`).
- Web links in warnings are https only; System Settings shortcuts exist only in the native UI.
