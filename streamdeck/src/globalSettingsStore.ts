import streamDeck from "@elgato/streamdeck";
import {GlobalSettings, PluginInstance} from "./GlobalSettings";
import {getConnector} from "./connectorState";
import type {StrengthCommand} from "./WebHostConnector";

// Global settings are stored by the Stream Deck app, so every read-modify-write is a race against the
// others (status events, dial rotation, key presses). Serialize them through a single promise chain.
let chain: Promise<unknown> = Promise.resolve();

export function updateGlobalSettings<T>(
    mutate: (settings: GlobalSettings) => T
): Promise<{ settings: GlobalSettings; result: T }> {
    const run = chain.then(async () => {
        const settings = await streamDeck.settings.getGlobalSettings<GlobalSettings>();
        const before = JSON.stringify(settings);
        const result = mutate(settings);
        if (JSON.stringify(settings) !== before) {
            await streamDeck.settings.setGlobalSettings(settings);
        }
        return {settings, result};
    });
    chain = run.catch(() => undefined);
    return run;
}

// An encoder edit is sent to the host once the dial has been still for this long.
const ENCODER_SETTLE_MS = 25;
let encoderTimer: NodeJS.Timeout | undefined;

export function scheduleEncoderCommit(): void {
    clearTimeout(encoderTimer);
    encoderTimer = setTimeout(() => {
        commitEncoderEdits().catch((error) => streamDeck.logger.error("Failed to commit encoder edits", error));
    }, ENCODER_SETTLE_MS);
}

async function commitEncoderEdits(): Promise<void> {
    // Collect without clearing: the pending flag must outlive the send so a status event
    // carrying the host's old strength can't overwrite the edit in between.
    const {result} = await updateGlobalSettings((settings) => {
        const now = Date.now();
        const sent: { command: StrengthCommand; editedAt: number }[] = [];
        let stillPending = false;

        for (const instance of Object.values(settings.instances ?? {}) as (PluginInstance | null)[]) {
            if (!instance?.encoderLastUpdated) continue;

            if (instance.encoderLastUpdated < now - ENCODER_SETTLE_MS) {
                sent.push({
                    command: {type: "strength", instanceId: instance.id, strength: instance.strength},
                    editedAt: instance.encoderLastUpdated
                });
            } else {
                stillPending = true;
            }
        }
        return {sent, stillPending};
    });

    if (result.stillPending) {
        scheduleEncoderCommit();
    }
    if (result.sent.length === 0) {
        return;
    }

    const outcomes = await Promise.allSettled(result.sent.map(({command}) => {
        const connector = getConnector();
        return connector ? connector.sendCommand(command) : Promise.reject(new Error("No web host connector"));
    }));
    outcomes.forEach((outcome) => {
        if (outcome.status === "rejected") {
            streamDeck.logger.error("Failed to send strength command; dropping the pending edit", outcome.reason);
        }
    });

    // Success or failure, the edit is settled; a failed one is dropped so the host's value resyncs.
    // Skip any instance the dial touched again during the send: that tick scheduled its own commit.
    await updateGlobalSettings((settings) => {
        for (const {command, editedAt} of result.sent) {
            const instance = settings.instances?.[command.instanceId];
            if (instance?.encoderLastUpdated === editedAt) {
                delete instance.encoderLastUpdated;
            }
        }
    });
}
