//
//  PermissionChecking.swift
//  DeFeedbackHost
//
//  ┌─────────────────────────────────────────────────────────────────────────────────────────┐
//  │ AI AGENTS: this file is the SOURCE OF TRUTH for the `Permissions` namespace. Read the   │
//  │ contract below before touching permission handling. Implementations live in sibling     │
//  │ files; the spec is docs/permissions-spec.md.                                            │
//  └─────────────────────────────────────────────────────────────────────────────────────────┘
//
//  # Model
//
//  The app needs three things the system makes the user approve: Microphone (audio input), Local
//  Network (the web control page) and Login Items (launch at login / restart after a crash).
//  `PermissionService` asks for them together at launch, so the prompts come before they are
//  needed, and reports a warning for each one that isn't allowed.
//
//  # `PermissionChecker` contract (one per permission)
//
//  Happy path
//    1. `check()`    -> the current state, without asking the user (see edge case 5).
//    2. `request()`  -> shows the system prompt when the state is `.notDetermined`, returns the
//                       answer. Called by `PermissionService.start()` once, at launch, and only for
//                       permissions that are `.notDetermined`.
//
//  Error / edge cases
//    3. Never throws. Anything unexpected is `.unknown`, and `.unknown` never produces a warning:
//       a wrong warning is worse than a late one.
//    4. `.denied` covers "denied" and "restricted by policy": either way the app can't use it.
//    5. Local Network has no status API. Its `check()` runs the same short Bonjour probe as
//       `request()`; if the user has never been asked, that probe is what raises the prompt.
//    6. Login Items is never requested here. Registering the launch agents would switch the user's
//       "launch at login" settings on, so it only REPORTS `.denied` when an agent the user turned on
//       still needs approval.
//    7. Under XCTest the service is given `InertPermissionChecker`s, so tests can't raise prompts.
//
//  # `PermissionService` contract
//    8. `start()`    -> once, at launch: check each permission, request the undetermined ones, in
//                       the order microphone, local network, login items.
//    9. `refresh()`  -> re-check only, never prompts the user (except edge case 5). Called when the
//                       app becomes active, so a grant made in System Settings clears its warning.
//   10. `warnings`   -> one `AppWarning` per `.denied` or `.notDetermined` permission, nothing for
//                       `.granted` or `.unknown`. Also a `WarningSource`, so the web page shows them.
//
import Foundation

enum Permission: String, CaseIterable, Identifiable, Sendable {
    case microphone
    case localNetwork
    case loginItems

    var id: String { rawValue }

    var label: String {
        switch self {
        case .microphone: "Microphone"
        case .localNetwork: "Local Network"
        case .loginItems: "Login Items"
        }
    }

    /// What goes wrong without it, in words for the warning.
    var consequence: String {
        switch self {
        case .microphone:
            "Microphone access is off, so DeFeedbackHost can't route audio input through the plug-ins."
        case .localNetwork:
            "Local Network access is off, so other devices can't reach the web control page."
        case .loginItems:
            "Launch permissions need approval, so launch at login and restart after a crash won't work."
        }
    }

    /// Where the user turns it on.
    var settingsPath: String {
        switch self {
        case .microphone: "System Settings › Privacy & Security › Microphone"
        case .localNetwork: "System Settings › Privacy & Security › Local Network"
        case .loginItems: "System Settings › General › Login Items & Extensions"
        }
    }

    /// Deep link to the matching System Settings pane. nil for Login Items, which has its own API.
    var settingsURL: URL? {
        switch self {
        case .microphone:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .localNetwork:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
        case .loginItems:
            nil
        }
    }
}

enum PermissionState: Equatable, Sendable {
    case granted
    case denied
    case notDetermined
    /// Couldn't tell. Never produces a warning.
    case unknown

    var needsAttention: Bool { self == .denied || self == .notDetermined }
}

@MainActor
protocol PermissionChecker: AnyObject {
    var permission: Permission { get }
    func check() async -> PermissionState
    func request() async -> PermissionState
}
