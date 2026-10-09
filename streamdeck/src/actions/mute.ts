import streamDeck, {
	action,
	DidReceiveSettingsEvent, KeyAction,
	KeyDownEvent,
	SingletonAction,
	WillAppearEvent
} from "@elgato/streamdeck";
import { formatNamed } from './helpers.js';

import fs from 'fs';
import path from 'path';
import {Key} from "node:readline";
import {GlobalSettings} from "../GlobalSettings";
import {BypassCommand, MuteCommand} from "../WebHostConnector";
import {getConnector} from "../connectorState";
import {hostDataUpdateEventBus, HostSettingsUpdatedEventEmitter} from "../HostSettingsUpdatedEvent";

function readMuteSvgFile(): string {
	try {
		const filePath = path.join( 'imgs','actions','mute', 'mute.svg');
		return fs.readFileSync(filePath, 'utf8');
	} catch (error) {
		console.error('Error reading file:', error);
		return 'Error';
	}
}
const fileData = readMuteSvgFile();


@action({ UUID: "com.eklynx.sound.defeedback.mute" })
export class Mute extends SingletonAction<MuteSettings> {

	private static getImageStr(isMuted :boolean, isDisconnected: boolean, isUnknown: boolean, isRunning: boolean):string {
		const imgData = {
			color: isMuted || isDisconnected || isUnknown || !isRunning ? "Red" : "Lime",
			// mute:
			showMuted: isMuted ? "block" : "none",
			showUnmuted: !isMuted ? "block" : "none",
			showDisconnected: isDisconnected ? "block" : "none",
			showUnknown: isUnknown && !isDisconnected && isRunning ? "block" : "none",
			showStopped: !isDisconnected && !isRunning ? "block": "none",
		}
		return `data:image/svg+xml,${encodeURIComponent( formatNamed(fileData, imgData))}`;
	}

	override async onDidReceiveSettings(ev: DidReceiveSettingsEvent<MuteSettings>) {
		const globalSettings: GlobalSettings = await streamDeck.settings.getGlobalSettings();
		return await this.updateActionFromEvent(ev, globalSettings);
	}
	override async onWillAppear(ev: WillAppearEvent<MuteSettings>): Promise<void> {
		const globalSettings: GlobalSettings = await streamDeck.settings.getGlobalSettings();
		return await this.updateActionFromEvent(ev, globalSettings);
	}


	private async updateActionFromEvent(ev :WillAppearEvent<MuteSettings>
									| DidReceiveSettingsEvent<MuteSettings>
									| KeyDownEvent<MuteSettings>
							   , globalSettings:GlobalSettings) {
		return Mute.updateActionFromSettings(ev.action as KeyAction, ev.payload.settings, globalSettings);
	}

	private static async updateActionFromSettings(action: KeyAction, settings:MuteSettings, globalSettings:GlobalSettings) {

		if (settings.instanceName) {

			const instanceName = settings.instanceName ?? "";
			if (!globalSettings.instances?.[instanceName]) {
				streamDeck.logger.error(`Invalid instance ${settings.instanceName}`);
			}
		}
		return Mute.updateActionImage(action as KeyAction, settings.instanceName ?? "", globalSettings);
	}

	public static async updateActionFromExternal(action: KeyAction, globalSettings:GlobalSettings) {
		return Mute.updateActionFromSettings(action, await action.getSettings(), globalSettings);
	}

	private static async updateActionImage(action:KeyAction, instanceName:string, globalSettings:GlobalSettings) {
		const isMuted: boolean = globalSettings.instances?.[instanceName]?.isMuted ?? false;
		const isUnknown: boolean = !globalSettings.instances?.[instanceName];
		const isDisconnected: boolean = !(getConnector()?.isConnected as boolean ?? false);
		const isRunning: boolean = globalSettings.isRunning;
		const imgStr = Mute.getImageStr(isMuted, isDisconnected, isUnknown, isRunning)
		await action.setImage(imgStr);
		return action.setTitle(instanceName ?? "???");
	}

	override async onKeyDown(ev: KeyDownEvent<MuteSettings>): Promise<void> {
		const { settings } = ev.payload;

		if (settings.instanceName == null) { // TODO: ERROR image
			return;
		}
		const instanceName:string = settings.instanceName;
		var globalSettings: GlobalSettings = await streamDeck.settings.getGlobalSettings();


		if (globalSettings.instances?.[instanceName]) {
			const wasMuted :boolean = globalSettings.instances[instanceName].isMuted ?? false;
			globalSettings.instances[instanceName].isMuted = !wasMuted;

			let cmd:MuteCommand = {
				type: "mute",
				instanceId: instanceName,
				muted: !wasMuted
			}
			await Promise.allSettled([
				streamDeck.settings.setGlobalSettings(globalSettings),
				getConnector()?.sendCommand(cmd)
			]);
		}
		hostDataUpdateEventBus.emit(HostSettingsUpdatedEventEmitter.EVENT_NAME, globalSettings)
		await Mute.updateActionImage(ev.action, instanceName, globalSettings);
	}
}

type MuteSettings = {
	instanceName?: string;
};
