//
//  UpdateTests.swift
//  DeFeedbackHostTests
//
//  Covers docs/updates-spec.md rules U1–U12, U14–U16, U18–U22 (U13 lives in OpenAPIConformanceTests,
//  U23–U24 in UpdateScriptTests).
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import Foundation
import Testing

@testable import DeFeedbackHost

/// Records calls and answers probes from a script, so nothing touches Sparkle or the network.
@MainActor
private final class FakeEngine: UpdateEngine {
    var probeCount = 0
    var presentCount = 0
    var probeChannels: [UpdateChannel] = []
    var presentChannels: [UpdateChannel] = []
    var results: [ProbeResult] = []
    var fallback: ProbeResult = .upToDate

    func probe(channel: UpdateChannel, onResult: @escaping @MainActor (ProbeResult) -> Void) {
        probeCount += 1
        probeChannels.append(channel)
        onResult(results.isEmpty ? fallback : results.removeFirst())
    }

    func presentUpdate(channel: UpdateChannel) {
        presentCount += 1
        presentChannels.append(channel)
    }
}

/// A sleep that returns instantly `budget` times, recording the delays, then parks (cancellably).
@MainActor
private final class FakeClock {
    var delays: [TimeInterval] = []
    var budget: Int

    init(budget: Int) { self.budget = budget }

    func sleep(_ seconds: TimeInterval) async throws {
        delays.append(seconds)
        if budget > 0 {
            budget -= 1
            await Task.yield()
        } else {
            try await Task.sleep(for: .seconds(100_000))
        }
    }
}

@MainActor
private func withService(enabled: Bool = false,
                         interval: UpdateInterval? = nil,
                         engine: FakeEngine? = nil,
                         clock: FakeClock? = nil,
                         _ body: (UpdateService, FakeEngine, FakeClock, UserDefaults) async throws -> Void) async rethrows {
    let name = "DeFeedbackHostTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    if enabled { defaults.set(true, forKey: UpdatePreferences.Key.enabled) }
    if let interval { defaults.set(interval.rawValue, forKey: UpdatePreferences.Key.checkInterval) }
    let engine = engine ?? FakeEngine()
    let clock = clock ?? FakeClock(budget: 0)
    let service = UpdateService(engine: engine, defaults: defaults, sleep: { try await clock.sleep($0) })
    try await body(service, engine, clock, defaults)
}

/// Lets the service's timer task run until `condition` holds (bounded, so a bug fails, not hangs).
@MainActor
private func settle(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() { await Task.yield() }
}

@MainActor
struct UpdateTests {

    @Test("U1: checking is off by default; default interval is one day")
    func defaultsAreOptIn() async {
        await withService { service, _, _, _ in
            #expect(service.isEnabled == false)
            #expect(service.status.isEnabled == false)
            #expect(service.interval == .daily)
        }
    }

    @Test("U2: setting off means no probe at startup")
    func offMeansNoProbe() async {
        await withService { service, engine, _, _ in
            service.start()
            await Task.yield()
            #expect(engine.probeCount == 0)
        }
    }

    @Test("U3: setting on probes once at startup")
    func startupProbeWhenEnabled() async {
        await withService(enabled: true) { service, engine, _, _ in
            service.start()
            await settle { engine.probeCount >= 1 }
            #expect(engine.probeCount == 1)
        }
    }

    @Test("U4: turning the setting on probes immediately")
    func enablingProbesNow() async {
        await withService { service, engine, _, defaults in
            service.start()
            service.isEnabled = true
            await settle { engine.probeCount >= 1 }
            #expect(engine.probeCount == 1)
            #expect(defaults.bool(forKey: UpdatePreferences.Key.enabled))
        }
    }

    @Test("U4: turning the setting off stops further probes")
    func disablingStopsProbes() async {
        await withService(enabled: true, clock: FakeClock(budget: 5)) { service, engine, clock, _ in
            service.start()
            service.isEnabled = false
            let before = engine.probeCount
            for _ in 0..<50 { await Task.yield() }
            #expect(engine.probeCount == before)
            #expect(service.status.isEnabled == false)
        }
    }

