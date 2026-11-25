// Stand-in for "@elgato/streamdeck" in the encoder simulation. The simulation (run.mjs) installs the
// fake Stream Deck app on globalThis.__sd before the bundled plugin code is imported.
const sd = globalThis.__sd;

export default sd.streamDeck;
export const action = () => (target) => target;
export class SingletonAction {}
export const LogLevel = { ERROR: 0, WARN: 1, INFO: 2, DEBUG: 3, TRACE: 4 };
