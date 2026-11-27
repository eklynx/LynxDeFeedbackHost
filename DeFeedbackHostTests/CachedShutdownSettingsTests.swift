//
//  CachedShutdownSettingsTests.swift
//  DeFeedbackHostTests
//
//  Spec rule SH24 (docs/shutdown-spec.md): the status reads the shutdown settings through a short
//  cache, the shutdown command never does.
//
import Foundation
import Testing

@testable import DeFeedbackHost

@MainActor
private final class ReadCounter: ShutdownSettings {
    var enabled = false
    var testMode = true
    var storedPhrase = "shutdown now"
    private(set) var reads = 0
    var isEnabled: Bool { reads += 1; return enabled }
    var isTestMode: Bool { reads += 1; return testMode }
    var phrase: String { reads += 1; return storedPhrase }
}

@MainActor
struct CachedShutdownSettingsTests {

    /// A clock the test moves by hand.
    private final class Clock { var time = Date(timeIntervalSince1970: 1_000_000) }

    @Test func statusReadsAreServedFromTheCacheForAWhile() {
        let source = ReadCounter()
        let clock = Clock()
        let cached = CachedShutdownSettings(source, maxAge: 1, now: { clock.time })

        for _ in 0..<20 {
            _ = cached.isEnabled; _ = cached.isTestMode; _ = cached.phrase
            clock.time += 0.04   // 20 reads over 0.8 s, the status loop's pace
        }
        #expect(source.reads == 3, "one snapshot of three values for the whole second")
    }

    @Test func aChangeShowsUpWithinTheMaximumAge() {
        let source = ReadCounter()
        let clock = Clock()
        let cached = CachedShutdownSettings(source, maxAge: 1, now: { clock.time })
        #expect(cached.isEnabled == false)

        source.enabled = true
        source.storedPhrase = "bye"
        #expect(cached.isEnabled == false, "still the snapshot")
        clock.time += 1.0
        #expect(cached.isEnabled == true)
        #expect(cached.phrase == "bye", "the three values come from one new snapshot")
    }

    @Test func aClockThatMovesBackwardsRefreshes() {
        let source = ReadCounter()
        let clock = Clock()
        let cached = CachedShutdownSettings(source, maxAge: 1, now: { clock.time })
        _ = cached.isEnabled
        source.enabled = true
        clock.time -= 5
        #expect(cached.isEnabled == true)
    }

    @Test func theCommandIgnoresTheCacheAndReadsTheLiveSettings() async {
        let settings = ReadCounter()
        let suite = "CachedShutdownSettingsTests-\(UUID().uuidString)"
        let host = AudioHost(defaults: UserDefaults(suiteName: suite)!, pluginInstalled: true)
        let service = WebControlService(host: host)
        service.shutdownSettings = settings

        // The status snapshot caches "disabled".
        let before = service.statusPayload()["shutdown"] as? [String: Any]
        #expect(before?["enabled"] as? Bool == false)

        // Enabled a moment later: the status may lag, but the command must not.
        settings.enabled = true
        let request = HTTPRequest(method: "POST", target: "/api/shutdown", path: "/api/shutdown", query: [:],
                                  headers: { var h = HTTPHeaders(); h.append("Content-Type", "application/json"); return h }(),
                                  body: (try? JSONSerialization.data(withJSONObject: ["phrase": "wrong"])) ?? Data())
        guard case .respond(let response) = await service.routeEndpoint(request) else {
            Issue.record("no plain response")
            return
        }
        #expect(response.status == 403, "reached the phrase check, so it saw the live 'enabled' value (not 409)")
    }
}
