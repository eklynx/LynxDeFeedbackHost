//
//  InertUpdateEngine.swift
//  DeFeedbackHost
//
//  An `UpdateEngine` that does nothing. Used when running hosted under XCTest, so tests never
//  start Sparkle or touch the network (contract edge case 8 in UpdateChecking.swift).
//
import Foundation

@MainActor
final class InertUpdateEngine: UpdateEngine {

    func probe(channel: UpdateChannel, onResult: @escaping @MainActor (ProbeResult) -> Void) {
        onResult(.failed("Update checking is disabled in this process."))
    }

    func presentUpdate(channel: UpdateChannel) {}
}
