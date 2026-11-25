//
//  PermissionService.swift
//  DeFeedbackHost
//
//  Implements the service contract in PermissionChecking.swift. Owns the states and the warnings.
//
import AppKit
import Observation
import ServiceManagement
import os

@Observable
@MainActor
final class PermissionService: WarningSource {

    /// Starts as `.unknown` for everything, so nothing warns before the first check finishes.
    private(set) var states: [Permission: PermissionState]

    @ObservationIgnored private let checkers: [PermissionChecker]
    @ObservationIgnored private var started = false
    /// One pass at a time: two overlapping Local Network probes confuse the system prompt.
    @ObservationIgnored private var isChecking = false
    /// A refresh arrived mid-pass (e.g. the app came back after the user answered a prompt): run
    /// one more pass when this one ends, instead of losing it.
    @ObservationIgnored private var refreshRequested = false

    /// - Parameter checkers: in the order they should be asked.
    init(checkers: [PermissionChecker]) {
        self.checkers = checkers
        self.states = Dictionary(uniqueKeysWithValues: checkers.map { ($0.permission, .unknown) })
    }

    /// The permissions that currently need the user's attention, in checker order.
    var problems: [Permission] {
        checkers.map(\.permission).filter { states[$0]?.needsAttention == true }
    }

    var warnings: [AppWarning] {
        problems.map { permission in
            AppWarning(id: "permission.\(permission.rawValue)",
                       kind: .permission,
                       message: "\(permission.consequence) Allow it in \(permission.settingsPath).")
        }
    }

    /// Call once at launch. Checks everything and asks for what has never been asked (contract 8).
    func start() async {
        guard !started else { return }
        started = true
        isChecking = true
        for checker in checkers {
            var state = await checker.check()
            if state == .notDetermined {
                state = await checker.request()
            }
            states[checker.permission] = state
            Logger.host_application.notice("Permission \(checker.permission.rawValue, privacy: .public): \(String(describing: state), privacy: .public)")
        }
        await finishPass()
    }

    /// Re-checks without asking (contract 9). Safe to call as often as the app becomes active. If a
    /// pass is already running, one more follows it (never two at once).
    func refresh() async {
        guard started else { return }
        guard !isChecking else {
            refreshRequested = true
            return
        }
        isChecking = true
        await recheckAll()
        await finishPass()
    }

    private func recheckAll() async {
        for checker in checkers {
            let state = await checker.check()
            if states[checker.permission] != state {
                Logger.host_application.notice("Permission \(checker.permission.rawValue, privacy: .public) changed to \(String(describing: state), privacy: .public)")
            }
            states[checker.permission] = state
        }
    }

    private func finishPass() async {
        while refreshRequested {
            refreshRequested = false
            await recheckAll()
        }
        isChecking = false
    }

    func openSystemSettings(for permission: Permission) {
        if let url = permission.settingsURL {
            NSWorkspace.shared.open(url)
        } else {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
