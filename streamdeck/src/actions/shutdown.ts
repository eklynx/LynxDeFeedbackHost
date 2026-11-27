/**
 * The key-only shutdown action (docs/shutdown-spec.md SH14-SH22). It is a thin adapter: the rules live in
 * shutdown/ShutdownSequence.ts, the wiring in shutdown/shutdownRuntime.ts.
 *
 * Action settings: `magicPresses` (X, default 5, clamped to >= 5). Global setting: `shutdownPhrase`.
 */
import {
	action,
	KeyAction,
	KeyDownEvent,
	KeyUpEvent,
	SingletonAction,
	WillAppearEvent,
	WillDisappearEvent
} from "@elgato/streamdeck";
import streamDeck from "@elgato/streamdeck";
import type {JsonObject} from "@elgato/utils";
import {GlobalSettings} from "../GlobalSettings";
import {applyGlobalSettings, keyRegistry, shutdownSequence} from "../shutdown/shutdownRuntime";
import {clampMagicPresses} from "../shutdown/ShutdownSequence";

type ShutdownSettings = {
	magicPresses?: number | string;
};

@action({ UUID: "com.eklynx.sound.defeedback.shutdown" })
export class Shutdown extends SingletonAction<ShutdownSettings> {

	override async onWillAppear(ev: WillAppearEvent<ShutdownSettings>): Promise<void> {
		// Know the host's shutdown status before the first draw, so the key does not flash grey on every page change.
		applyGlobalSettings(await streamDeck.settings.getGlobalSettings<GlobalSettings>());
		keyRegistry.appear(ev.action.id, "shutdown", ev.action as KeyAction<JsonObject>, ev.action.device.id);
	}

	override onWillDisappear(ev: WillDisappearEvent<ShutdownSettings>): void {
		keyRegistry.disappear(ev.action.id);
	}

	override onKeyDown(ev: KeyDownEvent<ShutdownSettings>): void {
		shutdownSequence.shutdownKeyDown(ev.action.id, clampMagicPresses(ev.payload.settings.magicPresses));
	}

	override onKeyUp(ev: KeyUpEvent<ShutdownSettings>): void {
		shutdownSequence.shutdownKeyUp(ev.action.id);
	}
}
