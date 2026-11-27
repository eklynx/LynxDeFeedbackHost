//
//  AutomationPermission.swift
//  DeFeedbackHost
//
//  Automation (System Events) checker. Contract: PermissionChecking.swift. Only matters while a
//  real shutdown is possible, so (spec SH5) it reports `.granted` unless shutdown is enabled AND
//  test mode is off; only then does it look at, or ask for, the real permission.
//
import AppKit
import Foundation

/// Seam over the system's Automation permission query so tests don't touch it.
@MainActor
protocol AutomationAuthorizing: AnyObject {
    /// State of the permission to send Apple events to System Events. Prompts only if `askUser`.
    func state(askUser: Bool) -> PermissionState
}

@MainActor
final class SystemAutomationAuthorizer: AutomationAuthorizing {

    static let targetBundleID = "com.apple.systemevents"

    func state(askUser: Bool) -> PermissionState {
        // System Events is launched on demand; the permission query needs it running.
        if NSRunningApplication.runningApplications(withBundleIdentifier: Self.targetBundleID).isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.targetBundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            configuration.hides = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        let target = NSAppleEventDescriptor(bundleIdentifier: Self.targetBundleID)
        guard let address = target.aeDesc else { return .unknown }
        let status = AEDeterminePermissionToAutomateTarget(address, AEEventClass(typeWildCard),
                                                           AEEventID(typeWildCard), askUser)
        switch Int(status) {
        case Int(noErr): return .granted
        case -1743: return .denied                  // errAEEventNotPermitted
        case -1744: return .notDetermined           // errAEEventWouldRequireUserConsent
        default: return .unknown                    // e.g. -600 System Events not running yet
        }
    }
}

@MainActor
final class AutomationPermission: PermissionChecker {

    let permission = Permission.automation
    private let settings: ShutdownSettings
    private let authorizer: AutomationAuthorizing

    init(settings: ShutdownSettings, authorizer: AutomationAuthorizing? = nil) {
        self.settings = settings
        self.authorizer = authorizer ?? SystemAutomationAuthorizer()
    }

    /// Whether a real shutdown could be requested right now (SH5).
    private var isNeeded: Bool { settings.isEnabled && !settings.isTestMode }

    func check() async -> PermissionState {
        isNeeded ? authorizer.state(askUser: false) : .granted
    }

    /// Prompts only when the permission is needed, so a user who never enables shutdown never sees it.
    func request() async -> PermissionState {
        isNeeded ? authorizer.state(askUser: true) : .granted
    }
}
