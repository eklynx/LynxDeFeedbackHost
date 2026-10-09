import streamDeck, {LogLevel} from "@elgato/streamdeck";

import {Mute} from "./actions/mute";
import {Bypass} from "./actions/bypass";
import {Strength} from "./actions/strength";
import "./actions/iconRefreshListener";
import {WebHostConnector} from "./WebHostConnector";
import {getConnector, setConnector} from "./connectorState";
import {CURRENT_VERSION, GlobalSettings, PluginInstance} from "./GlobalSettings";

// We can enable "trace" logging so that all messages between the Stream Deck, and the plugin are recorded. When storing sensitive information
streamDeck.logger.setLevel(LogLevel.INFO);

// Register the increment action.
streamDeck.actions.registerAction(new Mute());
streamDeck.actions.registerAction(new Bypass());
streamDeck.actions.registerAction(new Strength());


const defaultSettings: GlobalSettings = {
    version: CURRENT_VERSION,
    lastUpdated: 0,
    isRunning: false,
    hostname: "localhost",
    port: 8787,
    username: "",
    password: "",
    instances: {}
};


// Web event listener connection (see openapi.yaml for the /api/events contract).
// Reconnects whenever the connection-relevant global settings change.

// The PI's text field stores the port as a string, so always compare/connect with a number.
function connectionSettingsChanged(settings: GlobalSettings): boolean {
    const connector = getConnector();
    return !connector
        || connector.hostname !== settings.hostname
        || connector.port !== Number(settings.port)
        || connector.username !== settings.username
        || connector.password !== settings.password;
}

function reconnectWebHost(settings: GlobalSettings): void {
    getConnector()?.disconnect();
    setConnector(undefined);

    const port = Number(settings.port);
    if (!settings.hostname || !port) {
        return;
    }

    try {
        const connector = new WebHostConnector(settings.hostname, port, settings.username, settings.password);
        setConnector(connector);
        connector.connect();
    } catch (error) {
        streamDeck.logger.error("Failed to create web host connector", error);
    }
}

streamDeck.settings.onDidReceiveGlobalSettings<GlobalSettings>((ev) => {
    if (connectionSettingsChanged(ev.settings)) {
        reconnectWebHost(ev.settings);
    }
});

// Load persisted settings (merged over defaults) rather than overwriting them, so saved host/port/credentials survive a restart.
async function init(): Promise<void> {
    const stored = await streamDeck.settings.getGlobalSettings<Partial<GlobalSettings>>();
    let settings: GlobalSettings = {...defaultSettings, ...stored, instances: stored?.instances ?? {}};
    if (!stored.version || stored.version !== CURRENT_VERSION) {        delete settings.instances;
        settings.instances = {'init': null};
    }
    await streamDeck.settings.setGlobalSettings(settings);
    reconnectWebHost(settings);
}

// Finally, connect to the Stream Deck.
streamDeck.connect().then(init).catch((error) => streamDeck.logger.error("Plugin init failed", error));

