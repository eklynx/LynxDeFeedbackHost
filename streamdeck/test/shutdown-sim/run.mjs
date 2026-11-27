// Shutdown simulation (docs/shutdown-spec.md SH14-SH22): runs the REAL ShutdownSequence, key registry, shutdown wiring and the
// mute/bypass/strength/shutdown actions against a stubbed Stream Deck SDK, on virtual time.
//
//   npm run test:shutdown
import assert from "node:assert/strict";
import {mock, test} from "node:test";
import {fileURLToPath} from "node:url";
import {build, shutdownBundlePath} from "../encoder-sim/build.mjs";

mock.timers.enable({apis: ["setTimeout", "setInterval", "Date"]});
const drain = () => new Promise((resolve) => setImmediate(resolve));

// ---- the fake Stream Deck app -----------------------------------------------------------------------------------
let store, errors = [], setGlobalCalls = 0;
globalThis.__sd = {
    streamDeck: {
        logger: {debug() {}, info() {}, warn() {}, setLevel() {}, error: (...a) => errors.push(a.map(String).join(" "))},
        settings: {
            getGlobalSettings: async () => JSON.parse(JSON.stringify(store)),
            setGlobalSettings: async (s) => { setGlobalCalls++; store = JSON.parse(JSON.stringify(s)); },
        },
        actions: {forEach: () => {}},
    },
};

const bundleFile = await build({entry: "build/encoder-sim/test/shutdown-sim/entry.js", out: shutdownBundlePath});
process.chdir(fileURLToPath(new URL("../../com.eklynx.sound.defeedback.sdPlugin", import.meta.url)));   // the plugin reads its SVGs relative to this folder
const m = await import(new URL(`file://${encodeURI(bundleFile)}`).href);
const {ShutdownSequence, KeyRegistry, clampMagicPresses, FLASH_MS} = m;

const ENABLED = {enabled: true, testMode: false, phrase: "shutdown now"};

// ---- pure harness: sequence + registry + recording view + scripted sender -----------------------------------------
function harness({keys = ["m1", "b1", "s1"], status = ENABLED, phrase = "typed phrase", send, random = Math.random, shutdownKeys = ["sd"]} = {}) {
    const registry = new KeyRegistry();
    const kinds = ["mute", "bypass", "strength"];
    keys.forEach((id, i) => registry.appear(id, kinds[i % 3]));
    shutdownKeys.forEach((id) => registry.appear(id, "shutdown"));
    const shown = [], magics = [], sent = [];
    const view = {showShutdownState: (s) => shown.push(s), showMagicKey: (id) => magics.push(id)};
    const seq = new ShutdownSequence({
        registry, view,
        send: send ?? (async (p) => { sent.push(p); return {test: false}; }),
        getPhrase: () => phrase,
        random,
        scheduler: {setTimeout: (fn, ms) => setTimeout(fn, ms), clearTimeout: (h) => clearTimeout(h)},
    });
    seq.setStatus(status ?? undefined);
    return {seq, registry, shown, magics, sent, view};
}
const tap = (seq, id) => { const a = seq.keyDown(id); const b = seq.keyUp(id); return a && b; };
const lastShown = (h) => h.shown.at(-1);
// A seeded generator, so a failure reproduces.
function lcg(seed = 12345) { let s = seed; return () => (s = (s * 1664525 + 1013904223) % 4294967296) / 4294967296; }

// ---- SH14 -------------------------------------------------------------------------------------------------------
test("sequenceReleaseFails: releasing the shutdown key early ends the attempt, sends nothing, and a new hold restarts", async () => {
    const h = harness();
    h.seq.shutdownKeyDown("sd", 5);
    assert.equal(h.seq.isActive, true);
    assert.ok(h.seq.magicKeyId, "a magic key is chosen on hold");
    assert.equal(h.magics.at(-1), h.seq.magicKeyId, "the magic key is shown red");
    assert.ok(tap(h.seq, h.seq.magicKeyId));
    h.seq.shutdownKeyUp("sd");
    await drain();
    assert.equal(h.seq.isActive, false);
    assert.equal(h.magics.at(-1), null, "the red key goes back to normal");
    assert.equal(lastShown(h), "alert");
    assert.deepEqual(h.sent, []);
    // later taps are ordinary presses again
    assert.equal(h.seq.keyDown("m1"), false);
    mock.timers.tick(FLASH_MS);
    h.seq.shutdownKeyDown("sd", 5);
    assert.equal(h.seq.isActive, true, "holding again restarts the attempt");
    assert.equal(h.seq.tapCount, 0);
    h.seq.shutdownKeyUp("sd");
    mock.timers.tick(FLASH_MS);
});

