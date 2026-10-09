export const CURRENT_VERSION = 1;

export type PluginInstance = {
    version: number
    id: string;
    isMuted: boolean;
    isBypassed: boolean;
    strength: number;
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
}