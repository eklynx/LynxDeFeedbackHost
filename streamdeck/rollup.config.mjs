import commonjs from "@rollup/plugin-commonjs";
import nodeResolve from "@rollup/plugin-node-resolve";
import terser from "@rollup/plugin-terser";
import { execFile } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import url from "node:url";
import { promisify } from "node:util";

const isWatching = !!process.env.ROLLUP_WATCH;
const sdPlugin = "com.eklynx.sound.defeedback.sdPlugin";

/**
 * TypeScript 7 is a native compiler with no JavaScript API, so @rollup/plugin-typescript
 * (which needs that API) cannot run. This plugin runs the real `tsc` instead: it type-checks
 * src/ and emits plain JavaScript into build/ts, which Rollup then bundles. A type error
 * fails the build, as it did with the old plugin.
 */
const tsc = {
	name: "tsc",
	async buildStart() {
		for (const entry of fs.readdirSync("src", { recursive: true })) {
			if (entry.endsWith(".ts")) this.addWatchFile(path.resolve("src", entry));
		}
		try {
			await promisify(execFile)(path.resolve("node_modules/.bin/tsc"), ["-p", "."]);
		} catch (error) {
			this.error(`${error.stdout || ""}${error.stderr || ""}`.trim() || error.message);
		}
	}
};

/**
 * @type {import('rollup').RollupOptions}
 */
const config = {
	// TypeScript's decorator helpers test `this` at module scope and fall back safely when it is undefined.
	onwarn: (warning, warn) => { if (warning.code !== "THIS_IS_UNDEFINED") warn(warning); },
	input: "build/ts/plugin.js",
	output: {
		file: `${sdPlugin}/bin/plugin.js`,
		sourcemap: isWatching,
		sourcemapPathTransform: (relativeSourcePath, sourcemapPath) => {
			return url.pathToFileURL(path.resolve(path.dirname(sourcemapPath), relativeSourcePath)).href;
		}
	},
	plugins: [
		{
			name: "watch-externals",
			buildStart: function () {
				this.addWatchFile(`${sdPlugin}/manifest.json`);
			},
		},
		tsc,
		nodeResolve({
			browser: false,
			exportConditions: ["node"],
			preferBuiltins: true
		}),
		commonjs(),
		!isWatching && terser(),
		{
			name: "emit-module-package-file",
			generateBundle() {
				this.emitFile({ fileName: "package.json", source: `{ "type": "module" }`, type: "asset" });
			}
		}
	]
};

export default config;
