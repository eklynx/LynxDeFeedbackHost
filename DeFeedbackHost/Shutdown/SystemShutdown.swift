//
//  SystemShutdown.swift
//  DeFeedbackHost
//
//  ┌─────────────────────────────────────────────────────────────────────────────────────────┐
//  │ AI AGENTS: part of the SOURCE OF TRUTH for the `Shutdown` namespace, with               │
//  │ ShutdownSettings.swift (read that file's header first). Spec: docs/shutdown-spec.md.    │
//  └─────────────────────────────────────────────────────────────────────────────────────────┘
//
//  # `SystemShutdown` contract
//
//  The one thing the web command handler (#30) asks for once every check has passed. It does not
//  check the phrase or the enabled setting; the handler already did. It is a protocol so the
//  mechanism can change (System Events now, possibly a `sudoers` rule later) and so tests can use a
//  fake that never shuts anything down.
//
//  Happy path
//    1. `isTestMode`  -> whether `perform()` will only record the shutdown. Read it BEFORE calling
//                        `perform()`; the handler reports it to the client as `test`.
//    2. `perform()`   -> real mode: asks the system to shut down without prompting the user, and
//                        returns once the request has been accepted (the Mac goes down shortly
//                        after). Test mode: logs that a shutdown would have happened and returns.
//
//  Error / edge cases
//    3. `perform()` throws `ShutdownError.notPermitted` when the system refuses the request
//       because the app lacks the Automation permission.
//    4. `perform()` throws `ShutdownError.failed(reason)` for anything else; `reason` is a sentence
//       a person can read. The handler maps both to a 500 response.
//    5. Test mode never throws and never needs a system permission.
//    6. Being asked twice in a row is harmless: the second request is either ignored by the system
//       or logged again in test mode.
//
import Foundation

enum ShutdownError: Error, Equatable {
    case notPermitted
    case failed(String)
}

/// Performs, or in test mode only records, the system shutdown. See the contract above.
@MainActor
protocol SystemShutdown: AnyObject {
    var isTestMode: Bool { get }
    func perform() async throws
}
