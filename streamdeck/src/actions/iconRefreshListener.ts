import streamDeck, {DialAction, KeyAction} from "@elgato/streamdeck";
import {hostDataUpdateEventBus, HostSettingsUpdatedEventEmitter} from "../HostSettingsUpdatedEvent";
import {Mute} from "./mute";
import {Bypass} from "./bypass";
import {Strength} from "./strength";
import {GlobalSettings} from "../GlobalSettings";

hostDataUpdateEventBus.on(HostSettingsUpdatedEventEmitter.EVENT_NAME, (globalSettings: GlobalSettings) => {
    streamDeck.actions.forEach((action) => {
        let promises: Promise<void>[] = [];
        if (action.manifestId == 'com.eklynx.sound.defeedback.mute') {
            promises.push(Mute.updateActionFromExternal(action as KeyAction, globalSettings));
        } else if (action.manifestId == 'com.eklynx.sound.defeedback.bypass') {
            promises.push(Bypass.updateActionFromExternal(action as KeyAction, globalSettings));
        } else if (action.manifestId == 'com.eklynx.sound.defeedback.strength') {
            const strAction = action.isKey() ? action as KeyAction : action as DialAction;
            promises.push(Strength.updateActionFromExternal(strAction, globalSettings));
        }
        return Promise.allSettled(promises);
    });
});