// ---- SH15 -------------------------------------------------------------------------------------------------------
test("sequenceAdvances: a tap on the magic key counts and moves the red key", () => {
    const h = harness({random: lcg()});
    h.seq.shutdownKeyDown("sd", 5);
    const first = h.seq.magicKeyId;
    assert.ok(["m1", "b1", "s1"].includes(first));
    // pressing is not yet a tap
    assert.equal(h.seq.keyDown(first), true);
    assert.equal(h.seq.tapCount, 0);
    assert.equal(h.seq.magicKeyId, first);
    assert.equal(h.seq.keyUp(first), true);
    assert.equal(h.seq.tapCount, 1);
    assert.notEqual(h.seq.magicKeyId, first);
    assert.equal(h.magics.at(-1), h.seq.magicKeyId);
    assert.equal(h.seq.isActive, true);
    h.seq.shutdownKeyUp("sd");
    mock.timers.tick(FLASH_MS);
});

test("sequenceNeverRepeatsCurrent: the next magic key always differs from the current one, yet keys are re-used", () => {
    for (const rng of [() => 0, () => 0.5, () => 0.999999, lcg(1), lcg(99)]) {
        const h = harness({random: rng, keys: ["m1", "b1"]});   // the tightest case: 2 eligible keys
        h.seq.shutdownKeyDown("sd", 5);
        let previous = h.seq.magicKeyId;
        const seen = new Set([previous]);
        for (let i = 0; i < 4; i++) {
            tap(h.seq, previous);
            const next = h.seq.magicKeyId;
            assert.notEqual(next, previous);
            seen.add(next);
            previous = next;
        }
        h.seq.shutdownKeyUp("sd");
        mock.timers.tick(FLASH_MS);
        assert.equal(seen.size, 2, "with two keys, both are re-used across the sequence");
    }
    // with many keys, still never the same twice in a row
    const h = harness({random: lcg(7), keys: ["a", "b", "c", "d", "e", "f"], send: async () => ({test: false})});
    h.seq.shutdownKeyDown("sd", 40);
    let previous = h.seq.magicKeyId;
    for (let i = 0; i < 39; i++) { tap(h.seq, previous); assert.notEqual(h.seq.magicKeyId, previous); previous = h.seq.magicKeyId; }
    h.seq.shutdownKeyUp("sd");
    mock.timers.tick(FLASH_MS);
});

// ---- SH16 -------------------------------------------------------------------------------------------------------
test("sequenceSucceedsAfterX: X taps in a row send the phrase once, then the key shows success and resets", async () => {
    const h = harness({random: lcg(3)});
    h.seq.shutdownKeyDown("sd", 7);
    for (let i = 0; i < 6; i++) tap(h.seq, h.seq.magicKeyId);
    await drain();
    assert.deepEqual(h.sent, [], "not before the Xth tap");
    assert.equal(h.seq.isActive, true);
    tap(h.seq, h.seq.magicKeyId);
    await drain();
    assert.deepEqual(h.sent, ["typed phrase"]);
    assert.equal(h.seq.isActive, false);
    assert.equal(h.magics.at(-1), null);
    assert.equal(lastShown(h), "success");
    h.seq.shutdownKeyUp("sd");   // letting go afterwards does nothing
    assert.deepEqual(h.sent, ["typed phrase"]);
    mock.timers.tick(FLASH_MS);
    assert.equal(lastShown(h), "normal");
});

