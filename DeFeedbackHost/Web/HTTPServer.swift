//
//  HTTPServer.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/20/2026.
//

import Foundation
import Network
import os

/// A small HTTP/1.1 server over `NWListener`.
///
/// Deliberately hand-rolled rather than pulled in as a package: the whole surface is four routes
/// (`WebControlService`), and the app has no other dependencies. `HTTPRequestParser` holds all the
/// parsing, so what's left here is socket plumbing.
///
/// Nothing in this file may touch the audio path. It runs on its own utility queue; the only
/// crossing into `AudioHost` is the `async` route handler, which hops to the main actor.
///
/// `nonisolated` because the target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and
/// every callback here arrives on `queue` instead.
///
/// - AI was used heavily in creation of the core http server, as I didnt want to use a library to keep this lightweight.
nonisolated final class HTTPServer: @unchecked Sendable {

    enum State: Equatable {
        case stopped
        case starting
        case listening(port: UInt16)
        case failed(String)
    }

    /// What a route decided to do.
    enum RouteOutcome: Sendable {
        /// Ordinary request/response.
        case respond(HTTPResponse)

        /// Send `HTTPResponse`'s head, then hand the still-open connection over — how
        /// `/api/events` becomes an SSE stream. The response body is ignored; write through the
        /// stream instead.
        case stream(HTTPResponse, @Sendable (HTTPStream) -> Void)
    }

    typealias Router = @Sendable (HTTPRequest) async -> RouteOutcome

    /// Concurrent connections accepted before new ones are turned away with a 503.
    ///
    /// Bounded because each connection costs a receive buffer and a timer, and SSE clients hold
    /// theirs open indefinitely. A handful of browsers plus a few curl sessions fit comfortably.
    static let maximumConnections = 32

    /// How long a connection may sit without sending anything before it's dropped. Does not apply
    /// once a connection has been handed to a stream — those are idle by design.
    static let idleTimeout: TimeInterval = 30

    private let queue = DispatchQueue(label: "com.eklynx.sound.DeFeedbackHost.web",
                                      qos: .utility)

    private let log = Logger(subsystem: "com.eklynx.sound.DeFeedbackHost", category: "web")

    private let router: Router

    /// Called on `queue` whenever the listener's state changes.
    private let onStateChange: @Sendable (State) -> Void

    private var listener: NWListener?
    private var connections: Set<ObjectIdentifier> = []
    private var retained: [ObjectIdentifier: HTTPConnection] = [:]

    private(set) var state: State = .stopped {
        didSet {
            guard state != oldValue else { return }
            onStateChange(state)
        }
    }

    init(router: @escaping Router, onStateChange: @escaping @Sendable (State) -> Void) {
        self.router = router
        self.onStateChange = onStateChange
    }

    // MARK: - Lifecycle

    /// Binds every interface, which is the point — the endpoint has to be reachable from other
    /// machines. Deliberately no `requiredLocalEndpoint` and no `parameters.setLocalOnly`.
    func start(port: UInt16) {
        queue.async { [self] in
            stopLocked()

            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                state = .failed("Port \(port) is not a valid TCP port.")
                return
            }

            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            // A browser opening the page and the SSE stream at once should not be serialised
            // behind one connection's handshake.
            if let tcp = parameters.defaultProtocolStack
                .internetProtocol as? NWProtocolTCP.Options {
                tcp.noDelay = true
            }

            do {
                let listener = try NWListener(using: parameters, on: nwPort)
                self.listener = listener
                state = .starting

                listener.stateUpdateHandler = { [weak self] newState in
                    self?.listenerStateChanged(newState, requestedPort: port)
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: queue)
            } catch {
                state = .failed(Self.describe(error, port: port))
            }
        }
    }

    func stop() {
        queue.async { [self] in
            stopLocked()
            state = .stopped
        }
    }

    private func stopLocked() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil

        for connection in retained.values {
            connection.close()
        }
        retained.removeAll()
        connections.removeAll()
    }

    private func listenerStateChanged(_ newState: NWListener.State, requestedPort: UInt16) {
        switch newState {
        case .ready:
            state = .listening(port: listener?.port?.rawValue ?? requestedPort)
        case .failed(let error):
            log.error("web listener failed: \(String(describing: error), privacy: .public)")
            state = .failed(Self.describe(error, port: requestedPort))
            stopLocked()

        // Logged but not treated as fatal. A port already in use arrives as `.failed` above —
        // verified against a held port, which is what this case was first written to catch —
        // so what reaches `.waiting` is the transient kind the framework recovers from by
        // retrying. Tearing the listener down here would turn those into a failure the user has
        // to clear by hand.
        case .waiting(let error):
            log.notice("web listener waiting: \(String(describing: error), privacy: .public)")

        case .cancelled:
            if case .failed = state {} else { state = .stopped }
        case .setup:
            break
        @unknown default:
            break
        }
    }

    /// `EADDRINUSE` is the failure that will actually happen, so it gets said in words rather than
    /// as a POSIX code nobody should have to look up.
    private static func describe(_ error: Error, port: UInt16) -> String {
        if let nwError = error as? NWError, case .posix(let code) = nwError {
            switch code {
            case .EADDRINUSE:
                return "Port \(port) is already in use by another program."
            case .EACCES:
                return "Port \(port) needs administrator privileges. Choose a port above 1023."
            case .EADDRNOTAVAIL:
                return "Port \(port) isn't available on this machine's interfaces."
            default:
                break
            }
        }
        return "Couldn't listen on port \(port): \(error.localizedDescription)"
    }

    // MARK: - Connections

    private func accept(_ nwConnection: NWConnection) {
        guard connections.count < Self.maximumConnections else {
            // Answer rather than drop: a client that gets a 503 knows to back off, where a
            // silently closed socket looks like the server crashed.
            let response = HTTPResponse.error(503, "Too many connections", closeConnection: true)
            nwConnection.start(queue: queue)
            nwConnection.send(content: response.serialized(),
                              completion: .contentProcessed { _ in nwConnection.cancel() })
            return
        }

        let connection = HTTPConnection(connection: nwConnection,
                                        queue: queue,
                                        router: router,
                                        log: log) { [weak self] finished in
            self?.forget(finished)
        }

        let key = ObjectIdentifier(connection)
        connections.insert(key)
        retained[key] = connection
        connection.start()
    }

    private func forget(_ connection: HTTPConnection) {
        let key = ObjectIdentifier(connection)
        connections.remove(key)
        retained[key] = nil
    }
}
