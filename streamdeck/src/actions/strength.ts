import streamDeck, {
	action, DialAction, DialDownEvent, DialRotateEvent,
	DidReceiveSettingsEvent, KeyAction,
	KeyDownEvent,
	SingletonAction,
	WillAppearEvent
} from "@elgato/streamdeck";
import {formatNamed} from './helpers.js';

import fs from 'fs';
import path from 'path';
import {hostDataUpdateEventBus, HostSettingsUpdatedEventEmitter} from "../HostSettingsUpdatedEvent";
// @ts-ignore
import {ActionEvent} from "@elgato/streamdeck/types/common/events";
import {GlobalSettings} from "../GlobalSettings";
import {BypassCommand, MuteCommand, StrengthCommand} from "../WebHostConnector";
import {getConnector} from "../connectorState";
import {getCachedGlobalSettings, turnEncoder, updateGlobalSettings, withEncoderEdits} from "../globalSettingsStore";

function readStrengthKeySvgFile(): string {
	try {
		const filePath = path.join( 'imgs','actions','strength', 'strength_key.svg');
		return fs.readFileSync(filePath, 'utf8');
	} catch (error) {
		streamDeck.logger.error('Error reading file:', error);
		return 'Error';
	}
}
const fileData = readStrengthKeySvgFile();


@action({ UUID: "com.eklynx.sound.defeedback.strength" })
export class Strength extends SingletonAction<StrengthSettings> {

	private static getImageStr(strengthPercent: number | null, strengthMatches: boolean, isBypassed: boolean, isUnknown: boolean, isDisconnected: boolean, isRunning:boolean): string {
		let imgColor = strengthMatches ? "Lime" : "Red";
		if (isBypassed) { imgColor = "Blue"}
		const imgData = {
			color: imgColor,
			showMatching: strengthMatches ? "block": "none",
			strengthPercent: Number.isNaN(strengthPercent) ? "???" : strengthPercent,
			showDisconnected: isDisconnected ? "block" : "none",
			showUnknown: isUnknown && !isDisconnected && isRunning ? "block" : "none",
			showStopped: !isDisconnected && !isRunning ? "block": "none",
		}
		return `data:image/svg+xml,${encodeURIComponent(formatNamed(fileData, imgData))}`;
	}

	override async onDidReceiveSettings(ev: DidReceiveSettingsEvent<StrengthSettings>) {
		actionSettings.set(ev.action.id, ev.payload.settings);
		// The Stream Deck app also sends this event in reply to every action.getSettings() call, so it fires
		// constantly. Use the cached global settings (no round trip) and let dedupe drop an unchanged redraw;
		// a real change (instance picked in the property inspector) still differs and is drawn.
		const globalSettings: GlobalSettings = getCachedGlobalSettings() ?? await streamDeck.settings.getGlobalSettings();
		return await this.updateActionFromEvent(ev, globalSettings, true);
	}

	override async onWillAppear(ev: WillAppearEvent<StrengthSettings>) {
		actionSettings.set(ev.action.id, ev.payload.settings);
		// Always a full draw: the screen may have been reset (page or profile switch).
		const globalSettings: GlobalSettings = await streamDeck.settings.getGlobalSettings();
		return this.updateActionFromEvent(ev, globalSettings);
	}

	public static async updateActionFromExternal(action:KeyAction|DialAction, globalSettings:GlobalSettings) {
		// This action's own settings are cached from willAppear/didReceiveSettings: asking the Stream Deck app
		// for them each refresh costs a round trip and makes it answer with another didReceiveSettings event.
		const settings:StrengthSettings = actionSettings.get(action.id) ?? await action.getSettings()
		// A refresh that finds nothing new must not resend the dial's screen to the Stream Deck app.
		return this.updateActionWithSettings(action, settings, globalSettings, true);
	}

	private async updateActionFromEvent(ev: ActionEvent<StrengthSettings>, globalSettings: GlobalSettings, dedupe = false) {
		const {settings} = ev.payload;
		return Strength.updateActionWithSettings(ev.action, settings, globalSettings, dedupe);
	}

	private static async updateActionWithSettings(action:KeyAction|DialAction, settings:StrengthSettings, globalSettings: GlobalSettings, dedupe = false) {
		let targetStrength: number | null = Number(settings.strengthPercent)
		const instanceName = settings.instanceName;

		if (settings.instanceName && settings.strengthPercent) {

			if (!instanceName) {
				streamDeck.logger.error(`Invalid instance name ${instanceName}`);
			}
			if (targetStrength < 0 || targetStrength > 100) {
				targetStrength = null;
				streamDeck.logger.error(`Invalid strength value ${settings.strengthPercent}`);
			}
		}
		if (action.isKey()){
			return  Strength.updateActionImage(action, settings.instanceName ?? "", targetStrength, globalSettings);
		} else if (action.isDial()) {
			return  Strength.updateActionEncoder(action, settings.instanceName ?? "", globalSettings, dedupe);
		} else {
			streamDeck.logger.warn("Unknwon action type. ", action)
		}
	}

