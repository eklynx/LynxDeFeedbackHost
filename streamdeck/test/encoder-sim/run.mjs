// Encoder (dial) simulation: runs the REAL Strength.onDialRotate / globalSettingsStore /
// WebHostConnector.onStatusEvent / iconRefreshListener against a fake Stream Deck app and a fake host,
// on virtual time, and checks the two reported symptoms:
//   1. LAG       - the display must show each turn's value promptly.
//   2. SNAP-BACK - while turning one way, the display must never go backwards.
//
//   node test/encoder-sim/run.mjs            (exit 1 if any scenario is red)
import {mock} from "node:test";
import {fileURLToPath} from "node:url";
import {build} from "./build.mjs";

mock.timers.enable({apis: ["setTimeout", "setInterval", "Date"]});
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const drain = () => new Promise((resolve) => setImmediate(resolve));
async function advance(ms) {
    for (let i = 0; i < ms; i++) { mock.timers.tick(1); await drain(); }
}

// ---- the simulated world (all latencies in virtual ms; changed per scenario) ----
const sim = {rtt: 10, hostRtt: 20, echoDelay: 40};
let store, hostValue, shown = [], errors = [];
const actions = [];

globalThis.__sd = {
    streamDeck: {
        logger: {debug() {}, info() {}, warn() {}, setLevel() {}, error: (...a) => errors.push(a.map(String).join(" "))},
        settings: {
            // A full round trip to the Stream Deck app: the snapshot is taken when the request arrives.
            async getGlobalSettings() {
                await delay(sim.rtt / 2);
                const snapshot = JSON.parse(JSON.stringify(store));
                await delay(sim.rtt / 2);
                return snapshot;
            },
            // Fire-and-forget: resolves when sent, applied when it arrives.
            async setGlobalSettings(settings) {
                const copy = JSON.parse(JSON.stringify(settings));
                setTimeout(() => { store = copy; }, sim.rtt / 2);
            },
        },
        actions: {forEach: (fn) => actions.forEach(fn)},
    },
};

const isChild = process.argv[2] === "--one";
const bundleFile = isChild ? process.env.ENCODER_SIM_BUNDLE : await build();   // build must run from the streamdeck folder (relative tsconfig globs)
// The plugin reads its SVGs relative to the plugin folder when it is imported.
process.chdir(fileURLToPath(new URL("../../com.eklynx.sound.defeedback.sdPlugin", import.meta.url)));
let Strength, WebHostConnector, setConnector, FEEDBACK_MIN_INTERVAL_MS;
let generation = 0;
// A fresh copy of the plugin modules per scenario: the real ones keep module-level state (promise chain, timers).
async function loadPlugin() {
    ({Strength, WebHostConnector, setConnector, FEEDBACK_MIN_INTERVAL_MS} = await import(`${url(bundleFile)}?scenario=${generation++}`));
}
function url(p) { return new URL(`file://${encodeURI(p)}`).href; }

const dial = {
    manifestId: "com.eklynx.sound.defeedback.strength",
    isKey: () => false,
    isDial: () => true,
    getSettings: async () => { await delay(sim.rtt); return {instanceName: "A", dialButtonBehavior: "mute"}; },
    // The SDK resolves these when the message is SENT (no round trip), so they cost nothing here.
    setFeedback: async (fb) => { shown.push({t: Date.now(), v: fb.indicator.value}); },
    setTitle: async () => {},
};
actions.push(dial);

const connectorThis = {};
function deliverStatus(strength) {
    return WebHostConnector.prototype.onStatusEvent.call(connectorThis, {
        running: true,
        instances: [{id: "A", strength, muted: false, bypassed: false}],
    });
}
function installConnector() {
setConnector({
        isConnected: true,
        async sendCommand(command) {
            await delay(sim.hostRtt / 2);
            hostValue = command.strength;
            const snapshot = hostValue;                           // the status the host emits for this command...
            setTimeout(() => deliverStatus(snapshot), sim.echoDelay);   // ...arrives after the echo delay
            await delay(sim.hostRtt / 2);
        },
    });
}

