// Bundle entry for the shutdown simulation: the real shutdown modules and the actions that hook into them.
export {ShutdownSequence, clampMagicPresses, FLASH_MS} from "../../src/shutdown/ShutdownSequence";
export {KeyRegistry} from "../../src/shutdown/ShutdownKeyRegistry";
export {keyRegistry, shutdownSequence, applyGlobalSettings} from "../../src/shutdown/shutdownRuntime";
export {shutdownImage} from "../../src/shutdown/StreamDeckShutdownView";
export {Shutdown} from "../../src/actions/shutdown";
export {Mute} from "../../src/actions/mute";
export {Bypass} from "../../src/actions/bypass";
export {Strength} from "../../src/actions/strength";
export {WebHostConnector} from "../../src/WebHostConnector";
export {setConnector} from "../../src/connectorState";