    @Test("U5: probes repeat every chosen interval")
    func probesRepeatEveryInterval() async {
        let clock = FakeClock(budget: 2)
        await withService(enabled: true, interval: .everySixHours, clock: clock) { service, engine, clock, _ in
            service.start()
            await settle { engine.probeCount >= 3 }
            #expect(engine.probeCount == 3)
            #expect(clock.delays.prefix(2).allSatisfy { $0 == UpdateInterval.everySixHours.seconds })
        }
    }

    @Test("U6: stored intervals snap to a preset; junk falls back to the default")
    func intervalSnapsToPreset() {
        let name = "DeFeedbackHostTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set(25_000.0, forKey: UpdatePreferences.Key.checkInterval)
        #expect(UpdatePreferences(from: defaults).interval == .everySixHours)

        defaults.set(10.0, forKey: UpdatePreferences.Key.checkInterval)
        #expect(UpdatePreferences(from: defaults).interval == .hourly)

        defaults.set(999_999_999.0, forKey: UpdatePreferences.Key.checkInterval)
        #expect(UpdatePreferences(from: defaults).interval == .weekly)

        defaults.removeObject(forKey: UpdatePreferences.Key.checkInterval)
        #expect(UpdatePreferences(from: defaults).interval == .daily)
    }

    @Test("U7: a found update is recorded")
    func foundUpdateIsRecorded() async {
        let engine = FakeEngine()
        engine.fallback = .updateAvailable(version: "9.9.9", link: nil)
        await withService(enabled: true, engine: engine) { service, engine, _, _ in
            service.start()
            await settle { service.status.isUpdateAvailable }
            #expect(service.status.availableVersion == "9.9.9")
            #expect(service.status.lastChecked != nil)
            #expect(service.status.releasesPage == UpdateLinks.releasesPage)
        }
    }

    @Test("U7: up to date clears a previously found update")
    func upToDateClears() async {
        let engine = FakeEngine()
        engine.results = [.updateAvailable(version: "2.0", link: nil), .upToDate]
        await withService(enabled: true, engine: engine, clock: FakeClock(budget: 1)) { service, engine, _, _ in
            service.start()
            await settle { engine.probeCount >= 2 }
            #expect(service.status.availableVersion == nil)
        }
    }

    @Test("U8: a failed probe keeps a known update and records the error")
    func failureKeepsKnownUpdate() async {
        let engine = FakeEngine()
        engine.results = [.updateAvailable(version: "2.0", link: nil), .failed("offline")]
        await withService(enabled: true, engine: engine, clock: FakeClock(budget: 1)) { service, engine, _, _ in
            service.start()
            await settle { engine.probeCount >= 2 }
            #expect(service.status.availableVersion == "2.0")
            #expect(service.status.lastError == "offline")
        }
    }

    @Test("U9: the menu check works with the setting off")
    func manualCheckWorksWhenDisabled() async {
        await withService { service, engine, _, _ in
            service.checkForUpdates()
            #expect(engine.presentCount == 1)
            #expect(engine.probeCount == 0)
        }
    }

    @Test("U9: Update Now does nothing when no update is known")
    func installNowNeedsKnownUpdate() async {
        let engine = FakeEngine()
        engine.fallback = .updateAvailable(version: "3.0", link: nil)
        await withService(enabled: true, engine: engine) { service, engine, _, _ in
            service.installNow()
            #expect(engine.presentCount == 0)
            service.start()
            await settle { service.status.isUpdateAvailable }
            service.installNow()
            #expect(engine.presentCount == 1)
        }
    }

    @Test("U10: background probes never start the install flow")
    func probesNeverInstall() async {
        let engine = FakeEngine()
        engine.fallback = .updateAvailable(version: "3.0", link: nil)
        await withService(enabled: true, engine: engine, clock: FakeClock(budget: 3)) { service, engine, _, _ in
            service.start()
            await settle { engine.probeCount >= 4 }
            #expect(engine.presentCount == 0)
        }
    }

    @Test("U11: scheduler honours the floor; success waits the full interval")
    func schedulerFloorAndSuccessDelay() {
        for interval in UpdateInterval.allCases {
            #expect(UpdateScheduler.delay(after: .upToDate, interval: interval) == interval.seconds)
            #expect(UpdateScheduler.delay(after: .updateAvailable(version: "1", link: nil), interval: interval) == interval.seconds)
            #expect(UpdateScheduler.delay(after: .failed("x"), interval: interval) >= UpdateScheduler.minimumDelay)
            #expect(UpdateScheduler.delay(after: .failed("x"), interval: interval) <= interval.seconds)
        }
    }

