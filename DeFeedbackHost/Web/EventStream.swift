//
//  EventStream.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/20/2026.
//

import Foundation

/// Server-Sent Events fan-out: the push half of the control channel.
///
/// Chosen over WebSockets because it's plain HTTP — one Basic Auth check covers it like every
/// other route, the browser's `EventSource` reconnects on its own, and there's no handshake or
/// frame codec to hand-write. The cost is that it only carries app → browser; commands come back
/// as ordinary `POST`s.
///
/// `nonisolated` and lock-guarded: clients are added and dropped on the server's network queue
/// while `broadcast` is called from the main actor's status loop.
///
/// - AI was used heavily in creation of the core http server, as I didnt want to use a library to keep this lightweight.

nonisolated final class EventStream: @unchecked Sendable {

    /// How long the browser waits before reconnecting a dropped stream. Sent once as the stream
    /// opens; the default is 3 s, and a control surface should come back faster than that.
    static let reconnectDelayMilliseconds = 1_000

    private let lock = NSLock()
    private var clients: [ObjectIdentifier: HTTPStream] = [:]

    /// Reported whenever a client attaches or drops, so the status loop can stop polling
    /// `AudioHost` while nobody is watching.
    var onClientCountChanged: (@Sendable (Int) -> Void)?

    var clientCount: Int {
        lock.withLock { clients.count }
    }

    /// The head that turns a normal response into an event stream.
    ///
    /// `no-store` and `X-Accel-Buffering` both exist to stop anything in the middle holding events
    /// back until it has a bufferful — the whole point is that they arrive as they happen.
    static var preamble: HTTPResponse {
        HTTPResponse(status: 200,
                     headers: HTTPHeaders([
                        ("Content-Type", "text/event-stream; charset=utf-8"),
                        ("Cache-Control", "no-store"),
                        ("X-Accel-Buffering", "no"),
                     ]),
                     isStreaming: true)
    }

    // MARK: - Membership

    func add(_ stream: HTTPStream) {
        let key = ObjectIdentifier(stream)

        stream.onClose = { [weak self, weak stream] in
            guard let self, let stream else { return }
            remove(ObjectIdentifier(stream))
        }

        let count: Int = lock.withLock {
            clients[key] = stream
            return clients.count
        }

        stream.write(Data("retry: \(Self.reconnectDelayMilliseconds)\n\n".utf8))
        onClientCountChanged?(count)
    }

    private func remove(_ key: ObjectIdentifier) {
        let (removed, count): (Bool, Int) = lock.withLock {
            let existed = clients.removeValue(forKey: key) != nil
            return (existed, clients.count)
        }
        guard removed else { return }
        onClientCountChanged?(count)
    }

    func closeAll() {
        let existing: [HTTPStream] = lock.withLock {
            let values = Array(clients.values)
            clients.removeAll()
            return values
        }
        for stream in existing {
            stream.close()
        }
        if !existing.isEmpty {
            onClientCountChanged?(0)
        }
    }

    // MARK: - Sending

    func broadcast(event: String, json: Data) {
        let frame = Self.frame(event: event, data: String(decoding: json, as: UTF8.self))
        send(frame)
    }

    private func send(_ data: Data) {
        let targets: [HTTPStream] = lock.withLock { Array(clients.values) }
        for stream in targets {
            stream.write(data)
        }
    }

    /// Builds one SSE frame.
    ///
    /// Every line of the payload needs its own `data:` prefix — a raw newline inside one would
    /// otherwise end the field and corrupt the event. JSON is sent without pretty-printing so
    /// this is normally a single line, but the split is the correctness guarantee, not an
    /// assumption about the encoder.
    static func frame(event: String, data: String) -> Data {
        var text = "event: \(event)\n"
        // `split` with `omittingEmptySubsequences: false` keeps blank lines inside the payload.
        for line in data.split(separator: "\n", omittingEmptySubsequences: false) {
            text += "data: \(line)\n"
        }
        text += "\n"
        return Data(text.utf8)
    }
}
