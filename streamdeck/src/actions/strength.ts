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
import {scheduleEncoderCommit, updateGlobalSettings} from "../globalSettingsStore";

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
		const globalSettings: GlobalSettings = await streamDeck.settings.getGlobalSettings();
		return await this.updateActionFromEvent(ev, globalSettings);
	}

	override async onWillAppear(ev: WillAppearEvent<StrengthSettings>) {
		const globalSettings: GlobalSettings = await streamDeck.settings.getGlobalSettings();
		return this.updateActionFromEvent(ev, globalSettings);
	}

	public static async updateActionFromExternal(action:KeyAction|DialAction, globalSettings:GlobalSettings) {
		const settings:StrengthSettings = await action.getSettings()
		return this.updateActionWithSettings(action, settings, globalSettings);
	}

	private async updateActionFromEvent(ev: ActionEvent<StrengthSettings>, globalSettings: GlobalSettings) {
		const {settings} = ev.payload;
		return Strength.updateActionWithSettings(ev.action, settings, globalSettings);
	}

	private static async updateActionWithSettings(action:KeyAction|DialAction, settings:StrengthSettings, globalSettings: GlobalSettings) {
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
			return  Strength.updateActionEncoder(action, settings.instanceName ?? "", globalSettings);
		} else {
			streamDeck.logger.warn("Unknwon action type. ", action)
		}
	}

	private static async updateActionImage(action:KeyAction|DialAction, instanceName:string, targetStrength: number | null, globalSettings:GlobalSettings) {
		const currentStrength = globalSettings.instances?.[instanceName]?.strength ?? -1;
		const isBypassed = globalSettings.instances?.[instanceName]?.isBypassed ?? false;
		const isUnknown: boolean = !globalSettings.instances?.[instanceName];
		const isDisconnected: boolean = !(getConnector()?.isConnected as boolean ?? false)
		const isRunning: boolean = globalSettings.isRunning;
		const imgStr = Strength.getImageStr(targetStrength, targetStrength == currentStrength, isBypassed, isUnknown, isDisconnected, isRunning)
		await action.setImage(imgStr);
		await action.setTitle(instanceName ?? "???");
	}

	private static async updateActionEncoder(action: DialAction, instanceName:string, globalSettings:GlobalSettings) {
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
		let setFb = action.setFeedback({
			title: instanceName || "???",
			value: prefix + valueText,
			indicator: {
				value: Math.max(currentStrength, 0),
				range: {
					min: 0,
					max: 100,
				},
			},
		});
		let setTitle = action.setTitle((instanceName || "???") + (isMuted ? " - Muted" : "") +  (isBypassed ? " - Bypassed" : ""));
		await Promise.allSettled([setFb, setTitle]);
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
			const {settings: globalSettings, result: changed} = await updateGlobalSettings((gs) => {
				const instance = gs.instances?.[instanceName];
				if (!instance) {
					return false;
				}
				instance.strength = Math.min(100, Math.max(0, instance.strength + ev.payload.ticks));
				instance.encoderLastUpdated = Date.now();
				return true;
			});
			if (!changed) {
				return;
			}
			hostDataUpdateEventBus.emit(HostSettingsUpdatedEventEmitter.EVENT_NAME, globalSettings);
			scheduleEncoderCommit();
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