    @Test("U11: a failed probe retries sooner than a long interval, never later than the interval")
    func failureRetriesSooner() {
        #expect(UpdateScheduler.delay(after: .failed("x"), interval: .weekly) == UpdateScheduler.failureRetryDelay)
        #expect(UpdateScheduler.delay(after: .failed("x"), interval: .hourly) == UpdateScheduler.failureRetryDelay)
    }

    @Test("U12: /api/update reports what the app knows, without checking")
    func webPayloadReflectsStatus() async {
        let engine = FakeEngine()
        engine.fallback = .updateAvailable(version: "4.0", link: nil)
        await withService(enabled: true, engine: engine) { service, engine, _, _ in
            let web = WebControlService(host: AudioHost())

            // No source wired: reported as disabled.
            let none = web.updatePayload()
            #expect(none["enabled"] as? Bool == false)
            #expect(none["available"] as? Bool == false)

            web.updateSource = service
            service.start()
            await settle { service.status.isUpdateAvailable }
            let payload = web.updatePayload()
            #expect(payload["enabled"] as? Bool == true)
            #expect(payload["available"] as? Bool == true)
            #expect(payload["version"] as? String == "4.0")
            #expect(payload["releasesURL"] as? String == UpdateLinks.releasesPage.absoluteString)
            #expect(payload["channel"] as? String == "release")
            #expect(payload["releaseNotesURL"] as? String == UpdateLinks.releasesPage.absoluteString)
        }
    }

    // MARK: - Channels (U18–U22)

    @Test("U18: the channel defaults to release; unknown stored values fall back to it")
    func channelDefaultsToRelease() {
        let name = "DeFeedbackHostTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(UpdatePreferences(from: defaults).channel == .release)
        defaults.set("nightly", forKey: UpdatePreferences.Key.channel)
        #expect(UpdatePreferences(from: defaults).channel == .nightly)
        defaults.set("NIGHTLY!!", forKey: UpdatePreferences.Key.channel)
        #expect(UpdatePreferences(from: defaults).channel == .release)
        defaults.set(42, forKey: UpdatePreferences.Key.channel)
        #expect(UpdatePreferences(from: defaults).channel == .release)
        #expect(UpdateChannel(stored: nil) == .release)
    }

    @Test("U19: channels are cumulative; release sees only untagged items")
    func channelsAreCumulative() {
        #expect(UpdateChannel.release.sparkleChannels == [])
        #expect(UpdateChannel.prerelease.sparkleChannels == ["prerelease"])
        #expect(UpdateChannel.nightly.sparkleChannels == ["prerelease", "nightly"])
        for channel in UpdateChannel.allCases {
            #expect(!channel.label.isEmpty && !channel.summary.isEmpty)
        }
    }

    @Test("U20: probes and manual checks use the chosen channel")
    func engineIsToldTheChannel() async {
        await withService(enabled: true) { service, engine, _, defaults in
            service.channel = .prerelease
            #expect(defaults.string(forKey: UpdatePreferences.Key.channel) == "prerelease")
            service.start()
            await settle { engine.probeCount >= 1 }
            #expect(engine.probeChannels.last == .prerelease)
            service.checkForUpdates()
            #expect(engine.presentChannels == [.prerelease])
        }
    }

    @Test("U20: switching channel clears the known update and probes at once")
    func switchingChannelReprobes() async {
        let engine = FakeEngine()
        engine.results = [
            .updateAvailable(version: "1.0.1-20261125030000.ab12cd3",
                             link: URL(string: "https://example.com/n")),
            .upToDate,
        ]
        await withService(enabled: true, engine: engine, clock: FakeClock(budget: 0)) { service, engine, _, _ in
            service.channel = .nightly
            service.start()
            await settle { service.status.isUpdateAvailable }
            #expect(service.status.availableLink?.absoluteString == "https://example.com/n")

            service.channel = .release
            #expect(service.status.availableVersion == nil)
            #expect(service.status.availableLink == nil)
            #expect(service.status.channel == .release)
            await settle { engine.probeCount >= 2 }
            #expect(engine.probeChannels.last == .release)
        }
    }