test("xIsClamped: X defaults to 5 and is never below 5", async () => {
    assert.equal(clampMagicPresses(undefined), 5);
    assert.equal(clampMagicPresses(null), 5);
    assert.equal(clampMagicPresses(""), 5);
    assert.equal(clampMagicPresses("abc"), 5);
    assert.equal(clampMagicPresses(NaN), 5);
    for (const low of [4, 3, 1, 0, -2, "2"]) assert.equal(clampMagicPresses(low), 5, `${low}`);
    assert.equal(clampMagicPresses(5), 5);
    assert.equal(clampMagicPresses(8), 8);
    assert.equal(clampMagicPresses("12"), 12);
    assert.equal(clampMagicPresses(6.9), 6);

    // and the sequence enforces it even if a caller passes a small number
    const h = harness();
    h.seq.shutdownKeyDown("sd", 2);
    for (let i = 0; i < 4; i++) tap(h.seq, h.seq.magicKeyId);
    await drain();
    assert.deepEqual(h.sent, [], "4 taps are not enough for X=2 (clamped to 5)");
    tap(h.seq, h.seq.magicKeyId);
    await drain();
    assert.equal(h.sent.length, 1);
    mock.timers.tick(FLASH_MS);
});

// ---- SH17 -------------------------------------------------------------------------------------------------------
test("sequenceWrongKeyFails: pressing another key of ours (or another shutdown key) fails the attempt", async () => {
    const h = harness({shutdownKeys: ["sd", "sd2"]});
    h.seq.shutdownKeyDown("sd", 5);
    const wrong = ["m1", "b1", "s1"].find((id) => id !== h.seq.magicKeyId);
    assert.equal(h.seq.keyDown(wrong), true, "the press is consumed (its normal action must not run)");
    assert.equal(h.seq.isActive, false);
    assert.equal(lastShown(h), "alert");
    assert.equal(h.magics.at(-1), null);
    mock.timers.tick(FLASH_MS);

    h.seq.shutdownKeyDown("sd", 5);
    h.seq.shutdownKeyDown("sd2", 5);   // another shutdown key
    assert.equal(h.seq.isActive, false);
    assert.deepEqual(h.sent, []);
    mock.timers.tick(FLASH_MS);
});

test("sequenceIgnoresForeignInput: unknown keys and dials change nothing", async () => {
    const h = harness();
    h.seq.shutdownKeyDown("sd", 5);
    const magic = h.seq.magicKeyId;
    assert.equal(h.seq.keyDown("someone-elses-key"), false, "not consumed: not ours");
    assert.equal(h.seq.keyUp("someone-elses-key"), false);
    assert.equal(h.seq.isActive, true);
    assert.equal(h.seq.magicKeyId, magic);
    assert.equal(h.seq.tapCount, 0);
    h.seq.shutdownKeyUp("someone-elses-key");   // a release that is not the shutdown key's
    assert.equal(h.seq.isActive, true);
    h.seq.shutdownKeyUp("sd");
    mock.timers.tick(FLASH_MS);

    // The real strength action: a DIAL never registers, so it can neither be a magic key nor fail an attempt.
    resetRuntime();
    const registry = m.keyRegistry;
    const dial = fakeAction("dial1", "com.eklynx.sound.defeedback.strength", {instanceName: "A"}, {key: false});
    await new m.Strength().onWillAppear({action: dial, payload: {settings: {instanceName: "A"}}});
    assert.equal(registry.has("dial1"), false);
    const key = fakeAction("k1", "com.eklynx.sound.defeedback.strength", {instanceName: "A", strengthPercent: 50});
    await new m.Strength().onWillAppear({action: key, payload: {settings: {instanceName: "A"}}});
    assert.deepEqual(registry.eligibleIds(), ["k1"], "only the key is eligible");
    resetRuntime();
});

test("sequencePageChangeFails: any key appearing or disappearing mid-hold fails the attempt", () => {
    const h = harness();
    h.seq.shutdownKeyDown("sd", 5);
    h.registry.disappear(h.seq.magicKeyId);
    assert.equal(h.seq.isActive, false);
    assert.equal(lastShown(h), "alert");
    assert.equal(h.magics.at(-1), null);
    mock.timers.tick(FLASH_MS);

    const h2 = harness();
    h2.seq.shutdownKeyDown("sd", 5);
    h2.registry.appear("new-page-key", "mute");
    assert.equal(h2.seq.isActive, false);
    assert.deepEqual(h2.sent, []);
    mock.timers.tick(FLASH_MS);
});

