/**
 * The real `ShutdownView` (see ShutdownSequence.ts for the contract): draws the shutdown key states and the red magic
 * key on actual Stream Deck keys. Implementation only; the rules live in ShutdownSequence.ts.
 */
import fs from "node:fs";
import path from "node:path";
import streamDeck, {KeyAction} from "@elgato/streamdeck";
import type {JsonObject} from "@elgato/utils";
import {formatNamed} from "../actions/helpers.js";
import {KeyRegistry} from "./ShutdownKeyRegistry";
import type {ShutdownKeyState, ShutdownView} from "./ShutdownSequence";
import {hostDataUpdateEventBus, HostSettingsUpdatedEventEmitter} from "../HostSettingsUpdatedEvent";
import {getCachedGlobalSettings} from "../globalSettingsStore";

function readSvg(name: string): string {
    try {
        return fs.readFileSync(path.join("imgs", "actions", "shutdown", name), "utf8");
    } catch (error) {
        console.error("Error reading file:", error);
        return "Error";
    }
}
const shutdownSvg = readSvg("shutdown.svg");
const magicSvg = readSvg("magic.svg");

const dataUri = (svg: string) => `data:image/svg+xml,${encodeURIComponent(svg)}`;

/** The SVG template variables for a key state. */
export function shutdownImage(state: ShutdownKeyState): string {
    const show = (s: ShutdownKeyState) => (state === s ? "block" : "none");
    return dataUri(formatNamed(shutdownSvg, {
        showNormal: show("normal"),
        showDisabled: show("disabled"),
        showTooFew: show("tooFewKeys"),
        showSuccess: show("success"),
        showTest: show("test"),
        showAlert: show("alert"),
    }));
}

export class StreamDeckShutdownView implements ShutdownView {
    private red: string | undefined;

    constructor(private readonly registry: KeyRegistry<KeyAction<JsonObject>>) {}

    showShutdownState(state: ShutdownKeyState, only?: string): void {
        const image = shutdownImage(state);
        for (const id of only === undefined ? this.registry.shutdownIds() : [only]) {
            const action = this.registry.handleOf(id);
            if (!action) continue;
            action.setImage(image).catch((e) => streamDeck.logger.error("Failed to draw shutdown key", e));
            action.setTitle("").catch(() => undefined);
        }
    }

    showMagicKey(id: string | null): void {
        const previous = this.red;
        this.red = id ?? undefined;
        if (id) {
            const action = this.registry.handleOf(id);
            action?.setImage(dataUri(magicSvg)).catch((e) => streamDeck.logger.error("Failed to draw magic key", e));
            action?.setTitle("").catch(() => undefined);
        }
        if (previous && previous !== id) {
            // Put the key back the way its own action draws it (the refresh listener skips only the CURRENT magic key).
            const settings = getCachedGlobalSettings();
            if (settings) hostDataUpdateEventBus.emit(HostSettingsUpdatedEventEmitter.EVENT_NAME, settings);
            else streamDeck.settings.getGlobalSettings().then((s) =>
                hostDataUpdateEventBus.emit(HostSettingsUpdatedEventEmitter.EVENT_NAME, s as never));
        }
    }
}