    @Test("U21: switching channel with checking off makes no probe")
    func switchingChannelWhenOffDoesNotProbe() async {
        await withService { service, engine, _, defaults in
            service.start()
            service.channel = .nightly
            for _ in 0..<20 { await Task.yield() }
            #expect(engine.probeCount == 0)
            #expect(defaults.string(forKey: UpdatePreferences.Key.channel) == "nightly")
        }
    }

    @Test("U22: release notes link to the found release, else the releases page")
    func releaseNotesLinkFallsBack() async {
        var status = UpdateStatus()
        #expect(status.releaseNotesURL == UpdateLinks.releasesPage)
        status.availableLink = URL(string: "https://example.com/releases/tag/v2")
        #expect(status.releaseNotesURL.absoluteString == "https://example.com/releases/tag/v2")

        let engine = FakeEngine()
        engine.fallback = .updateAvailable(version: "2.0", link: URL(string: "https://example.com/r"))
        await withService(enabled: true, engine: engine) { service, _, _, _ in
            let web = WebControlService(host: AudioHost())
            web.updateSource = service
            service.start()
            await settle { service.status.isUpdateAvailable }
            let payload = web.updatePayload()
            #expect(payload["releaseNotesURL"] as? String == "https://example.com/r")
            #expect(payload["releasesURL"] as? String == UpdateLinks.releasesPage.absoluteString)
        }
    }

    @Test("U14: Sparkle is configured never to act on its own")
    func sparkleNeverActsOnItsOwn() throws {
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["SUEnableAutomaticChecks"] as? Bool == false)
        #expect(info["SUAutomaticallyUpdate"] as? Bool == false)
        let feed = try #require(info["SUFeedURL"] as? String)
        #expect(feed.hasPrefix("https://"))
    }

    @Test("U15: the inert engine never reaches Sparkle")
    func inertEngineNeverCallsSparkle() async {
        var result: ProbeResult?
        InertUpdateEngine().probe(channel: .release) { result = $0 }
        if case .failed = result {} else { Issue.record("expected .failed, got \(String(describing: result))") }
    }

    #if DEBUG
    @Test("U16: the simulated engine reports the configured version without any network")
    func simulatedEngineReportsVersion() async {
        let name = "DeFeedbackHostTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(SimulatedUpdateEngine.fromDefaults(defaults) == nil)
        defaults.set("   ", forKey: SimulatedUpdateEngine.defaultsKey)
        #expect(SimulatedUpdateEngine.fromDefaults(defaults) == nil)
        defaults.set("9.9.9", forKey: SimulatedUpdateEngine.defaultsKey)
        let engine = try? #require(SimulatedUpdateEngine.fromDefaults(defaults))

        var result: ProbeResult?
        engine?.probe(channel: .release) { result = $0 }
        #expect(result == .updateAvailable(version: "9.9.9", link: nil))
    }
    #endif

    @Test("U16: simulation code is compiled out of release builds")
    func simulationIsDebugOnly() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func text(_ path: String) throws -> String {
            try String(contentsOf: root.appending(path: path), encoding: .utf8)
        }
        let engine = try text("DeFeedbackHost/Updates/SimulatedUpdateEngine.swift")
        #expect(engine.contains("\n#if DEBUG\n") && engine.hasSuffix("#endif\n"),
                "the whole simulated engine must sit inside #if DEBUG")

        // Every other mention of it must be inside a DEBUG block, so release builds can't link it.
        for path in ["DeFeedbackHost/AppDelegate.swift", "DeFeedbackHost/Updates/UpdateViews.swift"] {
            var depth = 0
            for line in try text(path).split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#if DEBUG") { depth += 1 }
                else if trimmed.hasPrefix("#if") { depth += 1 }
                else if trimmed.hasPrefix("#endif") { depth -= 1 }
                if trimmed.contains("SimulatedUpdateEngine"), !trimmed.hasPrefix("//") {
                    #expect(depth > 0, "\(path): \"\(trimmed)\" is outside #if DEBUG")
                }
            }
        }
    }
}