// ---- SH19 / SH20 ------------------------------------------------------------------------------------------------
test("tooFewKeysShowsX: under 2 eligible keys the key shows the orange X and holds do nothing", () => {
    const h = harness({keys: ["m1"]});
    assert.equal(h.seq.state(), "tooFewKeys");
    assert.equal(lastShown(h), "tooFewKeys");
    h.seq.shutdownKeyDown("sd", 5);
    assert.equal(h.seq.isActive, false);
    assert.deepEqual(h.magics, []);
    // The shutdown key itself, and keys of other kinds, do not count as eligible.
    h.registry.appear("sd2", "shutdown");
    assert.equal(h.seq.state(), "tooFewKeys");
    h.registry.appear("b1", "bypass");
    assert.equal(h.seq.state(), "normal");
    assert.equal(lastShown(h), "normal");
    h.registry.disappear("b1");
    assert.equal(lastShown(h), "tooFewKeys");
    const none = harness({keys: []});
    assert.equal(none.seq.state(), "tooFewKeys");

    // the picture really has the large orange X
    const svg = decodeURIComponent(m.shutdownImage("tooFewKeys").split(",")[1]);
    assert.match(svg, /<g display="block">\s*<use href="#power"[^>]*stroke="#6b6b6b"\/>\s*<g stroke="darkorange"/);
});

test("disabledKeyIgnoresHold: shutdown disabled (or unknown) greys the key and ignores holds", () => {
    const off = harness({status: {...ENABLED, enabled: false}});
    assert.equal(off.seq.state(), "disabled");
    assert.equal(lastShown(off), "disabled");
    off.seq.shutdownKeyDown("sd", 5);
    assert.equal(off.seq.isActive, false);
    const unknown = harness({status: null});
    assert.equal(unknown.seq.state(), "disabled");
    unknown.seq.shutdownKeyDown("sd", 5);
    assert.equal(unknown.seq.isActive, false);
    // enabling later wakes the key up; disabling mid-attempt fails it
    unknown.seq.setStatus(ENABLED);
    assert.equal(lastShown(unknown), "normal");
    unknown.seq.shutdownKeyDown("sd", 5);
    assert.equal(unknown.seq.isActive, true);
    unknown.seq.setStatus({...ENABLED, enabled: false});
    assert.equal(unknown.seq.isActive, false);
    mock.timers.tick(FLASH_MS);
    assert.equal(lastShown(unknown), "disabled");
});

// ---- SH21 -------------------------------------------------------------------------------------------------------
async function succeedWith(h, x = 5) {
    h.seq.shutdownKeyDown("sd", x);
    for (let i = 0; i < x; i++) tap(h.seq, h.seq.magicKeyId);
    await drain();
}

test("resultFlashThenReset: every outcome flashes on the shutdown key, then everything returns to normal", async () => {
    // success
    let h = harness();
    await succeedWith(h);
    assert.equal(lastShown(h), "success");
    mock.timers.tick(FLASH_MS - 1);
    assert.equal(lastShown(h), "success");
    mock.timers.tick(1);
    assert.equal(lastShown(h), "normal");
    assert.equal(h.magics.at(-1), null);

    // a 202 with test:true is a distinct "test" result
    h = harness({send: async () => ({test: true})});
    await succeedWith(h);
    assert.equal(lastShown(h), "test");
    mock.timers.tick(FLASH_MS);
    assert.equal(lastShown(h), "normal");

    // API rejection (403 / 409 / 500) and network failure
    for (const message of ["Host rejected shutdown command (403)", "(409)", "(500)", "connect ECONNREFUSED"]) {
        h = harness({send: async () => { throw new Error(message); }});
        await succeedWith(h);
        assert.equal(lastShown(h), "alert", message);
        mock.timers.tick(FLASH_MS);
        assert.equal(lastShown(h), "normal");
    }

    // empty phrase: nothing is sent
    h = harness({phrase: ""});
    await succeedWith(h);
    assert.equal(lastShown(h), "alert");
    assert.deepEqual(h.sent, []);
    mock.timers.tick(FLASH_MS);

    // failed attempt flashes too, and can be restarted straight away
    h = harness();
    h.seq.shutdownKeyDown("sd", 5);
    h.seq.shutdownKeyUp("sd");
    assert.equal(lastShown(h), "alert");
    h.seq.shutdownKeyDown("sd", 5);
    assert.equal(h.seq.isActive, true);
    assert.equal(lastShown(h), "normal", "a new hold clears the flash");
    h.seq.shutdownKeyUp("sd");
    mock.timers.tick(FLASH_MS);
    assert.equal(lastShown(h), "normal");
});

