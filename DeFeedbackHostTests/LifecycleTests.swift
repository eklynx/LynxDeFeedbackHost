//
//  LifecycleTests.swift
//  DeFeedbackHostTests
//
//  Covers docs/launch-and-restart-spec.md rules L1–L7 (decision logic only; real launchd
//  behaviour is in the spec's manual checklist).
//

import Foundation
import Testing

@testable import DeFeedbackHost

// MARK: - Fakes

private final class FakeLock: InstanceLock {
    var acquirable: Bool
    var pid: pid_t?
    var age: TimeInterval?
    var acquireCalls = 0
    init(acquirable: Bool, pid: pid_t? = nil, age: TimeInterval? = nil) {
        self.acquirable = acquirable; self.pid = pid; self.age = age
    }
    func tryAcquire() -> Bool { acquireCalls += 1; return acquirable }
    func release() {}
    func holderPID() -> pid_t? { pid }
    func heartbeat() {}
    func holderHeartbeatAge() -> TimeInterval? { age }
}

private final class FakeSupervision: LaunchSupervision, @unchecked Sendable {
    let isRunningUnderSupervisor: Bool
    let handOffSucceeds: Bool
    private(set) var handOffCalls = 0
    init(supervised: Bool, handOffSucceeds: Bool = true) {
        self.isRunningUnderSupervisor = supervised; self.handOffSucceeds = handOffSucceeds
    }
    func handOff(afterDelay: TimeInterval) -> Bool { handOffCalls += 1; return handOffSucceeds }
}

private final class FakeStrikes: StrikeStore { var count = 0 }

private func coordinator(lock: FakeLock, supervision: FakeSupervision, restartOn: Bool,
                         strikes: FakeStrikes = FakeStrikes()) -> LaunchCoordinator {
    var c = LaunchCoordinator(lock: lock, supervision: supervision,
                              supervisorEnabled: { restartOn }, strikes: strikes)
    c.pause = { _ in }
    c.kill = { _ in Issue.record("nothing should be killed in this scenario") }
    return c
}

// MARK: - Startup decisions

struct LaunchCoordinatorTests {

    @Test("L1: nobody running, restart off -> run directly")
    func runsDirectlyWhenRestartIsOff() {
        let supervision = FakeSupervision(supervised: false)
        let action = coordinator(lock: FakeLock(acquirable: true), supervision: supervision, restartOn: false).decide()
        #expect(action == .proceed)
        #expect(supervision.handOffCalls == 0)
    }

    @Test("L2: restart on, launched outside launchd -> hand off and exit without taking the lock")
    func handsOffWhenNotSupervised() {
        let lock = FakeLock(acquirable: true)
        let supervision = FakeSupervision(supervised: false)
        let action = coordinator(lock: lock, supervision: supervision, restartOn: true).decide()
        #expect(action == .exitHandedOff)
        #expect(supervision.handOffCalls == 1)
        #expect(lock.acquireCalls == 0)
    }

    @Test("L3: restart on, already under the supervisor -> run, no further hand-off")
    func runsWhenAlreadySupervised() {
        let supervision = FakeSupervision(supervised: true)
        let action = coordinator(lock: FakeLock(acquirable: true), supervision: supervision, restartOn: true).decide()
        #expect(action == .proceed)
        #expect(supervision.handOffCalls == 0)
    }

    @Test("L4: a manual second launch activates the running instance and never kills")
    func secondManualLaunchActivatesHolder() {
        let lock = FakeLock(acquirable: false, pid: 4242, age: 999)   // even a stale-looking holder
        let action = coordinator(lock: lock, supervision: FakeSupervision(supervised: false), restartOn: false).decide()
        #expect(action == .activateHolderAndExit(4242))
    }

    @Test("L5: hand-off refused (not approved / already running) falls through to the lock")
    func failedHandOffFallsThroughToTheLock() {
        let free = coordinator(lock: FakeLock(acquirable: true),
                               supervision: FakeSupervision(supervised: false, handOffSucceeds: false),
                               restartOn: true).decide()
        #expect(free == .proceed)

        let taken = coordinator(lock: FakeLock(acquirable: false, pid: 7, age: 1),
                                supervision: FakeSupervision(supervised: false, handOffSucceeds: false),
                                restartOn: true).decide()
        #expect(taken == .activateHolderAndExit(7))
    }

    @Test("A successful acquire resets the strike counter")
    func acquiringResetsStrikes() {
        let strikes = FakeStrikes(); strikes.count = 2
        _ = coordinator(lock: FakeLock(acquirable: true), supervision: FakeSupervision(supervised: true),
                        restartOn: true, strikes: strikes).decide()
        #expect(strikes.count == 0)
    }

