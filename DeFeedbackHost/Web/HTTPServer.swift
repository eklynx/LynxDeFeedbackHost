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

/// One accepted connection: read, parse, dispatch, write, repeat.
///
/// All state is touched on the server's queue only.
nonisolated final class HTTPConnection: @unchecked Sendable {

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let router: HTTPServer.Router
    private let log: Logger
    private let onClose: @Sendable (HTTPConnection) -> Void

    private let isLoopback: Bool

    private var buffer: [UInt8] = []
    private var isClosed = false

    /// Set once the connection has been handed to a stream. From then on this object stops
    /// parsing: the bytes belong to whoever took it over.
    private var stream: HTTPStream?

    private var idleTimer: DispatchSourceTimer?

    init(connection: NWConnection,
         queue: DispatchQueue,
         router: @escaping HTTPServer.Router,
         log: Logger,
         onClose: @escaping @Sendable (HTTPConnection) -> Void) {
        self.connection = connection
        self.queue = queue
        self.router = router
        self.log = log
        self.onClose = onClose
        self.isLoopback = Self.isLoopback(connection.endpoint)
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        func isLoopbackV4(_ address: IPv4Address) -> Bool {
            address.rawValue.first == 127
        }

        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return isLoopbackV4(address)
        case .ipv6(let address):
            return address.isLoopback || (address.asIPv4.map(isLoopbackV4) ?? false)
        default:
            return false
        }
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
        armIdleTimer()
        receive()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true

        idleTimer?.cancel()
        idleTimer = nil

        stream?.didClose()
        stream = nil

        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose(self)
    }

    // MARK: - Reading

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                log.debug("web connection receive failed: \(error.localizedDescription, privacy: .public)")
                close()
                return
            }

            if let data, !data.isEmpty {
                armIdleTimer()
                buffer.append(contentsOf: data)
                drainBuffer()
            }

            if isComplete {
                close()
                return
            }

            // A hijacked connection keeps reading only so the peer's close is noticed; the bytes
            // themselves are discarded above by `drainBuffer` bailing out.
            if !isClosed {
                receive()
            }
        }
    }

    /// Parses as many complete requests as the buffer holds. Stops at the first one whose response
    /// is still being produced, so responses can't overtake each other on a pipelined connection.
    private func drainBuffer() {
        guard !isClosed, stream == nil else {
            buffer.removeAll(keepingCapacity: false)
            return
        }

        switch HTTPRequestParser.parse(buffer) {
        case .incomplete:
            return

        case .failed(let response):
            send(response, includeBody: true) { [weak self] in self?.close() }
            buffer.removeAll(keepingCapacity: false)

        case .complete(let request, let consumed):
            buffer.removeFirst(consumed)
            dispatch(request)
        }
    }

    private func dispatch(_ request: HTTPRequest) {
        var request = request
        request.isFromLoopback = isLoopback

        // The router hops to the main actor to read `AudioHost`, so this has to be async. The
        // connection reads nothing further until the response is out.
        Task { [weak self] in
            let outcome = await self?.router(request)
            guard let self, let outcome else { return }
            queue.async {
                self.complete(request, with: outcome)
            }
        }
    }

    private func complete(_ request: HTTPRequest, with outcome: HTTPServer.RouteOutcome) {
        guard !isClosed else { return }

        let includeBody = request.method != "HEAD"

        switch outcome {
        case .respond(var response):
            if !request.wantsKeepAlive {
                response.closeConnection = true
            }
            let shouldClose = response.closeConnection
            send(response, includeBody: includeBody) { [weak self] in
                guard let self else { return }
                if shouldClose {
                    close()
                } else {
                    // Anything pipelined behind this request is already in the buffer.
                    drainBuffer()
                }
            }

        case .stream(let response, let handOff):
            // An SSE stream has no length and never ends, so the idle timer must not apply.
            idleTimer?.cancel()
            idleTimer = nil

            let stream = HTTPStream(connection: connection, queue: queue) { [weak self] in
                self?.close()
            }
            self.stream = stream
            buffer.removeAll(keepingCapacity: false)

            send(response, includeBody: false) { [weak self] in
                guard let self, !isClosed else { return }
                handOff(stream)
            }
        }
    }

    // MARK: - Writing

    private func send(_ response: HTTPResponse,
                      includeBody: Bool,
                      then next: (@Sendable () -> Void)? = nil) {
        connection.send(content: response.serialized(includeBody: includeBody),
                        completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                log.debug("web connection send failed: \(error.localizedDescription, privacy: .public)")
                close()
                return
            }
            next?()
        })
    }

    // MARK: - Idle timeout

    /// Drops a peer that opens a connection and then says nothing — otherwise a handful of those
    /// would occupy every slot in the connection cap indefinitely.
    private func armIdleTimer() {
        idleTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + HTTPServer.idleTimeout)
        timer.setEventHandler { [weak self] in
            self?.close()
        }
        timer.resume()
        idleTimer = timer
    }
}

/// A connection that has been handed over to push data indefinitely — the SSE stream.
///
/// Writes are fire-and-forget: a failure means the peer has gone, which `onClose` reports so the
/// broadcaster can drop it.
nonisolated final class HTTPStream: @unchecked Sendable {

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let closeConnection: @Sendable () -> Void

    private var isClosed = false

    /// Set by the owner (`EventStream`) to hear about the peer going away.
    var onClose: (@Sendable () -> Void)?

    init(connection: NWConnection,
         queue: DispatchQueue,
         closeConnection: @escaping @Sendable () -> Void) {
        self.connection = connection
        self.queue = queue
        self.closeConnection = closeConnection
    }

    func write(_ data: Data) {
        queue.async { [self] in
            guard !isClosed else { return }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard error != nil else { return }
                self?.closeConnection()
            })
        }
    }

    func close() {
        queue.async { [self] in
            guard !isClosed else { return }
            closeConnection()
        }
    }

    /// Called by the connection once it has actually gone.
    func didClose() {
        guard !isClosed else { return }
        isClosed = true
        onClose?()
    }
}
