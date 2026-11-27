export const CURRENT_VERSION = 1;

export type PluginInstance = {
    version: number
    id: string;
    isMuted: boolean;
    isBypassed: boolean;
    strength: number;
    encoderLastUpdated?: number;
}

/** The host's shutdown settings as last reported by the status (openapi.yaml `ShutdownStatus`). */
export type ShutdownStatus = {
    enabled: boolean;
    testMode: boolean;
    phrase: string;
}

export type GlobalSettings = {
    version: number
    lastUpdated: number;
    isRunning: boolean;
    hostname: string;
    port: number;
    username?: string;
    password?: string;
    instances?: Record<string, PluginInstance | null>;
    /** From the host status; absent until a status with a `shutdown` object arrives (then the shutdown key is grey). */
    shutdown?: ShutdownStatus;
    /** The shutdown action's global setting, typed by the user (SH22). Sent as the phrase of POST /api/shutdown. */
    shutdownPhrase?: string;
}