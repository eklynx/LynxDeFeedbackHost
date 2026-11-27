import streamDeck, {DialAction, KeyAction} from "@elgato/streamdeck";
import type {JsonObject} from "@elgato/utils";
import {hostDataUpdateEventBus, HostSettingsUpdatedEventEmitter} from "../HostSettingsUpdatedEvent";
import {Mute} from "./mute";
import {Bypass} from "./bypass";
import {Strength} from "./strength";
import {GlobalSettings} from "../GlobalSettings";
import {shutdownSequence} from "../shutdown/shutdownRuntime";

hostDataUpdateEventBus.on(HostSettingsUpdatedEventEmitter.EVENT_NAME, (globalSettings: GlobalSettings) => {
    streamDeck.actions.forEach((action) => {
        let promises: Promise<void>[] = [];
        // The magic key of a shutdown attempt stays red until the sequence moves on.
        if (shutdownSequence.magicKeyId === action.id) {
            return;
        }
        if (action.manifestId == 'com.eklynx.sound.defeedback.mute') {
            promises.push(Mute.updateActionFromExternal(action as KeyAction<JsonObject>, globalSettings));
        } else if (action.manifestId == 'com.eklynx.sound.defeedback.bypass') {
            promises.push(Bypass.updateActionFromExternal(action as KeyAction<JsonObject>, globalSettings));
        } else if (action.manifestId == 'com.eklynx.sound.defeedback.strength') {
            const strAction = action.isKey() ? action as KeyAction<JsonObject> : action as DialAction<JsonObject>;
            promises.push(Strength.updateActionFromExternal(strAction, globalSettings));
        }
        return Promise.allSettled(promises);
    });
});
