import { EventEmitter } from "node:events";

import {GlobalSettings} from "./GlobalSettings";

interface HostSettingsUpdatedEvents {
    HostSettingsUpdatedEvent: [globalSettings: GlobalSettings];
}

export class HostSettingsUpdatedEventEmitter extends EventEmitter {
    static readonly EVENT_NAME = "HostSettingsUpdatedEvent" as const;

    override on<K extends keyof HostSettingsUpdatedEvents>( event: K, listener: (...args: HostSettingsUpdatedEvents[K]) => void
    ): this {
        return super.on(event, listener as (...args: any[]) => void);
    }

    override emit<K extends keyof HostSettingsUpdatedEvents>(event: K, ...args: HostSettingsUpdatedEvents[K]
    ): boolean {
        return super.emit(event, ...args);
    }
}
export const hostDataUpdateEventBus = new HostSettingsUpdatedEventEmitter();