// ---- the real actions, through the runtime singleton ------------------------------------------------------------
function fakeAction(id, manifestId, settings, {key = true} = {}) {
    return {
        id, manifestId, images: [], titles: [],
        isKey: () => key, isDial: () => !key,
        setImage(img) { this.images.push(img); return Promise.resolve(); },
        setTitle(t) { this.titles.push(t); return Promise.resolve(); },
        setFeedback() { return Promise.resolve(); }, setFeedbackLayout() { return Promise.resolve(); },
        getSettings: async () => settings,
    };
}
let commands = [], shutdownCalls = [];
function resetRuntime() {
    m.keyRegistry.clear();
    mock.timers.tick(FLASH_MS * 2);
    store = {
        version: 1, lastUpdated: 0, isRunning: true, hostname: "h", port: 1,
        shutdown: {...ENABLED}, shutdownPhrase: "typed in the PI",
        instances: {A: {version: 1, id: "A", isMuted: false, isBypassed: false, strength: 10}, B: {version: 1, id: "B", isMuted: false, isBypassed: false, strength: 10}},
    };
    commands = []; shutdownCalls = []; errors = []; setGlobalCalls = 0;
    m.setConnector({
        isConnected: true,
        sendCommand: async (c) => { commands.push(c); },
        sendShutdown: async (phrase) => { shutdownCalls.push(phrase); return {test: false}; },
    });
    m.applyGlobalSettings(store);
}
async function appear(action, Cls, settings) {
    await new Cls().onWillAppear({action, payload: {settings}});
}

test("magicTapSuppressesAction: tapping the magic key runs neither its press nor its release behaviour", async () => {
    resetRuntime();
    const muteA = fakeAction("muteA", "com.eklynx.sound.defeedback.mute", {instanceName: "A"});
    const bypassB = fakeAction("bypassB", "com.eklynx.sound.defeedback.bypass", {instanceName: "B"});
    const sd = fakeAction("sd", "com.eklynx.sound.defeedback.shutdown", {});
    await appear(muteA, m.Mute, {instanceName: "A"});
    await appear(bypassB, m.Bypass, {instanceName: "B"});
    await appear(sd, m.Shutdown, {});
    const actions = {muteA: [muteA, new m.Mute(), {instanceName: "A"}], bypassB: [bypassB, new m.Bypass(), {instanceName: "B"}]};
    const press = (id) => { const [a, impl, s] = actions[id]; return impl.onKeyDown({action: a, payload: {settings: s}}); };
    const release = (id) => { const [a, impl, s] = actions[id]; return impl.onKeyUp({action: a, payload: {settings: s}}); };

    // without an attempt, a press is the normal action
    await press("muteA");
    assert.equal(commands.length, 1);
    assert.equal(commands[0].type, "mute");
    commands = [];
    resetRuntime();
    await appear(muteA, m.Mute, {instanceName: "A"});
    await appear(bypassB, m.Bypass, {instanceName: "B"});
    await appear(sd, m.Shutdown, {});

    // hold the shutdown key, tap the magic key: no command, no settings write
    new m.Shutdown().onKeyDown({action: sd, payload: {settings: {magicPresses: 5}}});
    const writesBefore = setGlobalCalls;
    for (let i = 0; i < 4; i++) {
        const magic = m.shutdownSequence.magicKeyId;
        assert.ok(magic in actions, "the magic key is one of our mute/bypass keys");
        await press(magic);
        await release(magic);
    }
    assert.deepEqual(commands, [], "no mute/bypass command was sent by magic taps");
    assert.equal(setGlobalCalls, writesBefore, "no settings were changed by magic taps");
    assert.equal(store.instances.A.isMuted, false);
    assert.equal(store.instances.B.isBypassed, false);
    assert.equal(m.shutdownSequence.tapCount, 4);

    // a wrong press fails the attempt and is not executed either
    const wrong = Object.keys(actions).find((id) => id !== m.shutdownSequence.magicKeyId);
    await press(wrong);
    assert.deepEqual(commands, []);
    assert.equal(m.shutdownSequence.isActive, false);
    resetRuntime();
});

