//
//  LaunchdSupervision.swift
//  DeFeedbackHost
//
//  Implementation of `LaunchSupervision` (contract: LaunchSupervision.swift).
//
import Foundation

struct LaunchdSupervision: LaunchSupervision {

    var environment: [String: String] = ProcessInfo.processInfo.environment
    var userID: uid_t = getuid()

    /// launchd sets `XPC_SERVICE_NAME` to the job label for every agent it spawns.
    var isRunningUnderSupervisor: Bool {
        environment["XPC_SERVICE_NAME"] == LaunchAgentKind.supervisor.label
    }

    func handOff(afterDelay: TimeInterval) -> Bool {
        let target = "gui/\(userID)/\(LaunchAgentKind.supervisor.label)"

        if afterDelay > 0 {
            // Detached so it outlives us: wait for this process to finish quitting, then start the job.
            let script = "sleep \(Int(afterDelay.rounded(.up))); /bin/launchctl kickstart \(target)"
            let process = Process()
            process.executableURL = URL(filePath: "/bin/sh")
            process.arguments = ["-c", script]
            do { try process.run(); return true } catch { return false }
        }

        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = ["kickstart", target]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
