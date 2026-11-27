/**
 * SOURCE OF TRUTH (for AI agents): the Stream Deck shutdown "puzzle" (hold the shutdown key, tap the red magic key X times).
 * Rules: docs/shutdown-spec.md, SH14-SH23. API: openapi.yaml (`POST /api/shutdown`, status `shutdown`).
 *
 * Pure and injectable: it imports nothing from the Stream Deck SDK. Everything it touches is passed in
 * (`ShutdownSequenceDeps`): the key registry, the view, the sender, the phrase source, a random source and a scheduler.
 *
 * Happy path
 *   1. `shutdownKeyDown(id, x)` while enabled and >= 2 eligible keys are visible on the SAME Stream Deck as the held
 *      shutdown key: an attempt starts, one of those keys becomes the magic key (`view.showMagicKey(id)`). Keys on
 *      another device are never magic keys and do not count towards the minimum (SH23).
 *   2. The caller routes every key press/release of our mute/bypass/strength keys to `keyDown` / `keyUp`. A tap
 *      (down+up) on the magic key counts; the next magic key is random and different from the current one.
 *   3. After `x` taps the attempt ends and the phrase is sent; a 202 flashes "success" (or "test" when the host
 *      says `test: true`), then everything returns to normal.
 * Failure paths (all flash "alert", clear the magic key and end the attempt; holding again restarts)
 *   - the shutdown key is released early; a non-magic key of ours is pressed; any key appears or disappears
 *     (screen/folder change); the phrase is empty; the send rejects (403 wrong phrase, 409 disabled, 500, network).
 * Ignored: input from ids that are not in the registry (foreign keys, dials), holds while disabled or with too few
 * keys, holds while a send is in flight. There is no time limit.
 *
 * Contract with the actions: `keyDown`/`keyUp` return true when the press was consumed by an active attempt, and the
 * action must then NOT run its normal behaviour (SH18).
 */
import type {KeyRegistry} from "./ShutdownKeyRegistry";

export const MIN_MAGIC_PRESSES = 5;
export const DEFAULT_MAGIC_PRESSES = 5;
export const MIN_ELIGIBLE_KEYS = 2;
export const FLASH_MS = 1500;

/** What the shutdown key shows. */
export type ShutdownKeyState = "normal" | "disabled" | "tooFewKeys" | "success" | "test" | "alert";

/** The status `shutdown` object (openapi.yaml `ShutdownStatus`). */
export type ShutdownStatusInfo = { enabled: boolean; testMode: boolean; phrase: string };

export interface ShutdownView {
    /** Draw the state on the shutdown key `id`, or on every visible shutdown key when no id is given. */
    showShutdownState(state: ShutdownKeyState, id?: string): void;
    /** Paint `id` full red and restore whichever key was red before; null restores all. */
    showMagicKey(id: string | null): void;
}

export interface Scheduler {
    setTimeout(fn: () => void, ms: number): unknown;
    clearTimeout(handle: unknown): void;
}

export type ShutdownSequenceDeps = {
    registry: KeyRegistry<any>;
    view: ShutdownView;
    /** POST /api/shutdown {phrase}. Resolves on 202 (`test` from the body); rejects on any other outcome. */
    send: (phrase: string) => Promise<{ test: boolean }>;
    /** The user-typed global action setting (SH22). */
    getPhrase: () => Promise<string | undefined> | string | undefined;
    /** [0, 1) like Math.random. */
    random: () => number;
    scheduler: Scheduler;
    /** Whether the Stream Deck app still shows this action; keys that are not showing are never magic keys. Default: yes. */
    isShowing?: (id: string) => boolean;
    flashMs?: number;
    log?: (message: string, error?: unknown) => void;
    /** Debug-level trace (one line per magic key pick). */
    debug?: (message: string) => void;
};

/** X from the action settings: default 5, never below 5, whole numbers only (SH16). */
export function clampMagicPresses(value: unknown): number {
    const n = typeof value === "string" ? Number(value.trim() === "" ? NaN : value) : Number(value);
    if (!Number.isFinite(n)) return DEFAULT_MAGIC_PRESSES;
    return Math.max(MIN_MAGIC_PRESSES, Math.floor(n));
}

export class ShutdownSequence {
    private readonly d: ShutdownSequenceDeps;
    private status: ShutdownStatusInfo | undefined;

    private active = false;
    private holder: string | undefined;
    private required = MIN_MAGIC_PRESSES;
    private taps = 0;
    private magic: string | undefined;
    private magicPressed = false;

    private busy = false;
    private flashState: ShutdownKeyState | undefined;
    private flashTimer: unknown;

    constructor(deps: ShutdownSequenceDeps) {
        this.d = deps;
        deps.registry.onChange(() => this.onRegistryChanged());
    }

    // ---- state ----------------------------------------------------------------------------------------------

    get isActive(): boolean { return this.active; }
    get magicKeyId(): string | undefined { return this.magic; }
    get tapCount(): number { return this.taps; }

    /** Eligible magic keys for the shutdown key `holderId` (same device, showing); with no id: every device. */
    private eligibleFor(holderId?: string): string[] {
        const ids = holderId === undefined ? this.d.registry.eligibleIds() : this.d.registry.eligibleIdsOnDeviceOf(holderId);
        return this.d.isShowing ? ids.filter((id) => this.d.isShowing!(id)) : ids;
    }

