import streamDeck, {
	action, DialAction,
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
import {StrengthCommand} from "../WebHostConnector";
import {getConnector} from "../connectorState";

function readStrengthKeySvgFile(): string {
	try {
		const filePath = path.join( 'imgs','actions','strength', 'strength_key.svg');
		return fs.readFileSync(filePath, 'utf8');
	} catch (error) {
		console.error('Error reading file:', error);
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

	override async onWillAppear(ev: WillAppearEvent<StrengthSettings>): Promise<void> {
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
		await Strength.updateActionImage(action, settings.instanceName ?? "", targetStrength, globalSettings);
	}

	private static async updateActionImage(action:KeyAction|DialAction, instanceName:string, targetStrength: number | null, globalSettings:GlobalSettings) {
		const currentStrength = globalSettings.instances?.[instanceName]?.strength ?? -1;
		const isBypassed = globalSettings.instances?.[instanceName]?.isBypassed ?? false;
		const isUnknown: boolean = !globalSettings.instances?.[instanceName];
		const isDisconnected: boolean = !(getConnector()?.isConnected as boolean ?? false)
		const isRunning: boolean = globalSettings.isRunning;
		const imgStr = Strength.getImageStr(targetStrength, targetStrength == currentStrength, isBypassed, isUnknown, isDisconnected, isRunning)
		await action.setImage(imgStr);
		return action.setTitle(instanceName ?? "???");
	}

	override async onKeyDown(ev: KeyDownEvent<StrengthSettings>): Promise<void> {
		const {settings} = ev.payload;

		if (settings.instanceName == null || settings.strengthPercent == null) { // TODO: ERROR image
			return;
		}
		var globalSettings: GlobalSettings = await streamDeck.settings.getGlobalSettings();
		const instanceName:string = settings.instanceName;

		let strengthPercent: number = Number(settings.strengthPercent)
		if (strengthPercent < 0 || strengthPercent > 100) {
			strengthPercent = -1;
			streamDeck.logger.error(`Invalid strength value ${ev.payload.settings.strengthPercent}`);
		}

		if (globalSettings.instances?.[instanceName] && strengthPercent >= 0) {
			globalSettings.instances[instanceName].strength = strengthPercent;

			let cmd:StrengthCommand = {
				type: "strength",
				instanceId: instanceName,
				strength: strengthPercent
			}

			await Promise.allSettled([
				streamDeck.settings.setGlobalSettings(globalSettings),
				getConnector()?.sendCommand(cmd)
			]);

		}
		hostDataUpdateEventBus.emit(HostSettingsUpdatedEventEmitter.EVENT_NAME, globalSettings)
		await Strength.updateActionImage(ev.action, instanceName, strengthPercent, globalSettings);
	}
}

type StrengthSettings = {
	instanceName?: string;
	strengthPercent?: number;
};
