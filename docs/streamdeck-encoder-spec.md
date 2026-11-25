# Stream Deck encoder (dial) specification

Code: `streamdeck/src/globalSettingsStore.ts` (dial state), `streamdeck/src/actions/strength.ts` (`onDialRotate`), `streamdeck/src/WebHostConnector.ts` (`onStatusEvent`). Tests: `npm run test:encoder` in `streamdeck/` (`test/encoder-sim/`).

## Requirements
1. **No lag.** The dial shows each turn's value immediately, however slowly the Stream Deck app answers.
2. **No snap-back.** While the dial is being turned one way, its displayed value never goes backwards.
3. **No lost turns.** After the turn, the display, the host and the persisted setting all hold the final value.

## Design
- A dial turn is applied **in memory** (`turnEncoder`) and rendered at once from the cached global settings. It never waits on a `getGlobalSettings` round trip.
- The host is told at most every **40 ms** while turning (leading edge, then trailing), so audio follows the dial live and the final value is always sent.
- Persisted settings are written once the dial has been still for **250 ms**.
- The host answers every command with a status event carrying *its* strength, which can be an older command's. For **750 ms** after the last tick the dial's value wins over the host's (`activeEncoderStrength`); after that the host's value takes over again.
- Every render overlays the freshest dial value (`withEncoderEdits`), so a stale refresh can't move the display backwards.
- A failed host send drops the edit so the host's value resyncs.
- `updateGlobalSettings` compares before/after with **key-order-insensitive** JSON, so rewriting identical data never
  triggers a `setGlobalSettings` (it used to, on every host status update).
- A host status update leaves the stored strength alone while the dial is active, so it costs no write and no refresh.
- Each action's own settings are cached (`willAppear` / `didReceiveSettings`). Refreshing from the host therefore needs
  no `action.getSettings()` round trip, which also stopped the Stream Deck app's `didReceiveSettings` reply from
  triggering another forced redraw and a `getGlobalSettings` round trip for every dial.
- Each dial gets at most one screen frame per `FEEDBACK_MIN_INTERVAL_MS` (33 ms), from every source, always the latest
  value; unchanged frames and titles are not resent.
- `manifest.json` no longer sets `Nodejs.Debug`, so the plugin does not run under the Node inspector.

## Rules (each is a scenario in `test/encoder-sim/run.mjs`)
| Id | Rule | Scenarios |
|---|---|---|
| E1 | Display lag p95 ≤ 60 ms for fast turns at Stream Deck round trips of 5–40 ms | fast turn × 4 |
| E2 | No display regression for steady turns with host echoes of 60–250 ms | steady turn × 3, + hesitation |
| E3 | Display, host and persisted setting end at the final value | every scenario |
| E4 | Slow turns and hesitations (already fine before) stay fine | slow turn, hesitation |

## Limits of the simulation
Latencies are modelled, not measured on hardware. The Stream Deck app round trip, host echo delay and tick spacing are parameters; confirm on a real device by turning the dial fast and steadily while the host is running audio.

## Measured on hardware (Stream Deck +)
- The Stream Deck app delivers about 9–12 dial events a second, evenly spaced (median gap 77–118 ms, p90 ≤ 196 ms after the traffic cuts) and each bundling 3–4 ticks. The plugin handles an event in ~1 ms and the host accepts a command in ~4 ms (median).
- Reducing the plugin's outbound traffic improved event delivery once (median gap 124 → 77 ms, longest gap 784 → 287 ms); later reductions (settings writes, redraw loop, a 250 ms frame limit) did not change what is seen.
- Residual sluggishness (steppy dial, screen running on after you stop, worst when reversing) shows identically in the dial screen and the host window, which points upstream of the plugin (Stream Deck app or hardware). Not yet compared against an Elgato built-in dial.

## History
Before this design every tick did a serialized settings round trip (lag collapsed at ≥ 20 ms round trips), and the "edit pending" flag was cleared when the *send* finished rather than when the host's echo had landed, so late echoes overwrote the dial (snap-back, and lost turns).
