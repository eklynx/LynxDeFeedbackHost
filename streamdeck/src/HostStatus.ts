

export type Device = {
    uid: string;
    name: string;
    channels: number;
};

export type Instance = {
    index: number;
    id: string;
    name: string;
    strength: number | null;
    muted: boolean;
    bypassed: boolean;
    inputChannel: number;
    outputChannel: number;
    error: string | null;
};

export type Status = {
    protocol: number;
    running: boolean;
    canStart: boolean;
    blockedReason: string | null;
    sampleRate: number;
    bufferSize: number;
    bufferSizeChoices: number[];
    bufferSizeAccepted: boolean;
    pluginInstalled: boolean;
    pluginMessage: string | null;
    pluginURL: string;
    instances: Instance[];
    instanceCount: number;
    maxInstanceCount: number;
    inputDevice: string | null;
    outputDevice: string | null;
    inputDeviceUID: string | null;
    outputDeviceUID: string | null;
    inputDeviceMissing: boolean;
    outputDeviceMissing: boolean;
    inputDevices: Device[];
    outputDevices: Device[];
    inputChannelCount: number;
    outputChannelCount: number;
    inputSampleRate: number | null;
    outputSampleRate: number | null;
    inputSampleRates: number[];
    outputSampleRates: number[];
    sampleRatesMatch: boolean;
    dspLoad: number;
    peakDspLoad: number;
    underruns: number;
    hasRendered: boolean;
    realtime: boolean;
    error: string | null;
};