// ---- a scenario: one continuous clockwise turn ----
async function scenario({name, ticks = 60, spacing = 12, pauseAfter = null, pause = 0, quiet = false, ...latencies}) {
    Object.assign(sim, {rtt: 10, hostRtt: 20, echoDelay: 40}, latencies);
    store = {version: 1, lastUpdated: 0, isRunning: true, hostname: "h", port: 1,
        instances: {A: {version: 1, id: "A", isMuted: false, isBypassed: false, strength: 0}}};
    hostValue = 0; shown = []; errors = [];
    await loadPlugin();
    installConnector();

    const turnTimes = [];
    const pending = [];
    for (let i = 0; i < ticks; i++) {
        turnTimes.push(Date.now());
        pending.push(new Strength().onDialRotate({payload: {settings: {instanceName: "A"}, ticks: 1}, action: dial}));
        await advance(spacing + (pauseAfter === i ? pause : 0));
    }
    // Let everything drain (a backlog can take far longer than the turn itself), then let the host's echoes land.
    let drained = false;
    Promise.allSettled(pending).then(() => { drained = true; });
    for (let waited = 0; !drained && waited < 60_000; waited += 100) await advance(100);
    await advance(2000);
    for (let i = 0; i < 20; i++) { mock.timers.runAll(); await drain(); }   // flush stragglers so nothing leaks into the next scenario

    // snap-back: any display update that is lower than an earlier one
    let high = -1; const snaps = [];
    for (const s of shown) { if (s.v < high) snaps.push({t: s.t - turnTimes[0], from: high, to: s.v}); high = Math.max(high, s.v); }

    // lag: time from each turn until the display first shows at least its value
    const lags = turnTimes.map((t, i) => {
        const hit = shown.find((s) => s.t >= t && s.v >= i + 1);
        return hit ? hit.t - t : Infinity;
    });
    const sorted = [...lags].sort((a, b) => a - b);
    const maxLag = sorted.at(-1), p95 = sorted[Math.floor(sorted.length * 0.95)];
    const finalShown = shown.at(-1)?.v;
    if (process.env.VERBOSE) console.log(`  shown: ${shown.map((x) => `${x.v}@${x.t - turnTimes[0]}`).join(" ")}`);

    const problems = [];
    if (snaps.length) problems.push(`SNAP-BACK x${snaps.length} (first: ${snaps[0].from}->${snaps[0].to} at +${snaps[0].t}ms)`);
    // The display is deliberately limited to one frame per FEEDBACK_MIN_INTERVAL_MS (the LCD can't draw faster).
    const lagLimit = FEEDBACK_MIN_INTERVAL_MS + 60;
    if (p95 > lagLimit) problems.push(`LAG p95=${p95}ms max=${maxLag}ms (limit ${lagLimit}ms)`);
    if (finalShown !== ticks) problems.push(`final display ${finalShown} != ${ticks}`);
    if (hostValue !== ticks) problems.push(`host ended at ${hostValue} != ${ticks}`);
    const persisted = store.instances.A.strength;
    if (persisted !== ticks) problems.push(`persisted setting ended at ${persisted} != ${ticks}`);
    if (errors.length) problems.push(`errors: ${errors[0]}`);
    if (!quiet) console.log(`${problems.length ? "RED  " : "GREEN"} ${name.padEnd(46)} lag p95=${String(p95).padStart(4)}ms max=${String(maxLag).padStart(4)}ms snaps=${snaps.length}${problems.length ? "  <- " + problems.join("; ") : ""}`);
    return quiet ? {snaps, p95, maxLag, finalShown, hostValue} : problems.length === 0;
}

const scenarios = [
    // LAG: the plugin must keep up with a fast turn even when the Stream Deck app is slow to answer.
    {name: "fast turn (12ms/tick), snappy SD app (rtt 5ms)", rtt: 5},
    {name: "fast turn (12ms/tick), typical SD app (rtt 10ms)", rtt: 10},
    {name: "fast turn (12ms/tick), busy SD app (rtt 20ms)", rtt: 20},
    {name: "fast turn (12ms/tick), very busy SD app (rtt 40ms)", rtt: 40},
    // SNAP-BACK: a steady turn wider than the 25ms settle window, with the host's status echo arriving late.
    {name: "steady turn (50ms/tick), echo 60ms", rtt: 5, spacing: 50, echoDelay: 60, hostRtt: 10},
    {name: "steady turn (50ms/tick), echo 120ms", rtt: 5, spacing: 50, echoDelay: 120, hostRtt: 10},
    {name: "steady turn (50ms/tick), echo 250ms", rtt: 5, spacing: 50, echoDelay: 250, hostRtt: 10},
    {name: "steady turn + hesitation, echo 120ms", rtt: 10, spacing: 50, echoDelay: 120, pauseAfter: 30, pause: 60},
    // Controls that were already fine and must stay fine.
    {name: "slow turn (40ms/tick), echo 40ms", rtt: 10, spacing: 40},
    {name: "turn with a 60ms hesitation, short echo", rtt: 10, pauseAfter: 30, pause: 60},
];

if (isChild) {
    // One scenario per process: the plugin modules keep module-level state, so this is the only airtight isolation.
    process.exit((await scenario(scenarios[Number(process.argv[3])])) ? 0 : 1);
}

if (process.env.SWEEP) {
    // Exploration: which latency combinations make the display go backwards?
    let found = 0, total = 0;
    for (const rtt of [5, 10, 20])
    for (const echoDelay of [0, 60, 120, 250])
    for (const spacing of [12, 30, 50])
    for (const pause of [0, 60]) {
        const r = await scenario({name: "sweep", quiet: true, rtt, echoDelay, hostRtt: 10, spacing, pauseAfter: pause ? 30 : null, pause});
        total++;
        if (r.snaps.length) { found++; console.log(`snap rtt=${rtt} echo=${echoDelay} spacing=${spacing} pause=${pause}: x${r.snaps.length} first ${r.snaps[0].from}->${r.snaps[0].to}`); }
    }
    console.log(`${found}/${total} combinations showed a snap-back (scenarios share a process here: use for exploration only)`);
    process.exit(0);
}

const {spawnSync} = await import("node:child_process");
let ok = true;
for (let i = 0; i < scenarios.length; i++) {
    const child = spawnSync(process.execPath, [fileURLToPath(import.meta.url), "--one", String(i)], {
        stdio: "inherit", env: {...process.env, ENCODER_SIM_BUNDLE: bundleFile},
    });
    if (child.status !== 0) ok = false;
}
console.log(ok ? "\nall green" : "\nRED: encoder simulation reproduces the reported symptoms");
process.exit(ok ? 0 : 1);
