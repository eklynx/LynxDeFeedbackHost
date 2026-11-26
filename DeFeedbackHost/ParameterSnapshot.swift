//
//  ParameterSnapshot.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/17/26.
//

import AudioToolbox
import Synchronization

/// A value holder for an AU parameter in an Atomic fashion for passing to the instance plugins.
/// Parameters are done this way so the pulugin instances can set values without blocking.
nonisolated final class ParameterSnapshot: @unchecked Sendable {

    private static let absent = UInt64.max
    private let stored = Atomic<UInt64>(absent)

    var value: AUValue? {
        let raw = stored.load(ordering: .relaxed)
        guard raw != Self.absent else { return nil }
        return AUValue(bitPattern: UInt32(truncatingIfNeeded: raw))
    }

    func store(_ value: AUValue) {
        stored.store(UInt64(value.bitPattern), ordering: .relaxed)
    }

    func clear() {
        stored.store(Self.absent, ordering: .relaxed)
    }
}