    @Test("A supervised launch waits for the previous instance to finish quitting")
    func supervisedLaunchWaitsForLock() {
        final class Releasing: InstanceLock {
            var calls = 0
            func tryAcquire() -> Bool { calls += 1; return calls >= 4 }
            func release() {}
            func holderPID() -> pid_t? { 1 }
            func heartbeat() {}
            func holderHeartbeatAge() -> TimeInterval? { 0 }
        }
        let lock = Releasing()
        var c = LaunchCoordinator(lock: lock, supervision: FakeSupervision(supervised: true),
                                  supervisorEnabled: { true }, strikes: FakeStrikes())
        c.pause = { _ in }
        #expect(c.decide() == .proceed)
        #expect(lock.calls == 4)
    }
}

// MARK: - Supervision facts

struct LaunchdSupervisionTests {

    @Test("L6: launchd's XPC_SERVICE_NAME identifies the supervisor job")
    func detectsSupervisorFromEnvironment() {
        #expect(LaunchdSupervision(environment: ["XPC_SERVICE_NAME": LaunchAgentKind.supervisor.label]).isRunningUnderSupervisor)
        // The login agent and Finder launches are NOT supervised.
        #expect(!LaunchdSupervision(environment: ["XPC_SERVICE_NAME": LaunchAgentKind.login.label]).isRunningUnderSupervisor)
        #expect(!LaunchdSupervision(environment: ["XPC_SERVICE_NAME": "0"]).isRunningUnderSupervisor)
        #expect(!LaunchdSupervision(environment: [:]).isRunningUnderSupervisor)
    }

    @Test("Labels and plist names match the files shipped in the bundle")
    func labelsMatchPlists() throws {
        for kind in LaunchAgentKind.allCases {
            #expect(kind.plistName == "\(kind.label).plist")
        }
        #expect(LaunchAgentKind.login.label != LaunchAgentKind.supervisor.label)
    }
}

// MARK: - The lock

struct FileInstanceLockTests {

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "lifecycle-\(UUID().uuidString)")
    }

    @Test("L7: a second lock on the same file is refused until the first is released")
    func contention() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = FileInstanceLock(directory: directory)
        let second = FileInstanceLock(directory: directory)

        #expect(first.tryAcquire())
        #expect(first.tryAcquire(), "re-acquiring by the holder is idempotent")
        #expect(!second.tryAcquire())
        #expect(second.holderPID() == getpid())

        first.release()
        #expect(second.tryAcquire())
    }

    @Test("The heartbeat refreshes the holder's age")
    func heartbeatAge() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let lock = FileInstanceLock(directory: directory)
        #expect(lock.tryAcquire())

        let old = Date().addingTimeInterval(-60)
        try FileManager.default.setAttributes([.modificationDate: old],
                                              ofItemAtPath: directory.appending(path: "instance.lock").path)
        #expect((lock.holderHeartbeatAge() ?? 0) > 50)

        lock.heartbeat()
        #expect((lock.holderHeartbeatAge() ?? 99) < 5)
    }

    @Test("An unusable lock location fails open so the app can still start")
    func failsOpen() {
        let lock = FileInstanceLock(directory: URL(filePath: "/dev/null/not-a-directory"))
        #expect(lock.tryAcquire())
    }
}

// MARK: - Stale holder policy (L8)

struct StaleHolderPolicyTests {

    private func verdict(supervised: Bool = true, strikes: Int = 3, age: TimeInterval? = 60,
                         sameApp: Bool = true) -> HolderVerdict {
        StaleHolderPolicy.verdict(startedBySupervisor: supervised, contendedLaunches: strikes,
                                  heartbeatAge: age, holderIsSameApp: sameApp)
    }

    @Test func manualLaunchesNeverKill() {
        #expect(verdict(supervised: false) == .leaveAlone)
    }

    @Test func aHealthyHolderIsLeftAlone() {
        #expect(verdict(strikes: 99, age: 1) == .leaveAlone)
    }

    @Test func anUnknownHeartbeatIsNotTreatedAsStale() {
        #expect(verdict(strikes: 99, age: nil) == .leaveAlone)
    }

    @Test func aStaleHolderIsRetriedBeforeTheStrikeLimit() {
        #expect(verdict(strikes: 1) == .retryLater)
        #expect(verdict(strikes: StaleHolderPolicy.strikesBeforeKill - 1) == .retryLater)
    }

    @Test func aStaleHolderIsKilledAtTheStrikeLimit() {
        #expect(verdict(strikes: StaleHolderPolicy.strikesBeforeKill) == .kill)
    }

    @Test func neverKillsAProcessThatIsNotThisApp() {
        #expect(verdict(strikes: 99, sameApp: false) == .retryLater)
    }
}