test("phraseComesFromGlobalSetting: the plugin sends the shutdown action's global phrase, not the app's", async () => {
    // pure: the injected phrase source decides
    const h = harness({phrase: "my own phrase", status: {...ENABLED, phrase: "the app phrase"}});
    await succeedWith(h);
    assert.deepEqual(h.sent, ["my own phrase"]);
    mock.timers.tick(FLASH_MS);

    // through the real wiring: global setting `shutdownPhrase` -> connector.sendShutdown
    resetRuntime();
    store.shutdown.phrase = "the app phrase";
    const a = fakeAction("muteA", "com.eklynx.sound.defeedback.mute", {instanceName: "A"});
    const b = fakeAction("muteB", "com.eklynx.sound.defeedback.mute", {instanceName: "B"});
    const sd = fakeAction("sd", "com.eklynx.sound.defeedback.shutdown", {});
    await appear(a, m.Mute, {instanceName: "A"});
    await appear(b, m.Mute, {instanceName: "B"});
    await appear(sd, m.Shutdown, {});
    const impl = {muteA: [a, {instanceName: "A"}], muteB: [b, {instanceName: "B"}]};
    const mute = new m.Mute();
    const shutdown = new m.Shutdown();
    shutdown.onKeyDown({action: sd, payload: {settings: {}}});   // X unset: default 5
    for (let i = 0; i < 5; i++) {
        const [act, s] = impl[m.shutdownSequence.magicKeyId === "muteA" ? "muteA" : "muteB"];
        await mute.onKeyDown({action: act, payload: {settings: s}});
        mute.onKeyUp({action: act, payload: {settings: s}});
    }
    await drain();
    assert.deepEqual(shutdownCalls, ["typed in the PI"]);
    assert.equal(commands.length, 0);
    assert.equal(sd.images.length > 0, true);
    mock.timers.tick(FLASH_MS);

    // an empty global phrase is refused locally (alert), nothing is sent
    resetRuntime();
    store.shutdownPhrase = "";
    await appear(a, m.Mute, {instanceName: "A"});
    await appear(b, m.Mute, {instanceName: "B"});
    await appear(sd, m.Shutdown, {});
    shutdown.onKeyDown({action: sd, payload: {settings: {magicPresses: 5}}});
    for (let i = 0; i < 5; i++) {
        const [act, s] = impl[m.shutdownSequence.magicKeyId === "muteA" ? "muteA" : "muteB"];
        await mute.onKeyDown({action: act, payload: {settings: s}});
        mute.onKeyUp({action: act, payload: {settings: s}});
    }
    await drain();
    assert.deepEqual(shutdownCalls, []);
    resetRuntime();
});

test("statusCarriesShutdown: the connector copies the host's shutdown object into the global settings", async () => {
    resetRuntime();
    delete store.shutdown;
    const connector = Object.create(m.WebHostConnector.prototype);
    await connector.onStatusEvent({running: true, instances: [], shutdown: {enabled: true, testMode: true, phrase: "shutdown now"}});
    assert.deepEqual(store.shutdown, {enabled: true, testMode: true, phrase: "shutdown now"});
    assert.equal(store.version, 1, "the settings version is untouched");
    await connector.onStatusEvent({running: true, instances: []});   // an older host: no object
    assert.equal(store.shutdown, undefined);
    resetRuntime();
});
