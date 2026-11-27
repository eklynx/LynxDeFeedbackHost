/**
 * Leaf module that wires the pure shutdown sequence to the real plugin (Stream Deck SDK, connector, global settings).
 * Actions import `keyRegistry` and `shutdownSequence` from here; it imports no action (avoids import cycles).
 * Rules: docs/shutdown-spec.md SH14-SH22; the logic itself is in ShutdownSequence.ts.
 */
import streamDeck, {KeyAction} from "@elgato/streamdeck";
import type {JsonObject} from "@elgato/utils";
import {GlobalSettings} from "../GlobalSettings";
import {getConnector} from "../connectorState";
import {hostDataUpdateEventBus, HostSettingsUpdatedEventEmitter} from "../HostSettingsUpdatedEvent";
import {KeyRegistry} from "./ShutdownKeyRegistry";
import {ShutdownSequence} from "./ShutdownSequence";
import {StreamDeckShutdownView} from "./StreamDeckShutdownView";

export const keyRegistry = new KeyRegistry<KeyAction<JsonObject>>();

export const shutdownSequence = new ShutdownSequence({
    registry: keyRegistry,
    view: new StreamDeckShutdownView(keyRegistry),
    send: async (phrase) => {
        const connector = getConnector();
        if (!connector) throw new Error("No web host connector");
        return connector.sendShutdown(phrase);
    },
    // SH22: the phrase is the shutdown action's global setting, read when the sequence succeeds.
    getPhrase: async () => (await streamDeck.settings.getGlobalSettings<GlobalSettings>()).shutdownPhrase,
    random: Math.random,
    scheduler: {setTimeout: (fn, ms) => setTimeout(fn, ms), clearTimeout: (h) => clearTimeout(h as NodeJS.Timeout)},
    log: (message, error) => error === undefined ? streamDeck.logger.info(message) : streamDeck.logger.error(message, error),
});

/** Feeds the host's `shutdown` status (carried in the global settings) to the sequence. */
export function applyGlobalSettings(settings: GlobalSettings | undefined): void {
    shutdownSequence.setStatus(settings?.shutdown);
}

hostDataUpdateEventBus.on(HostSettingsUpdatedEventEmitter.EVENT_NAME, applyGlobalSettings);
