//
//  LaunchAgentService.swift
//  DeFeedbackHost
//
//  Registers/unregisters the two launch agents (contract: LaunchSupervision.swift).
//
import ServiceManagement

/// Happy path: `setEnabled` registers/unregisters and `status` reflects it (`.enabled`).
/// Errors: `setEnabled` throws what `SMAppService` throws; `.requiresApproval` means registered but
/// the user must allow it in System Settings › Login Items; `.notFound` means the plist is missing
/// from the app bundle (a packaging bug, or a stale registration of a removed plist).
protocol LaunchAgentControlling {
    func status(of kind: LaunchAgentKind) -> SMAppService.Status
    func setEnabled(_ enabled: Bool, for kind: LaunchAgentKind) throws
}

struct LaunchAgentService: LaunchAgentControlling {

    private func service(for kind: LaunchAgentKind) -> SMAppService {
        SMAppService.agent(plistName: kind.plistName)
    }

    func status(of kind: LaunchAgentKind) -> SMAppService.Status {
        service(for: kind).status
    }

    func setEnabled(_ enabled: Bool, for kind: LaunchAgentKind) throws {
        let service = service(for: kind)
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }
    }
}
