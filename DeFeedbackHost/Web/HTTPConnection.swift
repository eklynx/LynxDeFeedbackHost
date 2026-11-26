//
//  HTTPConnection.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/20/2026.
//

import Foundation
import Network
import os

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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
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
