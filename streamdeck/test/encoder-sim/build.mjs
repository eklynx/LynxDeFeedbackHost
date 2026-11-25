// Bundles entry.ts (real plugin code, stubbed Stream Deck SDK) to $CLAUDE_WORK/tmp/encoder-sim/bundle.mjs.
import {rollup} from "rollup";
import typescript from "@rollup/plugin-typescript";
import nodeResolve from "@rollup/plugin-node-resolve";
import commonjs from "@rollup/plugin-commonjs";
import path from "node:path";
import url from "node:url";

const here = path.dirname(url.fileURLToPath(import.meta.url));
const root = path.resolve(here, "../..");
export const bundlePath = path.join(process.env.CLAUDE_WORK ?? path.join(root, "test", ".out"), "tmp", "encoder-sim", "bundle.mjs");

export async function build() {
    const bundle = await rollup({
        input: path.join(here, "entry.ts"),
        onwarn: (w) => { if (w.code !== "THIS_IS_UNDEFINED") console.warn(w.message); },
        plugins: [
            {
                name: "stub-streamdeck",
                resolveId: (id) => (id === "@elgato/streamdeck" ? path.join(here, "stub-streamdeck.js") : null),
            },
            typescript({
                tsconfig: path.join(root, "tsconfig.json"),
                // Relative to the cwd (the streamdeck folder): absolute globs break on the spaces in this path.
                include: ["src/**/*.ts", "test/**/*.ts"],
                noEmitOnError: false,
                outDir: undefined,
            }),
            nodeResolve({browser: false, preferBuiltins: true}),
            commonjs(),
        ],
    });
    await bundle.write({file: bundlePath, format: "esm"});
    await bundle.close();
    return bundlePath;
}
