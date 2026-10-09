import streamDeck, {
	action,
	DidReceiveSettingsEvent,
	JsonObject, KeyAction,
	KeyDownEvent,
	SingletonAction,
	WillAppearEvent
} from "@elgato/streamdeck";
import {formatNamed} from './helpers.js';

import fs from 'fs';
import path from 'path';
import {hostDataUpdateEventBus, HostSettingsUpdatedEventEmitter} from "../HostSettingsUpdatedEvent";
import {GlobalSettings} from "../GlobalSettings";
import {getConnector} from "../connectorState";
import {BypassCommand} from "../WebHostConnector";

function readBypassSvgFile(): string {
	try {
		const filePath = path.join( 'imgs','actions','bypass', 'bypass.svg');
		return fs.readFileSync(filePath, 'utf8');
	} catch (error) {
		console.error('Error reading file:', error);
		return 'Error';
	}
}
const fileData = readBypassSvgFile();


@action({ UUID: "com.eklynx.sound.defeedback.bypass" })
export class Bypass extends SingletonAction<BypassSettings> {

	/// instanceNum is 1-based index, so make sure you correct it to 0-indexed when using.
	private static getImageStr(isBypassed: boolean, isDisconnected:boolean, isUnknown:boolean, isRunning:boolean): string {
		const imgData = {
			color: isBypassed || isDisconnected || isUnknown || !isRunning ? "Red" : "Lime",
			// bypass:
			showBypassed: isBypassed ? "block" : "none",
			showUnbypassed: !isBypassed ? "block": "none",
			showDisconnected: isDisconnected ? "block" : "none",
			showUnknown: isUnknown && !isDisconnected && isRunning ? "block" : "none",
			showStopped: !isDisconnected && !isRunning ? "block": "none",
		}
		return `data:image/svg+xml,${encodeURIComponent( formatNamed(fileData, imgData))}`;
	}

	override  async onDidReceiveSettings(ev: DidReceiveSettingsEvent<BypassSettings>) {
		const globalSettings: GlobalSettings = await streamDeck.settings.getGlobalSettings();
		return await Bypass.updateActionFromEvent(ev, globalSettings);
	}
	override async onWillAppear(ev: WillAppearEvent<BypassSettings>): Promise<void> {
		const globalSettings: GlobalSettings = await streamDeck.settings.getGlobalSettings();
		return await Bypass.updateActionFromEvent(ev, globalSettings);
	}


	private static async updateActionFromEvent(ev: WillAppearEvent<BypassSettings> | DidReceiveSettingsEvent<BypassSettings> | KeyDownEvent<BypassSettings>, globalSettings:GlobalSettings) {
		return Bypass.updateActionFromSettings(ev.action as KeyAction, ev.payload.settings, globalSettings);
	}

	public static async updateActionFromExternal(action: KeyAction, globalSettings:GlobalSettings) {
		return Bypass.updateActionFromSettings(action, await action.getSettings(), globalSettings);
	}

	private static async updateActionFromSettings(action:KeyAction, settings: BypassSettings, globalSettings:GlobalSettings) {
		if (settings.instanceName == null) {
			return;
		}
		await Bypass.updateActionImage(action as KeyAction, settings.instanceName, globalSettings)
	}

	private static async updateActionImage(action:KeyAction, instanceName:string, globalSettings:GlobalSettings) {
		const isBypassed: boolean = globalSettings.instances?.[instanceName]?.isBypassed ?? false;
		const isUnknown: boolean = !globalSettings.instances?.[instanceName];
		const isDisconnected: boolean = !(getConnector()?.isConnected as boolean ?? false)
		const isRunning: boolean = globalSettings.isRunning;
		const imgStr = Bypass.getImageStr(isBypassed, isDisconnected, isUnknown, isRunning)
		await action.setImage(imgStr);
		return action.setTitle(instanceName ?? "???");
	}

	override async onKeyDown(ev: KeyDownEvent<BypassSettings>): Promise<void> {
		const { settings } = ev.payload;
		if (settings.instanceName == null) { // TODO: ERROR image
			return;
		}
		let globalSettings: GlobalSettings = await streamDeck.settings.getGlobalSettings();
		const instanceName: string = settings.instanceName;

		if (globalSettings.instances?.[instanceName]) {
			const wasBypassed :boolean = globalSettings.instances[instanceName].isBypassed ?? false;
			globalSettings.instances[instanceName].isBypassed = !wasBypassed;
			let cmd:BypassCommand = {
				type: "bypass",
				instanceId: instanceName.toString(),
				bypassed: !wasBypassed
			}
			await Promise.allSettled([
				streamDeck.settings.setGlobalSettings(globalSettings),
				getConnector()?.sendCommand(cmd)
			]);
		}
		hostDataUpdateEventBus.emit(HostSettingsUpdatedEventEmitter.EVENT_NAME, globalSettings)
		return Bypass.updateActionImage(ev.action, instanceName, globalSettings);
	}
}

type BypassSettings = {
	instanceName?: string;
};