    /** The state the shutdown key `id` should show now (without an id, as if every device were one). */
    state(id?: string): ShutdownKeyState {
        if (this.flashState) return this.flashState;
        if (!this.status?.enabled) return "disabled";
        if (this.eligibleFor(id).length < MIN_ELIGIBLE_KEYS) return "tooFewKeys";
        return "normal";
    }

    /** Latest `shutdown` object from the host status; undefined (old host, never connected) behaves as disabled. */
    setStatus(status: ShutdownStatusInfo | undefined): void {
        this.status = status;
        if (this.active && !status?.enabled) this.fail("shutdown was disabled mid-attempt");
        else this.render();
    }

    render(): void {
        const ids = this.d.registry.shutdownIds();
        if (ids.length === 0) this.d.view.showShutdownState(this.state());
        for (const id of ids) this.d.view.showShutdownState(this.state(id), id);
    }

    // ---- the shutdown key -----------------------------------------------------------------------------------

    shutdownKeyDown(id: string, requiredTaps: number): void {
        if (!this.d.registry.has(id)) return;
        if (this.active) {
            // A second shutdown key is "another key of ours".
            if (id !== this.holder) this.fail("another key was pressed");
            return;
        }
        if (this.busy) return;
        const s = this.state(id);
        if (s === "disabled" || s === "tooFewKeys") return;   // holds do nothing (SH19, SH20)

        this.clearFlash();
        this.active = true;
        this.holder = id;
        this.required = clampMagicPresses(requiredTaps);
        this.taps = 0;
        this.magicPressed = false;
        this.magic = this.pickMagic(undefined);
        this.logPick();
        this.render();
        this.d.view.showMagicKey(this.magic ?? null);
    }

    shutdownKeyUp(id: string): void {
        if (this.active && id === this.holder) this.fail("shutdown key released early");
    }

    // ---- other keys of ours ---------------------------------------------------------------------------------

    /** @returns true when the press belongs to an active attempt (the action must not run its normal behaviour). */
    keyDown(id: string): boolean {
        if (!this.active || !this.d.registry.has(id)) return false;
        if (id === this.magic) {
            this.magicPressed = true;
        } else {
            this.fail("wrong key pressed");
        }
        return true;
    }

    /** @returns true when the release belongs to an active attempt. */
    keyUp(id: string): boolean {
        if (!this.active || !this.d.registry.has(id)) return false;
        if (id === this.magic && this.magicPressed) {
            this.magicPressed = false;
            this.taps++;
            if (this.taps >= this.required) {
                void this.succeed();
            } else {
                this.magic = this.pickMagic(this.magic);
                this.logPick();
                this.d.view.showMagicKey(this.magic ?? null);
            }
        }
        return true;
    }

    // ---- internals ------------------------------------------------------------------------------------------

    /** Random eligible key on the holder's device, never `current` (SH15, SH23). */
    private pickMagic(current: string | undefined): string | undefined {
        const candidates = this.eligibleFor(this.holder).filter((id) => id !== current);
        if (candidates.length === 0) return undefined;
        const i = Math.min(candidates.length - 1, Math.floor(this.d.random() * candidates.length));
        return candidates[i];
    }

    /** One debug line per pick, so a sequence with no next key can be diagnosed from the plugin log. */
    private logPick(): void {
        const eligible = this.eligibleFor(this.holder);
        this.d.debug?.(`Shutdown magic key ${this.magic ?? "none"} (tap ${this.taps + 1} of ${this.required}); holder ${this.holder} on device ${this.d.registry.deviceOf(this.holder ?? "") ?? "unknown"}; ${eligible.length} eligible key(s) there`);
    }

    private onRegistryChanged(): void {
        // Any appear/disappear during a hold is a screen or folder change (or the keys being edited): fail safe.
        if (this.active) this.fail("the screen changed");
        else this.render();
    }

    private endAttempt(): void {
        this.active = false;
        this.holder = undefined;
        this.magic = undefined;
        this.magicPressed = false;
        this.taps = 0;
        this.d.view.showMagicKey(null);
    }

    private fail(reason: string): void {
        this.d.log?.(`Shutdown attempt failed: ${reason}`);
        this.endAttempt();
        this.flash("alert");
    }

    private async succeed(): Promise<void> {
        this.endAttempt();
        this.busy = true;
        try {
            const phrase = await this.d.getPhrase();
            if (!phrase) {
                this.d.log?.("Shutdown phrase is empty; nothing sent");
                this.flash("alert");
                return;
            }
            const result = await this.d.send(phrase);
            this.flash(result.test ? "test" : "success");
        } catch (error) {
            this.d.log?.("Shutdown request failed", error);
            this.flash("alert");
        } finally {
            this.busy = false;
        }
    }

    private flash(state: ShutdownKeyState): void {
        this.clearFlash();
        this.flashState = state;
        this.render();
        this.flashTimer = this.d.scheduler.setTimeout(() => {
            this.flashTimer = undefined;
            this.flashState = undefined;
            this.render();
        }, this.d.flashMs ?? FLASH_MS);
    }

    private clearFlash(): void {
        if (this.flashTimer !== undefined) this.d.scheduler.clearTimeout(this.flashTimer);
        this.flashTimer = undefined;
        this.flashState = undefined;
    }
}
