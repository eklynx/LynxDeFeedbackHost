// Bundles entry.ts (real plugin code, stubbed Stream Deck SDK) to $CLAUDE_WORK/tmp/encoder-sim/bundle.mjs.
import {rollup} from "rollup";
import nodeResolve from "@rollup/plugin-node-resolve";
import commonjs from "@rollup/plugin-commonjs";
import {execFile} from "node:child_process";
import path from "node:path";
import url from "node:url";
import {promisify} from "node:util";

const here = path.dirname(url.fileURLToPath(import.meta.url));
const root = path.resolve(here, "../..");
export const bundlePath = path.join(process.env.CLAUDE_WORK ?? path.join(root, "test", ".out"), "tmp", "encoder-sim", "bundle.mjs");

export const shutdownBundlePath = path.join(process.env.CLAUDE_WORK ?? path.join(root, "test", ".out"), "tmp", "shutdown-sim", "bundle.mjs");

// Defaults bundle the encoder simulation; the shutdown simulation passes its own entry and output.
export async function build({entry = "build/encoder-sim/test/encoder-sim/entry.js", out = bundlePath} = {}) {
    // TypeScript 7 has no JavaScript API for a Rollup plugin, so run the real tsc and bundle its output.
    // Type errors here are tolerated on purpose (noEmitOnError is false): the stub SDK is not fully typed.
    await promisify(execFile)(path.join(root, "node_modules/.bin/tsc"), ["-p", here]).catch(() => {});
    const bundle = await rollup({
        input: path.join(root, entry),
        onwarn: (w) => { if (w.code !== "THIS_IS_UNDEFINED") console.warn(w.message); },
        plugins: [
            {
                name: "stub-streamdeck",
                resolveId: (id) => (id === "@elgato/streamdeck" ? path.join(here, "stub-streamdeck.js") : null),
            },
            nodeResolve({browser: false, preferBuiltins: true}),
            commonjs(),
        ],
    });
    await bundle.write({file: out, format: "esm"});
    await bundle.close();
    return out;
}