	private static async updateActionImage(action:KeyAction|DialAction, instanceName:string, targetStrength: number | null, globalSettings:GlobalSettings) {
		globalSettings = withEncoderEdits(globalSettings);
		const currentStrength = globalSettings.instances?.[instanceName]?.strength ?? -1;
		const isBypassed = globalSettings.instances?.[instanceName]?.isBypassed ?? false;
		const isUnknown: boolean = !globalSettings.instances?.[instanceName];
		const isDisconnected: boolean = !(getConnector()?.isConnected as boolean ?? false)
		const isRunning: boolean = globalSettings.isRunning;
		const imgStr = Strength.getImageStr(targetStrength, targetStrength == currentStrength, isBypassed, isUnknown, isDisconnected, isRunning)
		await action.setImage(imgStr);
		await action.setTitle(instanceName ?? "???");
	}

	private static async updateActionEncoder(action: DialAction, instanceName:string, globalSettings:GlobalSettings, dedupe = false) {
		// Whatever snapshot we were handed, show the dial's freshest value (a stale refresh must never move it backwards).
		globalSettings = withEncoderEdits(globalSettings);
		const currentStrength = globalSettings.instances?.[instanceName]?.strength ?? -1;
		const isBypassed = globalSettings.instances?.[instanceName]?.isBypassed ?? false;
		const isMuted = globalSettings.instances?.[instanceName]?.isMuted ?? false;
		const isUnknown: boolean = !globalSettings.instances?.[instanceName];
		const isDisconnected: boolean = !(getConnector()?.isConnected as boolean ?? false)
		const isRunning: boolean = globalSettings.isRunning;
		const prefix =
			(isMuted ? "M" : "") +
			(isBypassed ? "B" : "") +
			(isMuted || isBypassed ? " ":"");
		const valueText = isDisconnected ? "Disconnected"
			: !isRunning ? "Stopped"
			: isUnknown || currentStrength < 0 ? "Unknown"
			: `${currentStrength}%`;
		const feedback = {
			title: instanceName || "???",
			value: prefix + valueText,
			indicator: {
				value: Math.max(currentStrength, 0),
				range: {
					min: 0,
					max: 100,
				},
			},
		};
		const title = (instanceName || "???") + (isMuted ? " - Muted" : "") +  (isBypassed ? " - Bypassed" : "");
		// While the dial is turning, don't resend what the Stream Deck app already has: every message
		// competes with the dial events it is trying to deliver to us.
		const feedbackKey = JSON.stringify(feedback);
		const sends: Promise<void>[] = [];
		if (dedupe) {
			sendFeedbackLimited(action, feedback, feedbackKey);
		} else {
			lastFeedback.set(action.id, feedbackKey);
			lastFeedbackAt.set(action.id, Date.now());
			sends.push(action.setFeedback(feedback));
		}
		if (!dedupe || lastTitle.get(action.id) !== title) {
			lastTitle.set(action.id, title);
			sends.push(action.setTitle(title));
		}
		await Promise.allSettled(sends);
	}

	override async onKeyDown(ev: KeyDownEvent<StrengthSettings>): Promise<void> {
		try {
			const {settings} = ev.payload;

			if (settings.instanceName == null || settings.strengthPercent == null) {
				return;
			}
			const instanceName:string = settings.instanceName;

			let strengthPercent: number = Number(settings.strengthPercent)
			if (strengthPercent < 0 || strengthPercent > 100) {
				strengthPercent = -1;
				streamDeck.logger.error(`Invalid strength value ${ev.payload.settings.strengthPercent}`);
			}

			const {settings: globalSettings, result: found} = await updateGlobalSettings((gs) => {
				const instance = gs.instances?.[instanceName];
				if (!instance || strengthPercent < 0) {
					return false;
				}
				instance.strength = strengthPercent;
				return true;
			});

			if (found) {
				const cmd:StrengthCommand = {
					type: "strength",
					instanceId: instanceName,
					strength: strengthPercent
				}
				await Promise.allSettled([getConnector()?.sendCommand(cmd)]);
			}
			hostDataUpdateEventBus.emit(HostSettingsUpdatedEventEmitter.EVENT_NAME, globalSettings)
			await Strength.updateActionImage(ev.action, instanceName, strengthPercent, globalSettings);
		} catch (error) {
			streamDeck.logger.error("onKeyDown failed", error);
		}
	}

