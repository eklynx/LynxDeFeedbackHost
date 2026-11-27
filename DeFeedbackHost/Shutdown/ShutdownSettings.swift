//
//  ShutdownSettings.swift
//  DeFeedbackHost
//
//  ┌─────────────────────────────────────────────────────────────────────────────────────────┐
//  │ AI AGENTS: this file and SystemShutdown.swift are the SOURCE OF TRUTH for the           │
//  │ `Shutdown` namespace. Read the contract below before touching shutdown handling.        │
//  │ Implementations live in sibling files; the spec is docs/shutdown-spec.md (GitHub #29).  │
//  └─────────────────────────────────────────────────────────────────────────────────────────┘
//
//  # Model
//
//  The app can shut down the Mac it runs on, on request from the web page or the Stream Deck.
//  Three settings control it. They are plain values the user can also script with `defaults write`
//  (keys in docs/cli-settings-spec.md):
//
//    - `isEnabled`   Whether the shutdown command is accepted at all. Off by default.
//    - `isTestMode`  When on, a shutdown command goes through every check and every client flow, but
//                    the computer is NOT shut down: the app only records that it would have.
//    - `phrase`      The safety word. The command must carry exactly this phrase. It is accident
//                    protection, NOT a secret: it is reported in plain text in the status payload so
//                    the web page can show it. Never log it as if it were a credential.
//
//  # `ShutdownSettings` contract (read-only view; the settings screen owns the writes)
//
//  Happy path
//    1. `isEnabled` / `isTestMode` / `phrase` always return the current stored value, so a change
//       made in the settings screen or with `defaults write` applies to the next command.
//
//  Error / edge cases
//    2. `phrase` is never empty. An empty or missing stored value reads as
//       `ShutdownPhrase.defaultPhrase`, and the settings screen refuses to save an empty one.
//    3. Defaults for a fresh install: disabled, and test mode OFF (spec rule SH1). A user who wants
//       to try the flow without shutting the Mac down turns test mode on first.
//    4. Reading never throws and never prompts.
//
//  Other pieces of the namespace:
//    - `SystemShutdown` (SystemShutdown.swift)  actually performs the shutdown.
//    - `ShutdownPhrase` (ShutdownPhrase.swift)  the one definition of "does this phrase match".
//
import Foundation

/// Read-only view of the shutdown settings. See the contract above.
@MainActor
protocol ShutdownSettings: AnyObject {
    var isEnabled: Bool { get }
    var isTestMode: Bool { get }
    var phrase: String { get }
}
