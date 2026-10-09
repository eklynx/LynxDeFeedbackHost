import http from "node:http";
import streamDeck from "@elgato/streamdeck";
import {Instance, Status} from "./HostStatus";

import {CURRENT_VERSION, GlobalSettings, PluginInstance} from "./GlobalSettings";
import {hostDataUpdateEventBus, HostSettingsUpdatedEventEmitter} from "./HostSettingsUpdatedEvent";

const RETRY_DELAY_MS = 500;
const COMMAND_TIMEOUT_MS = 500;

export type MuteCommand = { type: "mute"; instanceId: string; muted: boolean };
export type BypassCommand = { type: "bypass"; instanceId: string; bypassed: boolean };
export type StrengthCommand = { type: "strength"; instanceId: string; strength: number };
export type HostCommand = MuteCommand | BypassCommand | StrengthCommand;

export class WebHostConnector {
    hostname: string;
    port: number;
    username: string | undefined;
    password: string | undefined;

    isConnected: boolean = false;

    private request: http.ClientRequest | undefined;
    private retryTimer: NodeJS.Timeout | undefined;
    private buffer: string = "";
    private disposed: boolean = false;

    constructor(hostname: string, port: number, username: string | undefined, password: string | undefined) {
        this.hostname = hostname;
        this.port = port;
        this.username = username;
        this.password = password;

        if (!this.hostname || port < 1024 || port > 65535) {
            throw new Error("Invalid hostname or port");
        }
    }

    connect(): void {
        this.disposed = false;
        this.buffer = "";

        const headers: http.OutgoingHttpHeaders = {
            Accept: "text/event-stream",
            ...this.authHeaders()
        };

        streamDeck.logger.debug(`Connecting to web host event listener at ${this.hostname}:${this.port}`);

        this.request = http.request(
            {
                hostname: this.hostname,
                port: this.port,
                path: "/api/events",
                method: "GET",
                headers
            },
            (res) => this.handleResponse(res)
        );

        this.request.on("error", (error) => this.handleConnectionFailure(error));
        this.request.end();
    }

    async disconnect(): Promise<void> {
        this.disposed = true;
        this.isConnected = false;
        this.clearRetryTimer();
        this.request?.destroy();
        this.request = undefined;
        streamDeck.logger.info("Disconnected from web host");
        hostDataUpdateEventBus.emit(HostSettingsUpdatedEventEmitter.EVENT_NAME, await streamDeck.settings.getGlobalSettings())
    }

    async sendCommand(command: HostCommand): Promise<Status> {
        if (!this.isConnected) {
            throw new Error("Not connected to web host");
        }

        const body = JSON.stringify(this.commandBody(command));
        streamDeck.logger.info(`Sending command to web host: ${body} for instance ${command.instanceId}`);

        return new Promise<Status>((resolve, reject) => {
            const req = http.request(
                {
                    hostname: this.hostname,
                    port: this.port,
                    path: `/api/instances/${encodeURIComponent(command.instanceId)}`,
                    method: "PATCH",
                    timeout: COMMAND_TIMEOUT_MS,
                    headers: {
                        "Content-Type": "application/json",
                        "Content-Length": Buffer.byteLength(body),
                        ...this.authHeaders()
                    }
                },
                (res) => {
                    let data = "";
                    res.setEncoding("utf8");
                    res.on("data", (chunk: string) => (data += chunk));
                    res.on("error", reject);
                    res.on("end", () => {
                        if (res.statusCode === 202) {
                            try {
                                resolve(JSON.parse(data) as Status);
                            } catch (error) {
                                reject(new Error(`Host returned an unreadable response: ${error}`));
                            }
                            return;
                        }

                        let message = "";
                        try {
                            message = (JSON.parse(data) as { error?: string }).error ?? "";
                        } catch {
                            // Non-JSON error body; fall back to the status code alone.
                        }
                        reject(new Error(`Host rejected ${command.type} command (${res.statusCode})${message ? `: ${message}` : ""}`));
                    });
                }
            );

            req.on("timeout", () => req.destroy(new Error(`Timed out sending ${command.type} command`)));
            req.on("error", reject);
            req.end(body);
        });
    }

    private commandBody(command: HostCommand): Record<string, boolean | number> {
        switch (command.type) {
            case "mute":
                return { muted: command.muted };
            case "bypass":
                return { bypassed: command.bypassed };
            case "strength":
                if (!Number.isInteger(command.strength) || command.strength < 0 || command.strength > 100) {
                    throw new Error("Strength must be an integer from 0 to 100");
                }
                return { strength: command.strength };
        }
    }

    private authHeaders(): http.OutgoingHttpHeaders {
        if (!this.username) {
            return {};
        }
        const credentials = Buffer.from(`${this.username}:${this.password ?? ""}`).toString("base64");
        return { Authorization: `Basic ${credentials}` };
    }