	override async onDialDown(ev: DialDownEvent<StrengthSettings>) {
		try {
			const {settings} = ev.payload;
			const behavior = settings.dialButtonBehavior;

			if (settings.instanceName == null || (behavior !== "mute" && behavior !== "bypass")) {
				return;
			}
			const instanceName: string = settings.instanceName;
			const {settings: globalSettings, result: cmd} = await updateGlobalSettings((gs): MuteCommand | BypassCommand | undefined => {
				const instance = gs.instances?.[instanceName];
				if (!instance) {
					return undefined;
				}
				if (behavior === "mute") {
					instance.isMuted = !(instance.isMuted ?? false);
					return {type: "mute", instanceId: instanceName, muted: instance.isMuted};
				}
				instance.isBypassed = !(instance.isBypassed ?? false);
				return {type: "bypass", instanceId: instanceName, bypassed: instance.isBypassed};
			});

			if (cmd) {
				await Promise.allSettled([getConnector()?.sendCommand(cmd)]);
			}
			hostDataUpdateEventBus.emit(HostSettingsUpdatedEventEmitter.EVENT_NAME, globalSettings)
			await Strength.updateActionEncoder(ev.action, instanceName, globalSettings);
		} catch (error) {
			streamDeck.logger.error("onDialDown failed", error);
		}
	}

	override async onDialRotate(ev: DialRotateEvent<StrengthSettings>) {
		try {
			const {settings} = ev.payload;

			if (settings.instanceName == null) {
				return;
			}
			const instanceName: string = settings.instanceName;

			// Everything below is synchronous after the first turn: no Stream Deck round trip per tick.
			let cached = getCachedGlobalSettings();
			if (!cached) {
				cached = (await updateGlobalSettings(() => undefined)).settings;
			}
			const instance = cached.instances?.[instanceName];
			if (!instance) {
				return;
			}

			turnEncoder(instanceName, ev.payload.ticks, instance.strength);
			emitToOtherActionsSoon();
			Strength.updateActionEncoder(ev.action, instanceName, cached, true)
				.catch((error: unknown) => streamDeck.logger.error("Dial render failed", error));
		} catch (error) {
			streamDeck.logger.error("onDialRotate failed", error);
		}
	}
}

type StrengthSettings = {
	instanceName?: string;
	strengthPercent?: number;
	dialButtonBehavior?: "none" | "mute" | "bypass";
};

// Each action's own settings, kept current by willAppear / didReceiveSettings.
const actionSettings = new Map<string, StrengthSettings>();

// What the dial last showed, per action, so an unchanged value isn't sent again.
const lastFeedback = new Map<string, string>();
const lastTitle = new Map<string, string>();

/**
 * Each dial gets at most one screen frame per FEEDBACK_MIN_INTERVAL_MS, from every source (turning, host
 * refreshes), and it is always the latest value: the first frame goes out at once, later ones are coalesced
 * into a trailing frame. (Tried 250 ms on the theory that the LCD queues frames and keeps moving after you
 * stop; the run-on did not change, so it is kept short for responsiveness.)
 */
export const FEEDBACK_MIN_INTERVAL_MS = 33;
type FeedbackPayload = Parameters<DialAction["setFeedback"]>[0];
const lastFeedbackAt = new Map<string, number>();
const feedbackLimiter = new Map<string, { timer?: NodeJS.Timeout; pending?: { action: DialAction; feedback: FeedbackPayload; key: string } }>();

function sendFeedbackLimited(action: DialAction, feedback: FeedbackPayload, key: string): void {
	let state = feedbackLimiter.get(action.id);
	if (!state) {
		state = {};
		feedbackLimiter.set(action.id, state);
	}
	state.pending = {action, feedback, key};
	if (state.timer) return;     // the pending frame is sent when the interval ends
	const wait = Math.max(0, FEEDBACK_MIN_INTERVAL_MS - (Date.now() - (lastFeedbackAt.get(action.id) ?? 0)));
	state.timer = setTimeout(() => {
		state.timer = undefined;
		const pending = state.pending;
		state.pending = undefined;
		if (!pending || lastFeedback.get(pending.action.id) === pending.key) return;   // nothing new to show
		lastFeedback.set(pending.action.id, pending.key);
		lastFeedbackAt.set(pending.action.id, Date.now());
		pending.action.setFeedback(pending.feedback)
			.catch((error: unknown) => streamDeck.logger.error("Dial render failed", error));
	}, wait);
}


// Other actions (keys showing the same instance) refresh from the bus; rate-limit it so a fast turn
// doesn't trigger a settings round trip per action per tick.
let busTimer: NodeJS.Timeout | undefined;
function emitToOtherActionsSoon(): void {
	if (busTimer) return;
	busTimer = setTimeout(() => {
		busTimer = undefined;
		const cached = getCachedGlobalSettings();
		if (cached) {
			hostDataUpdateEventBus.emit(HostSettingsUpdatedEventEmitter.EVENT_NAME, withEncoderEdits(cached));
		}
	}, 100);
}
