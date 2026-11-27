//
//  WebControlService.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/20/2026.
//

import AppKit
import Foundation
import Observation

// MARK: -
// MARK: WebControlService

/// The web service that allows for control of the host and plugin instances.  POST is used for command sending,
///  and EventStreams are used for status updates. JSON is used for the data format.
///
///  - AI used for framework, most features added by human.
@Observable
@MainActor
final class WebControlService {

    /// How often to take the status snaphot
    static let statusInterval: Duration = .milliseconds(250)

    /// Keep alive interval for the web connection
    static let statusKeepAlive: Duration = .seconds(2)

    /// History:
    ///  - 1: initial version.
    static let protocolVersion = 1

    @ObservationIgnored let host: AudioHost

    /// Read-only view of update state for `GET /api/update`. Set by the app delegate; nil in tests
    /// that don't care, in which case the endpoint reports updates as disabled.
    @ObservationIgnored weak var updateSource: UpdateStatusSource?

    /// Everything that has something to warn about (updates, permissions). Collected into the
    /// `warnings` array of every status payload. Set by the app delegate.
    @ObservationIgnored var warningSources: [WarningSource] = []

    /// The shutdown settings behind `POST /api/shutdown` and the status `shutdown` object. Set by the
    /// app delegate; nil (tests, previews) behaves as shutdown disabled. The command always reads
    /// these live; the status snapshot reads them through a one-second cache (`statusShutdownSettings`).
    @ObservationIgnored var shutdownSettings: ShutdownSettings? {
        didSet { statusShutdownSettings = shutdownSettings.map { CachedShutdownSettings($0) } }
    }

    /// Display-only view of `shutdownSettings` for the status snapshot, which is rebuilt several times a second.
    @ObservationIgnored private var statusShutdownSettings: CachedShutdownSettings?

    /// Performs the shutdown once every check has passed. Set by the app delegate.
    @ObservationIgnored var systemShutdown: SystemShutdown?

    @ObservationIgnored private var server: HTTPServer?
    @ObservationIgnored private let events = EventStream()
    @ObservationIgnored private let authGuard = BasicAuth.Guard()

    @ObservationIgnored private var activeSettings: (settings: WebServerSettings, password: String)?

    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var lastSentPayload: Data?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?

    @ObservationIgnored private var cachedIndexPage: Data?

    // MARK: - Observable state, for the settings window

    private(set) var state: HTTPServer.State = .stopped

    private(set) var connectedClients = 0

    var isListening: Bool {
        if case .listening = state { return true }
        return false
    }

    var listeningPort: UInt16? {
        if case .listening(let port) = state { return port }
        return nil
    }

    var errorMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    var reachableURL: String? {
        guard let port = listeningPort else { return nil }
        var name = ProcessInfo.processInfo.hostName
        if name.hasSuffix(".") { name.removeLast() }
        if name.isEmpty { name = "localhost" }
        return "http://\(name):\(port)/"
    }

