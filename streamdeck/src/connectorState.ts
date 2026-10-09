import type {WebHostConnector} from "./WebHostConnector";

// Holds the active connector in a leaf module so actions don't have to import plugin.ts (which imports them).
let activeConnector: WebHostConnector | undefined;

export const getConnector = (): WebHostConnector | undefined => activeConnector;

export const setConnector = (connector: WebHostConnector | undefined): void => {
    activeConnector = connector;
};
