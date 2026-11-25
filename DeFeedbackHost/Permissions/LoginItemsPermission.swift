//
//  LoginItemsPermission.swift
//  DeFeedbackHost
//
//  Login Items checker. Contract: PermissionChecking.swift (edge case 6): it only REPORTS. A launch
//  agent the user turned on that still awaits approval in System Settings is `.denied`; with
//  nothing turned on there is nothing to approve, so the state is `.granted`.
//
import Foundation
import ServiceManagement

@MainActor
final class LoginItemsPermission: PermissionChecker {

    let permission = Permission.loginItems
    private let agents: LaunchAgentControlling

    init(agents: LaunchAgentControlling = LaunchAgentService()) {
        self.agents = agents
    }

    func check() async -> PermissionState {
        let waiting = LaunchAgentKind.allCases.contains { agents.status(of: $0) == .requiresApproval }
        return waiting ? .denied : .granted
    }

    /// Nothing prompts for Login Items; registering agents here would turn the user's settings on.
    func request() async -> PermissionState {
        await check()
    }
}
