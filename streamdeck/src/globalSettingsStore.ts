import streamDeck from "@elgato/streamdeck";
import {GlobalSettings, PluginInstance} from "./GlobalSettings";
import {getConnector} from "./connectorState";
import type {StrengthCommand} from "./WebHostConnector";

// Global settings are stored by the Stream Deck app, so every read-modify-write is a race against the
// others (status events, dial rotation, key presses). Serialize them through a single promise chain.
let chain: Promise<unknown> = Promise.resolve();


/**
 * JSON with object keys sorted. `JSON.stringify` follows insertion order, so rebuilding an object with the
 * same values in a different key order looked like a change and wrote the settings (a full message to the
 * Stream Deck app) on every host status update.
 */
function stableStringify(value: unknown): string {
    return JSON.stringify(value, (_key, v) =>
        v && typeof v === "object" && !Array.isArray(v)
            ? Object.fromEntries(Object.entries(v as Record<string, unknown>).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)))
            : v);
}

export function updateGlobalSettings<T>(
    mutate: (settings: GlobalSettings) => T
): Promise<{ settings: GlobalSettings; result: T }> {
    const run = chain.then(async () => {
        const settings = await streamDeck.settings.getGlobalSettings<GlobalSettings>();
        const before = stableStringify(settings);
        const result = mutate(settings);
        if (stableStringify(settings) !== before) {
            await streamDeck.settings.setGlobalSettings(settings);
        }
        cachedSettings = settings;
        return {settings, result};
    });
    chain = run.catch(() => undefined);
    return run;
}

// ---------------------------------------------------------------------------------------------------
// Encoder (dial) edits
//
// A dial turn must never wait on the Stream Deck app: reading global settings is a full round trip
// to it, and doing that (serialized) per tick caps throughput at one tick per round trip, so a fast
// turn lags further and further behind. Instead, an edit lives in memory and is rendered at once;
// the host and the persisted settings are brought up to date separately, and less often.
//
// The host answers every command with a status event that carries ITS strength. An echo of an older
// command can arrive after newer ticks, so for a grace period after the last tick the host's strength
// is ignored (`activeEncoderStrength`) instead of being allowed to overwrite the dial.
// ---------------------------------------------------------------------------------------------------

/** While turning, tell the host at most this often (leading edge, then trailing). */
const SEND_INTERVAL_MS = 40;
/** Write the persisted settings once the dial has been still this long. */
const PERSIST_IDLE_MS = 250;
/** After the last tick, keep the dial's value over the host's for this long (covers late status echoes). */
const HOST_ECHO_GRACE_MS = 750;

type EncoderEdit = {
    strength: number;
    editedAt: number;
    sentStrength?: number;
    sendTimer?: NodeJS.Timeout;
    persistTimer?: NodeJS.Timeout;
};
const edits = new Map<string, EncoderEdit>();

/** The most recent global settings this plugin has read or written; lets the dial render without a round trip. */
let cachedSettings: GlobalSettings | undefined;
export function getCachedGlobalSettings(): GlobalSettings | undefined {
    return cachedSettings;
}

/** The dial's own value for an instance while an edit is fresh (or not yet sent), else undefined. */
export function activeEncoderStrength(instanceId: string): number | undefined {
    const edit = edits.get(instanceId);
    if (!edit) return undefined;
    const settled = edit.sentStrength === edit.strength;
    if (settled && Date.now() - edit.editedAt >= HOST_ECHO_GRACE_MS) {
        edits.delete(instanceId);
        return undefined;
    }
    return edit.strength;
}

/** A copy of `settings` with every active dial edit applied, so any render shows the freshest value. */
export function withEncoderEdits(settings: GlobalSettings): GlobalSettings {
    if (!settings.instances) return settings;
    let copy: GlobalSettings | undefined;
    for (const [id, instance] of Object.entries(settings.instances)) {
        const local = instance ? activeEncoderStrength(id) : undefined;
        if (instance && local !== undefined && local !== instance.strength) {
            copy ??= {...settings, instances: {...settings.instances}};
            copy.instances![id] = {...instance, strength: local};
        }
    }
    return copy ?? settings;
}

/** Applies a dial turn in memory and schedules the (throttled) host update and (debounced) persistence. Returns the new strength. */
export function turnEncoder(instanceId: string, ticks: number, currentStrength: number): number {
    const edit = edits.get(instanceId) ?? {strength: currentStrength, editedAt: 0};
    const base = activeEncoderStrength(instanceId) ?? currentStrength;
    edit.strength = Math.min(100, Math.max(0, base + ticks));
    edit.editedAt = Date.now();
    edits.set(instanceId, edit);

    scheduleSend(instanceId, edit);
    clearTimeout(edit.persistTimer);
    edit.persistTimer = setTimeout(() => {
        persistEncoder(instanceId, edit).catch((error) => streamDeck.logger.error("Failed to persist encoder edit", error));
    }, PERSIST_IDLE_MS);
    return edit.strength;
}

function scheduleSend(instanceId: string, edit: EncoderEdit): void {
    if (edit.sendTimer) return;                      // a send already happened recently; the trailing check below covers us
    sendEncoder(instanceId, edit);
    edit.sendTimer = setTimeout(() => {
        edit.sendTimer = undefined;
        if (edit.strength !== edit.sentStrength) scheduleSend(instanceId, edit);
    }, SEND_INTERVAL_MS);
}

function sendEncoder(instanceId: string, edit: EncoderEdit): void {
    const strength = edit.strength;
    const command: StrengthCommand = {type: "strength", instanceId, strength};
    const connector = getConnector();
    edit.sentStrength = strength;
    if (!connector) {
        streamDeck.logger.error("Failed to send strength command; dropping the pending edit", "No web host connector");
        edits.delete(instanceId);
        return;
    }
    connector.sendCommand(command).catch((error) => {
        // A failed edit is dropped so the host's value resyncs.
        streamDeck.logger.error("Failed to send strength command; dropping the pending edit", error);
        if (edits.get(instanceId) === edit) edits.delete(instanceId);
    });
}

async function persistEncoder(instanceId: string, edit: EncoderEdit): Promise<void> {
    await updateGlobalSettings((settings) => {
        const instance = settings.instances?.[instanceId];
        if (instance) {
            instance.strength = edit.strength;
        }
    });
}
