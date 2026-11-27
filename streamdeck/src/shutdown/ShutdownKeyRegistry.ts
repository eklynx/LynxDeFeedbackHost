/**
 * SOURCE OF TRUTH (for AI agents): the key registry of the shutdown sequence.
 * Rules: docs/shutdown-spec.md (SH15, SH17, SH19, SH23). Pure: no Stream Deck SDK imports, so it is unit-testable.
 *
 * The registry knows which KEY actions of ours are visible right now ("the current screen"), kept up to date by the
 * actions' will-appear / will-disappear handlers.
 *
 * Happy path: `appear(id, kind, handle, deviceId)` on will-appear, `disappear(id)` on will-disappear; the sequence reads
 *   `eligibleIdsOnDeviceOf(holder)` (mute / bypass / strength keys on the SAME Stream Deck as the held shutdown key)
 *   to choose magic keys (SH23). `eligibleIds()` is every device and is only for counting and tests.
 * Error / edge cases:
 *   - Dials are never registered (callers check `action.isKey()` first), so they can never be magic keys.
 *   - Keys that are not ours never reach the plugin, so they can never be registered.
 *   - A key's device is whatever `appear` was given; keys registered without one all count as one (unknown) device.
 *   - `appear` for an id already registered replaces it (the SDK may repeat will-appear after a redraw).
 *   - `disappear` for an unknown id is a no-op and does not notify.
 *   - Every real change notifies the listeners synchronously, so the sequence can fail an attempt on a screen change.
 */

/** The kinds of key action of ours. `shutdown` is the trigger key and is never eligible as a magic key. */
export type KeyKind = "mute" | "bypass" | "strength" | "shutdown";

const MAGIC_KINDS: ReadonlySet<KeyKind> = new Set<KeyKind>(["mute", "bypass", "strength"]);

export class KeyRegistry<H = unknown> {
    private readonly keys = new Map<string, { kind: KeyKind; handle: H | undefined; deviceId: string | undefined }>();
    private readonly listeners: Array<() => void> = [];

    appear(id: string, kind: KeyKind, handle?: H, deviceId?: string): void {
        this.keys.set(id, {kind, handle, deviceId});
        this.notify();
    }

    disappear(id: string): void {
        if (this.keys.delete(id)) this.notify();
    }

    has(id: string): boolean {
        return this.keys.has(id);
    }

    kindOf(id: string): KeyKind | undefined {
        return this.keys.get(id)?.kind;
    }

    handleOf(id: string): H | undefined {
        return this.keys.get(id)?.handle;
    }

    /** The Stream Deck this key is on (undefined when it was registered without one). */
    deviceOf(id: string): string | undefined {
        return this.keys.get(id)?.deviceId;
    }

    /** Visible key actions that can be a magic key on ANY device, in appearance order. */
    eligibleIds(): string[] {
        return [...this.keys].filter(([, v]) => MAGIC_KINDS.has(v.kind)).map(([id]) => id);
    }

    /** Visible key actions that can be a magic key and are on the same device as `id` (SH23). */
    eligibleIdsOnDeviceOf(id: string): string[] {
        const device = this.deviceOf(id);
        return [...this.keys].filter(([, v]) => MAGIC_KINDS.has(v.kind) && v.deviceId === device).map(([key]) => key);
    }

    /** Visible shutdown keys. */
    shutdownIds(): string[] {
        return [...this.keys].filter(([, v]) => v.kind === "shutdown").map(([id]) => id);
    }

    /** Remove everything (tests, plugin teardown). Notifies once if anything was registered. */
    clear(): void {
        if (this.keys.size === 0) return;
        this.keys.clear();
        this.notify();
    }

    onChange(listener: () => void): void {
        this.listeners.push(listener);
    }

    private notify(): void {
        for (const l of this.listeners) l();
    }
}
