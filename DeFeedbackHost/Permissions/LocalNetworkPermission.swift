//
//  LocalNetworkPermission.swift
//  DeFeedbackHost
//
//  Local Network checker. Contract: PermissionChecking.swift (edge case 5).
//
//  macOS has no API that reports the Local Network state, and no way to ask for it directly. The
//  accepted technique is to browse for a Bonjour service: the first browse raises the system
//  prompt, and a "policy denied" DNS error shows up as a `.waiting` state when it is not allowed.
//  The service type must be listed under NSBonjourServices in Info.plist (see
//  DeFeedbackHost/Updates/SparkleInfo.plist), or the system refuses the browse.
//
//  `.ready` does NOT mean allowed: it arrives before the user has answered the prompt. So `.ready`
//  only counts as "granted" once `settle` seconds pass with no denial. A denial that arrives later
//  (the user answers "Don't Allow") is caught by the re-check when the app becomes active again.
//
import Foundation
import Network
import os

@MainActor
final class LocalNetworkPermission: PermissionChecker {

    /// Starts a browse delivering state changes on `queue`; returns a closure that stops it.
    /// A seam so tests can feed states without raising a real system prompt.
    typealias Browse = @Sendable (DispatchQueue, @escaping @Sendable (NWBrowser.State) -> Void) -> @Sendable () -> Void

    let permission = Permission.localNetwork

    /// Must match the NSBonjourServices entry in the merged Info.plist.
    nonisolated static let serviceType = "_defeedbackhost._tcp"
    /// kDNSServiceErr_PolicyDenied: what the system reports when Local Network is denied.
    nonisolated static let policyDenied: Int32 = -65570

    /// The real browse, for the app.
    nonisolated static let systemBrowse: Browse = { queue, onState in
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
        browser.stateUpdateHandler = onState
        browser.browseResultsChangedHandler = { _, _ in }
        browser.start(queue: queue)
        return {
            browser.stateUpdateHandler = nil
            browser.cancel()
        }
    }

    private let timeout: TimeInterval
    private let settle: TimeInterval
    private let browse: Browse

    /// - Parameters:
    ///   - timeout: how long to wait for any decision. An unanswered prompt outlasts it, which is
    ///     `.unknown` (no warning); the next `refresh()` probes again.
    ///   - settle: how long `.ready` must go without a denial before it counts as granted.
    init(timeout: TimeInterval = 8, settle: TimeInterval = 2, browse: @escaping Browse = LocalNetworkPermission.systemBrowse) {
        self.timeout = timeout
        self.settle = settle
        self.browse = browse
    }

    /// Pure mapping of a browser state to a decision; nil means "not decided yet, keep waiting".
    /// `.granted` here is provisional (see the file header).
    nonisolated static func state(for browserState: NWBrowser.State) -> PermissionState? {
        switch browserState {
        case .ready:
            return .granted
        case .waiting(let error), .failed(let error):
            if case .dns(let code) = error, code == policyDenied { return .denied }
            if case .failed = browserState { return .unknown }
            return nil
        case .setup, .cancelled:
            return nil
        @unknown default:
            return nil
        }
    }

    func check() async -> PermissionState {
        let (timeout, settle, browse) = (timeout, settle, browse)
        return await withCheckedContinuation { continuation in
            Probe(timeout: timeout, settle: settle, browse: browse) { continuation.resume(returning: $0) }.start()
        }
    }

    func request() async -> PermissionState {
        await check()
    }

    /// One short browse. Everything runs on its own queue; `finish` runs at most once. It keeps
    /// ITSELF alive through the callbacks it hands out (strong captures) until `finish` drops them;
    /// holding it only weakly lets it be freed mid-probe and the result is never delivered.
    final class Probe: @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.eklynx.sound.DeFeedbackHost.localnetwork-probe")
        private let timeout: TimeInterval
        private let settle: TimeInterval
        private let browse: Browse
        private let completion: @Sendable (PermissionState) -> Void
        private var stop: (@Sendable () -> Void)?
        private var finished = false
        private var settling = false

        init(timeout: TimeInterval, settle: TimeInterval, browse: @escaping Browse,
             completion: @escaping @Sendable (PermissionState) -> Void) {
            self.timeout = timeout
            self.settle = settle
            self.browse = browse
            self.completion = completion
        }

        func start() {
            queue.async { [self] in
                stop = browse(queue) { [self] state in
                    // Callbacks arrive on `queue`.
                    Logger.host_application.notice("Local Network probe state: \(String(describing: state), privacy: .public)")
                    guard let decision = LocalNetworkPermission.state(for: state) else { return }
                    if decision == .granted {
                        beginSettling()
                    } else {
                        finish(decision)
                    }
                }
                queue.asyncAfter(deadline: .now() + timeout) { [self] in
                    // The timer always fires; it only matters if nothing decided before it.
                    if !finished {
                        Logger.host_application.notice("Local Network probe timed out with no decision")
                    }
                    finish(.unknown)
                }
            }
        }

        /// `.ready` seen: grant only if no denial follows within `settle`.
        private func beginSettling() {
            guard !settling, !finished else { return }
            settling = true
            queue.asyncAfter(deadline: .now() + settle) { [self] in finish(.granted) }
        }

        private func finish(_ result: PermissionState) {
            guard !finished else { return }
            finished = true
            stop?()
            stop = nil
            completion(result)
        }
    }
}