    init(host: AudioHost) {
        self.host = host

        events.onClientCountChanged = { [weak self] count in
            guard let self else { return }
            Task { @MainActor in
                self.clientCountChanged(count)
            }
        }

        // make sure we shut down fully when terminating
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.shutDown()
            }
        }
    }

    // MARK: - Lifecycle

    func reconcile() {
        let settings = host.webServerSettings
        let password = settings.requiresAuthentication ? (KeychainPassword.read() ?? "") : ""

        guard settings.isEnabled else {
            shutDown()
            state = .failed(WebErrorStrings.ServiceDisabled.rawValue)
            return
        }

        let authValid = settings.isAuthenticationComplete
            && (!settings.requiresAuthentication
                || !password.isEmpty)

        guard authValid else {
            if settings.isEnabled, !settings.isAuthenticationComplete || password.isEmpty {
                shutDown()
                state = .failed(WebErrorStrings.IncompleteCredentials.rawValue)
            } else {
                shutDown()
            }
            return
        }

        authGuard.require(settings.requiresAuthentication
                          ? BasicAuth.Credentials(username: settings.username, password: password)
                          : nil,
                          allowingLoopback: settings.unauthedLocalhostAllowed)

        if let activeSettings, activeSettings.settings.port == settings.port, server != nil {
            self.activeSettings = (settings, password)
            return
        }

        startListener(on: settings.port)
        activeSettings = (settings, password)
    }

    private func startListener(on port: Int) {
        stopListener()

        let server = HTTPServer(router: { [weak self] request in
            if let rejection = self?.authGuard.reject(request) {
                return .respond(rejection)
            }
            guard let self else {
                return .respond(.error(503, WebErrorStrings.ShuttingDown.rawValue,
                                       closeConnection: true))
            }
            return await routeEndpoint(request)
        }, onStateChange: { [weak self] newState in
            guard let self else { return }
            Task { @MainActor in
                self.state = newState
            }
        })

        self.server = server
        server.start(port: UInt16(clamping: port))
    }

    private func stopListener() {
        statusTask?.cancel()
        statusTask = nil
        lastSentPayload = nil

        events.closeAll()
        server?.stop()
        server = nil
    }

    func shutDown() {
        stopListener()
        activeSettings = nil
        connectedClients = 0
        state = .stopped
    }

    // MARK: - Endpoints

    /// Answers a request: `/api/instances/{id}` by template first, then the table in `WebRoutes`.
    func routeEndpoint(_ request: HTTPRequest) async -> HTTPServer.RouteOutcome {
        if let id = Self.extractPathFromTemplate(in: request.path, matching: WebRoutes.instanceTemplate) {
            return await WebRoutes.instance.answer(request, from: self, id: id)
        }
        guard let route = WebRoutes.table[request.path] else {
            return .respond(.error(404, WebErrorStrings.pageNotFound(path: request.path)))
        }
        return await route.answer(request, from: self, id: nil)
    }

    /// Extracts the path from a templated URL.
    nonisolated static func extractPathFromTemplate(in path: String, matching template: String) -> String? {
        guard let brace = template.lastIndex(of: "{") else { return nil }
        let prefix = template[template.startIndex..<brace]

        guard path.hasPrefix(prefix) else { return nil }
        let tail = path.dropFirst(prefix.count)
        guard !tail.isEmpty, !tail.contains("/") else { return nil }

        return String(tail)
    }

    func pageResponse() -> HTTPResponse {
        if let cachedIndexPage {
            return .html(cachedIndexPage)
        }
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html"),
              let data = try? Data(contentsOf: url) else {
            return .error(500, WebErrorStrings.IndexPageMissing.rawValue)
        }
        cachedIndexPage = data
        return .html(data)
    }

    // MARK: - Status

    /// `GET /api/update`. Never triggers a check; reports what the app already knows.
    func updatePayload() -> [String: Any] { payloads.update() }

    /// The `warnings` array of the status payload: every source's current warnings, in source order.
    func warningPayload() -> [[String: Any]] { payloads.warnings() }

    func statusPayload() -> [String: Any] { payloads.status() }

    private var payloads: WebStatusPayload {
        WebStatusPayload(host: host, updateSource: updateSource, warningSources: warningSources,
                         shutdownSettings: statusShutdownSettings)
    }

    func attachStream(_ stream: HTTPStream) {
        events.add(stream)
        pushStatus(force: true)
    }

    private func clientCountChanged(_ count: Int) {
        connectedClients = count
        if count > 0 {
            startStatusLoop()
        } else {
            statusTask?.cancel()
            statusTask = nil
            lastSentPayload = nil
        }
    }

    private func startStatusLoop() {
        guard statusTask == nil else { return }

        statusTask = Task { [weak self] in
            var ticksSinceSend = 0
            let ticksPerKeepAlive = max(1, Int(Self.statusKeepAlive / Self.statusInterval))

            while !Task.isCancelled {
                try? await Task.sleep(for: Self.statusInterval)
                guard let self, !Task.isCancelled else { return }

                ticksSinceSend += 1
                let force = ticksSinceSend >= ticksPerKeepAlive
                if pushStatus(force: force) {
                    ticksSinceSend = 0
                }
            }
        }
    }

    @discardableResult
    func pushStatus(force: Bool) -> Bool {
        guard connectedClients > 0 else { return false }
        guard let payload = try? JSONSerialization.data(withJSONObject: statusPayload(),
                                                        options: [.sortedKeys]) else {
            return false
        }

        if !force, payload == lastSentPayload { return false }

        lastSentPayload = payload
        events.broadcast(event: "status", json: payload)
        return true
    }
}