    private async handleResponse(res: http.IncomingMessage): Promise<void> {
        if (res.statusCode === 401) {
            streamDeck.logger.error("Web host rejected connection: unauthorized (check username/password)");
            res.resume();
            this.handleConnectionFailure(new Error("Unauthorized"));
            return;
        }

        if (res.statusCode !== 200) {
            streamDeck.logger.error(`Web host returned unexpected status code ${res.statusCode}`);
            res.resume();
            this.handleConnectionFailure(new Error(`Unexpected status code ${res.statusCode}`));
            return;
        }

        this.isConnected = true;
        streamDeck.logger.info("Connected to web host event listener");
        const globalSettings = await streamDeck.settings.getGlobalSettings() as GlobalSettings
        hostDataUpdateEventBus.emit(HostSettingsUpdatedEventEmitter.EVENT_NAME, globalSettings)

        res.setEncoding("utf8");
        res.on("data", (chunk: string) => this.handleChunk(chunk));
        res.on("end", () => this.handleConnectionFailure(new Error("Connection closed by host")));
        res.on("error", (error) => this.handleConnectionFailure(error));
    }

    private handleChunk(chunk: string): void {
        this.buffer += chunk;

        let frameEnd: number;
        while ((frameEnd = this.buffer.indexOf("\n\n")) !== -1) {
            const frame = this.buffer.slice(0, frameEnd);
            this.buffer = this.buffer.slice(frameEnd + 2);
            this.parseFrame(frame);
        }
    }

    private parseFrame(frame: string): void {
        let eventType = "message";
        const dataLines: string[] = [];

        for (const line of frame.split("\n")) {
            if (line.startsWith("event:")) {
                eventType = line.slice("event:".length).trim();
            } else if (line.startsWith("data:")) {
                dataLines.push(line.slice("data:".length).trim());
            }
        }

        if (dataLines.length === 0) {
            return;
        }

        this.dispatch(eventType, dataLines.join("\n"));
    }

    private dispatch(eventType: string, rawData: string): void {
        let payload: unknown;
        try {
            payload = JSON.parse(rawData);
        } catch (error) {
            streamDeck.logger.error(`Failed to parse event payload for "${eventType}" event`, error);
            return;
        }

        switch (eventType) {
            case "status":
                this.onStatusEvent(payload as Status);
                break;
            default:
                streamDeck.logger.warn(`Received unhandled event type "${eventType}"`, payload);
                break;
        }
    }

    private async onStatusEvent(status: Status): Promise<void> {
        streamDeck.logger.debug("Received status event", status);
        let globalSettings: GlobalSettings = await streamDeck.settings.getGlobalSettings();
        let modified = false;
        if (globalSettings) {
            if (globalSettings.instances == null)  {
                globalSettings.instances = {};
            }

            if (globalSettings.isRunning != status.running) {
                globalSettings.isRunning = status.running;
                modified = true;
            }

            for (const key in Object.keys(globalSettings.instances)) {
                if (!status.instances[key]) {
                    delete globalSettings.instances[key];
                }
            }
            status.instances.forEach((inst: Instance)=> {
                if (!globalSettings.instances) {
                    throw new Error("Instances not found");
                }
               const id = inst.id as string;
               if (!globalSettings.instances[id]) {
                   modified = true; // new item
               }
               else {
                   if (globalSettings.instances[id].isBypassed != inst.bypassed ||
                       globalSettings.instances[id].isMuted != inst.muted ||
                       globalSettings.instances[id].strength != inst.strength) {
                       modified = true;
                   }
               }
               globalSettings.instances[inst.id as string] = {
                   version: CURRENT_VERSION,
                    id: id,
                    isBypassed: inst.bypassed,
                    isMuted: inst.muted,
                    strength: inst.strength ?? 0
               }
            });

            globalSettings.lastUpdated = Date.now();
            await streamDeck.settings.setGlobalSettings(globalSettings);
        }
        if (modified) {
            hostDataUpdateEventBus.emit(HostSettingsUpdatedEventEmitter.EVENT_NAME, globalSettings)
        }
    }

    private async handleConnectionFailure(error: unknown): Promise<void> {
        if (this.disposed) {
            return;
        }

        if (this.isConnected) {
            streamDeck.logger.error("Web host event listener connection failed; disconnecting.", error);
        } else {
            streamDeck.logger.debug("Web host event listener connection failed.", error);
        }
        this.isConnected = false;
        hostDataUpdateEventBus.emit(HostSettingsUpdatedEventEmitter.EVENT_NAME, await streamDeck.settings.getGlobalSettings())
        this.scheduleRetry();
    }

    private scheduleRetry(): void {
        if (this.disposed) {
            return;
        }

        this.clearRetryTimer();
        this.retryTimer = setTimeout(() => this.connect(), RETRY_DELAY_MS);
    }

    private clearRetryTimer(): void {
        if (this.retryTimer) {
            clearTimeout(this.retryTimer);
            this.retryTimer = undefined;
        }
    }

}
