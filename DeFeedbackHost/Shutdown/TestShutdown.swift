//
//  TestShutdown.swift
//  DeFeedbackHost
//
//  Test-mode shutdown: records that a shutdown would have happened. Contract: SystemShutdown.swift
//  (edge case 5): never throws, never needs a permission.
//
import Foundation
import os

@MainActor
final class TestShutdown: SystemShutdown {

    let isTestMode = true
    private(set) var performCount = 0

    func perform() async throws {
        performCount += 1
        Logger.host_application.notice("Shutdown requested in test mode: the computer would have shut down now.")
    }
}
