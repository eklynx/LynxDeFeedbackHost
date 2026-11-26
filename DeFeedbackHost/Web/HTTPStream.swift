//
//  HTTPStream.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/20/2026.
//

import Foundation
import Network

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
