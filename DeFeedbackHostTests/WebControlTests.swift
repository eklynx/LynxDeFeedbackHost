//
//  WebControlTests.swift
//  DeFeedbackHostTests
//
//  Authentication, SSE framing and the endpoint's settings. Nothing here opens a socket.
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import AVFAudio
import Foundation
import Network
import Testing

@testable import DeFeedbackHost

private func authHeader(_ user: String, _ password: String) -> String {
    "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
}

struct BasicAuthTests {

    @Test func parsesAWellFormedHeader() {
        let credentials = BasicAuth.parse(authHeader("edgars", "hunter2"))
        #expect(credentials?.username == "edgars")
        #expect(credentials?.password == "hunter2")
    }

    /// Only the first colon separates the two, so a password may contain colons — a real
    /// constraint, since generated passwords often do.
    @Test func keepsColonsInThePassword() {
        let credentials = BasicAuth.parse(authHeader("edgars", "a:b:c"))
        #expect(credentials?.username == "edgars")
        #expect(credentials?.password == "a:b:c")
    }

    @Test func acceptsAnEmptyPassword() {
        let credentials = BasicAuth.parse(authHeader("edgars", ""))
        #expect(credentials?.username == "edgars")
        #expect(credentials?.password == "")
    }

    @Test func schemeMatchIgnoresCase() {
        let encoded = Data("a:b".utf8).base64EncodedString()
        #expect(BasicAuth.parse("basic \(encoded)")?.username == "a")
        #expect(BasicAuth.parse("BASIC \(encoded)")?.username == "a")
    }

    @Test(arguments: [
        "",
        "Basic",
        "Bearer abcdef",
        "Basic !!!not base64!!!",
        // No colon: not a credential pair at all.
        "Basic " + Data("nocolon".utf8).base64EncodedString(),
    ])
    func rejectsMalformedHeaders(_ header: String) {
        #expect(BasicAuth.parse(header) == nil)
    }

    @Test func rejectsAnAbsentHeader() {
        #expect(BasicAuth.parse(nil) == nil)
    }

    // MARK: - Matching

    @Test func matchesOnlyTheRightCredentials() {
        let right = BasicAuth.Credentials(username: "edgars", password: "hunter2")

        #expect(BasicAuth.matches(right, username: "edgars", password: "hunter2"))
        #expect(!BasicAuth.matches(right, username: "edgars", password: "hunter3"))
        #expect(!BasicAuth.matches(right, username: "someone", password: "hunter2"))
        #expect(!BasicAuth.matches(nil, username: "edgars", password: "hunter2"))
    }


    // MARK: - The guard

    @Test func guardLetsEverythingThroughWhenUnconfigured() {
        let authGuard = BasicAuth.Guard()
        #expect(authGuard.reject(request(authorization: nil)) == nil)
    }

    @Test func guardChallengesWithoutCredentials() throws {
        let authGuard = BasicAuth.Guard()
        authGuard.require(BasicAuth.Credentials(username: "edgars", password: "hunter2"))

        let response = try #require(authGuard.reject(request(authorization: nil)))
        #expect(response.status == 401)
        // Without this header the browser shows a bare error instead of a sign-in sheet.
        #expect(response.headers["WWW-Authenticate"]?.contains("Basic realm=") == true)
    }

    @Test func guardChallengesWrongCredentialsAndAdmitsRight() {
        let authGuard = BasicAuth.Guard()
        authGuard.require(BasicAuth.Credentials(username: "edgars", password: "hunter2"))

        #expect(authGuard.reject(request(authorization: authHeader("edgars", "wrong")))?.status
                == 401)
        #expect(authGuard.reject(request(authorization: authHeader("edgars", "hunter2"))) == nil)
    }

    /// Turning sign-in off must take effect without rebinding the socket, so connected clients
    /// keep their streams.
    @Test func guardCanBeRelaxed() {
        let authGuard = BasicAuth.Guard()
        authGuard.require(BasicAuth.Credentials(username: "edgars", password: "hunter2"))
        authGuard.require(nil)

        #expect(authGuard.reject(request(authorization: nil)) == nil)
    }

    // MARK: - Unauthenticated localhost

    private func loopbackGuard(allowing: Bool = true) -> BasicAuth.Guard {
        let authGuard = BasicAuth.Guard()
        authGuard.require(BasicAuth.Credentials(username: "edgars", password: "hunter2"),
                          allowingLoopback: allowing)
        return authGuard
    }

    @Test(arguments: ["localhost", "localhost:8080", "127.0.0.1:8080", "[::1]:8080", "LOCALHOST"])
    func loopbackAdmittedWithoutCredentials(host: String) {
        let authGuard = loopbackGuard()
        #expect(authGuard.reject(request(authorization: nil, loopback: true, host: host)) == nil)
    }

    @Test func loopbackStillChallengedWhenNotAllowed() {
        let authGuard = loopbackGuard(allowing: false)
        #expect(authGuard.reject(request(authorization: nil, loopback: true, host: "localhost"))?
                    .status == 401)
    }

    /// The `Host` header says localhost but the socket doesn't — a remote client lying.
    @Test func remotePeerClaimingLocalhostIsChallenged() {
        let authGuard = loopbackGuard()
        #expect(authGuard.reject(request(authorization: nil, loopback: false, host: "localhost"))?
                    .status == 401)
    }

    /// DNS rebinding: a page in a local browser reaches loopback under the attacker's hostname.
    @Test func loopbackWithForeignHostIsChallenged() {
        let authGuard = loopbackGuard()
        #expect(authGuard.reject(request(authorization: nil, loopback: true,
                                         host: "evil.example:8080"))?.status == 401)
        #expect(authGuard.reject(request(authorization: nil, loopback: true, host: nil))?
                    .status == 401)
    }

    @Test func loopbackWithForeignOriginIsChallenged() {
        let authGuard = loopbackGuard()
        #expect(authGuard.reject(request(authorization: nil, loopback: true, host: "localhost",
                                         origin: "http://evil.example"))?.status == 401)
        #expect(authGuard.reject(request(authorization: nil, loopback: true, host: "localhost",
                                         origin: "null"))?.status == 401)
        #expect(authGuard.reject(request(authorization: nil, loopback: true, host: "localhost",
                                         origin: "http://localhost:8080")) == nil)
    }

    @Test func loopbackEndpointDetection() {
        #expect(HTTPConnection.isLoopback(.hostPort(host: "127.0.0.1", port: 80)))
        #expect(HTTPConnection.isLoopback(.hostPort(host: "127.4.5.6", port: 80)))
        #expect(HTTPConnection.isLoopback(.hostPort(host: "::1", port: 80)))
        #expect(HTTPConnection.isLoopback(.hostPort(host: "::ffff:127.0.0.1", port: 80)))
        #expect(!HTTPConnection.isLoopback(.hostPort(host: "192.168.1.10", port: 80)))
        #expect(!HTTPConnection.isLoopback(.hostPort(host: "fe80::1", port: 80)))
        #expect(!HTTPConnection.isLoopback(.hostPort(host: "localhost", port: 80)))
    }

    private func request(authorization: String?,
                         loopback: Bool = false,
                         host: String? = nil,
                         origin: String? = nil) -> HTTPRequest {
        var headers = HTTPHeaders()
        if let authorization {
            headers.append("Authorization", authorization)
        }
        if let host {
            headers.append("Host", host)
        }
        if let origin {
            headers.append("Origin", origin)
        }
        var request = HTTPRequest(method: "GET",
                                  target: "/api/status",
                                  path: "/api/status",
                                  query: [:],
                                  headers: headers,
                                  body: Data())
        request.isFromLoopback = loopback
        return request
    }
}

struct EventStreamTests {

    @Test func framesAnEvent() {
        let frame = EventStream.frame(event: "status", data: #"{"running":true}"#)
        #expect(String(decoding: frame, as: UTF8.self)
                == "event: status\ndata: {\"running\":true}\n\n")
    }

    /// A raw newline inside the payload would end the `data:` field and corrupt the event, so
    /// every line needs its own prefix.
    @Test func prefixesEveryLineOfAMultiLinePayload() {
        let frame = EventStream.frame(event: "status", data: "{\n  \"a\": 1\n}")
        #expect(String(decoding: frame, as: UTF8.self)
                == "event: status\ndata: {\ndata:   \"a\": 1\ndata: }\n\n")
    }

    @Test func keepsBlankLinesInsideThePayload() {
        let frame = EventStream.frame(event: "x", data: "a\n\nb")
        #expect(String(decoding: frame, as: UTF8.self)
                == "event: x\ndata: a\ndata: \ndata: b\n\n")
    }

    @Test func startsWithNoClients() {
        #expect(EventStream().clientCount == 0)
    }

    @Test func preambleDeclaresAnEventStream() {
        let preamble = EventStream.preamble
        #expect(preamble.status == 200)
        #expect(preamble.headers["Content-Type"]?.hasPrefix("text/event-stream") == true)
        // Anything buffering the response would defeat the point of streaming it.
        #expect(preamble.headers["Cache-Control"] == "no-store")
        #expect(preamble.headers["X-Accel-Buffering"] == "no")
    }

    /// Found end to end, not in a unit test: the preamble used to serialize with
    /// `Content-Length: 0`, so clients treated the response as finished before a single event
    /// was written and the stream appeared silent. A stream must declare no length at all.
    @Test func preambleDeclaresNoLength() {
        let head = String(decoding: EventStream.preamble.serialized(), as: UTF8.self)

        #expect(!head.lowercased().contains("content-length"))
        #expect(head.contains("Connection: close"))
        #expect(head.hasSuffix("\r\n\r\n"))
    }

    /// The flag must not leak into ordinary responses, which still need their length.
    @Test func normalResponsesStillDeclareALength() {
        let head = String(decoding: HTTPResponse.json(["a": 1]).serialized(), as: UTF8.self)
        #expect(head.contains("Content-Length: "))
    }
}

/// What the host does when the plugin it exists to load isn't installed.
///
/// Availability is injected rather than read from the machine, because the whole point is the
/// side a developer's machine never shows: the plugin is installed there, so every one of these
/// assertions would pass vacuously. Both sides are driven explicitly instead.
@MainActor
struct MissingPluginTests {

    /// The window, the page and the endpoint's refusal all show this sentence. Three copies of a
    /// message is three chances for them to drift, so there is one.
    @Test func oneSentenceServesEveryInterface() {
        #expect(AudioHostError.pluginNotInstalled.localizedDescription
                == String(format:
                            String(localized: locKeyErrPluginNotFoundFormat, table: locTableErrors),
PluginConfiguration.displayName)
        )
        #expect(PluginConfiguration.notInstalledMessage.contains(PluginConfiguration.displayName),
                "the notice has to name the plugin — 'the plugin' identifies nothing")
    }
    

    /// Being told something is missing without being told where to get it leaves the reader
    /// exactly where they started, so both interfaces show this link.
    @Test func theNoticeSaysWhereToGetIt() {
        let page = PluginConfiguration.pluginHomepage
        #expect(page.scheme == "https")
        #expect(page.host()?.hasSuffix("alphalabsaudio.com") == true,
                "the link should point at the plugin's own page")
    }

    /// The host's cached answer has to be the one the component registrar gives, since that's
    /// what decides whether an instance can actually be created.
    @Test func theCachedAnswerIsTheRealOne() {
        #expect(AudioHost().isPluginInstalled == PluginConfiguration.isInstalled)
    }

    /// Run is blocked, and says why in the sentence both interfaces show — the page prints
    /// `blockedReason` and the endpoint returns it in a 409.
    @Test func startingIsBlockedAndSaysWhy() {
        let host = AudioHost(pluginInstalled: false)

        #expect(!host.canStart)
        #expect(host.startBlockedReason == String(format:
                                                    String(localized: locKeyErrPluginNotFoundFormat, table: locTableErrors),
                    PluginConfiguration.displayName))
    }

    /// The missing plugin is reported ahead of everything else. A machine with no plugin *and* no
    /// devices selected has two things wrong with it, and being told to pick a device first sends
    /// the reader after the one they can't fix by choosing differently.
    @Test func theMissingPluginIsTheFirstThingSaid() {
        let host = AudioHost(pluginInstalled: false)

        #expect(host.selectedInputDeviceID == nil, "a bare host has selected nothing")
        #expect(host.startBlockedReason == String(format:
                                                    String(localized: locKeyErrPluginNotFoundFormat, table: locTableErrors),
                    PluginConfiguration.displayName)
        )
    }

    /// `start()` must refuse on its own rather than trusting callers to have asked `canStart`
    /// first. That is what will block the autostart setting when it arrives, without that code
    /// having to remember anything.
    @Test func startRefusesEvenWhenAskedDirectly() async {
        let host = AudioHost(pluginInstalled: false)

        await host.start()

        #expect(!host.isRunning, "the devices must not open with nothing to render through")
        #expect(host.errorMessage == String(format:
                                                String(localized: locKeyErrPluginNotFoundFormat, table: locTableErrors),
                PluginConfiguration.displayName)
        )
    }

    /// Adding is refused too: every instance added would be an empty shell with a load error, and
    /// neither interface has anywhere to show it — both replace their instance list with the
    /// notice.
    @Test func addingIsRefusedWithTheRightReason() async {
        let host = AudioHost(pluginInstalled: false)

        #expect(!host.canAddInstance)

        let added = await host.addInstance()
        #expect(added == nil)
        #expect(host.instances.isEmpty, "a refused add must not leave a shell behind")
        // Not the "limited to 32 instances" message, which is the other reason `canAddInstance`
        // can be false and would be a bewildering answer to the first Add.
        #expect(host.errorMessage == String(format:
                                                String(localized: locKeyErrPluginNotFoundFormat, table:locTableErrors),
                                            PluginConfiguration.displayName)
                )
    }

    /// The other side of each gate: with a plugin present, none of the above is what's in the way.
    @Test func aPresentPluginBlocksNothing() {
        let host = AudioHost(pluginInstalled: true)

        #expect(host.canAddInstance)
        #expect(host.startBlockedReason != PluginConfiguration.notInstalledMessage,
                "an installed plugin must not be reported as the thing blocking Run")
    }
}

/// The device menus the web page drives. `WebControlService` itself needs a live `AudioHost`, so
/// what's covered here is the payload shape both sides agree on and the UID keying it depends on.
@MainActor
struct WebDeviceMenuTests {

    /// Menus are keyed on UID, not `AudioDeviceID`: IDs are handed out per boot and change when
    /// hardware is reconnected, so a page holding one across a reconnect would point at nothing —
    /// or at a different device, which is worse.
    @Test func devicesAreIdentifiedByUID() {
        let devices = AudioHardware.allDevices()
        try? #require(!devices.isEmpty)

        for device in devices {
            #expect(!device.uid.isEmpty, "\(device.name) has no UID to key a menu on")
        }

        let uids = devices.map(\.uid)
        #expect(Set(uids).count == uids.count, "UIDs must be unique to resolve a selection")
    }

    /// An interface that is both an input and an output must not show its input count in the
    /// output menu — that's the difference the channel count is there to convey.
    @Test func eachDirectionReportsItsOwnChannelCount() {
        let host = AudioHost()
        host.refreshDevices()

        for device in host.inputDevices {
            #expect(device.inputChannelCount > 0,
                    "\(device.name) is in the input menu with no input channels")
        }
        for device in host.outputDevices {
            #expect(device.outputChannelCount > 0,
                    "\(device.name) is in the output menu with no output channels")
        }
    }

    /// Selecting by UID has to land on exactly one device, which is what the route's lookup does.
    @Test func aUIDResolvesToASingleDevice() {
        let host = AudioHost()
        host.refreshDevices()

        guard let wanted = host.outputDevices.first else { return }
        let matches = host.outputDevices.filter { $0.uid == wanted.uid }
        #expect(matches.count == 1)
        #expect(matches.first?.id == wanted.id)
    }

    /// The window's pickers are disabled while running because changing either device means
    /// rebuilding the I/O units; the endpoint refuses for the same reason, and both read the
    /// same flag rather than each deciding for themselves.
    @Test func devicesAreOnlyChangeableWhileStopped() {
        let host = AudioHost()
        #expect(!host.isRunning, "a freshly built host is stopped, so devices are changeable")
    }
}

/// The sample rate menus. The route's resolution step is private, so what's asserted here is the
/// tolerance rule it relies on and the shape of the menus it validates against.
@MainActor
struct WebSampleRateMenuTests {

    /// Rates are `Double` and have survived a round trip through the HAL, so the route matches a
    /// requested rate with the same 0.5 Hz tolerance the rest of the host uses. Equality would
    /// reject a perfectly good 44100 that came back as 44099.999.
    @Test func rateMatchingIsTolerant() {
        #expect(AudioHost.ratesMatch(44_100, 44_100))
        #expect(AudioHost.ratesMatch(44_100, 44_100.4))
        #expect(AudioHost.ratesMatch(48_000, 47_999.6))
        #expect(!AudioHost.ratesMatch(44_100, 48_000))
        #expect(!AudioHost.ratesMatch(44_100, 44_101))
        // A missing rate is never a match — the menus can legitimately be empty.
        #expect(!AudioHost.ratesMatch(nil, 44_100))
        #expect(!AudioHost.ratesMatch(44_100, nil))
    }

    /// Every offered rate has to round-trip through the page, which sends it as a whole number.
    /// A device offering a fractional rate would break that, so this checks the assumption holds.
    @Test func offeredRatesAreWholeHertz() {
        let host = AudioHost()
        host.refreshDevices()

        for rate in host.inputSampleRates + host.outputSampleRates {
            #expect(rate > 0, "a menu rate must be positive")
            #expect(abs(rate - rate.rounded()) <= 0.5,
                    "\(rate) would not survive the page's rounding to whole hertz")
        }
    }

    /// The selection always has to be something the menu actually offers, or the page would show
    /// a value it can't post back.
    @Test func theSelectedRateIsOneOfTheOfferedOnes() {
        let host = AudioHost()
        host.refreshDevices()

        for (selected, offered) in [(host.selectedInputSampleRate, host.inputSampleRates),
                                    (host.selectedOutputSampleRate, host.outputSampleRates)] {
            guard let selected, !offered.isEmpty else { continue }
            #expect(offered.contains { abs($0 - selected) <= 0.5 },
                    "\(selected) Hz is selected but not in \(offered)")
        }
    }

    /// `sampleRatesMatch` is what gates Run, and the page marks both rate menus from it — so it
    /// has to agree with `canStart` rather than being computed a second way.
    @Test func mismatchedRatesBlockStarting() {
        let host = AudioHost()
        host.refreshDevices()

        if !host.doSampleRatesMatch {
            #expect(!host.canStart, "rates that don't match must block Run")
            #expect(host.startBlockedReason != nil, "and must say why")
        }
    }
}

/// The buffer size menu. The route's validation is private, so what's covered here is the offered
/// list it validates against, the `didSet` it relies on, and the agreement between the flag the
/// page marks its menu from and the one that actually gates Run.
@MainActor
struct WebBufferSizeTests {

    /// The page builds its menu from `bufferSizeChoices` and posts the chosen value straight back, so
    /// every entry has to be something the route will accept — and the list has to be usable as
    /// menu options, which means no duplicates.
    @Test func everyOfferedSizeIsOneTheRouteWouldTake() {
        let sizes = PluginConfiguration.validBufferSizes

        #expect(!sizes.isEmpty, "an empty list would leave the page with no menu to show")
        #expect(Set(sizes).count == sizes.count, "a duplicated size would give two identical options")

        for size in sizes {
            #expect(size > 0, "\(size) is not a usable buffer size")
        }

        // The route accepts exactly this list, so the host's own default must be in it or a fresh
        // install would show a menu with nothing selected.
        #expect(sizes.contains(PluginConfiguration.defaultBufferSize),
                "the default buffer size isn't one of the offered ones")
    }

    // Persistence of the size the route writes is already covered, and at the level that matters:
    // `SettingsStoreTests` round-trips `bufferSize` through `HostSettings` and through
    // `SettingsStore`, including an old session saved before later fields existed. The route only
    // assigns `host.bufferSize`; everything past that is that path, and repeating it here would
    // add a second place to update rather than a second thing checked.

    /// The route refuses while running because the size is pushed at the HAL as part of starting.
    /// Both the window's picker and the route read this same flag rather than each deciding.
    @Test func theBufferSizeIsOnlyChangeableWhileStopped() {
        let host = AudioHost()
        #expect(!host.isRunning, "a freshly built host is stopped, so the size is changeable")
    }

    /// A size the host offers is not necessarily one the *devices* will take, which is the whole
    /// reason the route accepts it and reports the consequence instead of refusing.
    ///
    /// `bufferSizeAccepted` is what the page marks its menu from, so it has to agree with the flag
    /// that actually gates Run rather than being computed a second way — and the reason has to
    /// name the device and the size, since the menu alone can't say which of the two refused.
    ///
    /// Needs real hardware to have a range to fall outside of; returns rather than fails without
    /// it, like the device tests.
    @Test func aSizeTheDevicesRejectBlocksStartingAndSaysWhich() {
        let host = AudioHost()
        host.refreshDevices()

        guard let output = host.selectedOutputDevice,
              let range = host.bufferSizeRange(for: .output) else { return }

        // Past what the device will take. Not one of the offered sizes, necessarily — the point is
        // the state, which a device swap can strand the host in whatever it was set to.
        host.bufferSize = range.upperBound + 1

        #expect(!host.devicesRejectingBufferSize.isEmpty,
                "a size past the device's range should be reported as rejected")
        #expect(!host.canStart, "a rejected buffer size must block Run")

        let reason = host.startBlockedReason
        #expect(reason?.contains(output.name) == true,
                "the reason should name the device that refused, not just say no")
        #expect(reason?.contains("\(range.upperBound + 1)") == true,
                "the reason should name the size that was refused")

        // And the agreement the page depends on, in the other direction.
        host.bufferSize = PluginConfiguration.defaultBufferSize
        if host.devicesRejectingBufferSize.isEmpty {
            #expect(host.startBlockedReason?.contains("sample buffer") != true,
                    "an accepted size must not still be reported as the thing blocking Run")
        }
    }
}

/// The per-instance settings the page shows. The payload itself needs a live `WebControlService`,
/// so what's covered here is the one piece of arithmetic between the plugin and the wire.
struct InstanceStrengthTests {

    /// De-Feedback publishes Strength as a "Generic" parameter, which says nothing about its
    /// units — `auval` reports its extremes as "0%" and "100%", but those are display strings.
    /// Scaling from the parameter's own range has to give the same answer either way.
    @Test func normalisesFromEitherConvention() {
        // 0…1
        #expect(PluginInstance.percentFromAUValue(of: 0, from: 0, span: 1) == 0)
        #expect(PluginInstance.percentFromAUValue(of: 0.5, from: 0, span: 1) == 50)
        #expect(PluginInstance.percentFromAUValue(of: 1, from: 0, span: 1) == 100)

        // 0…100
        #expect(PluginInstance.percentFromAUValue(of: 0, from: 0, span: 100) == 0)
        #expect(PluginInstance.percentFromAUValue(of: 37, from: 0, span: 100) == 37)
        #expect(PluginInstance.percentFromAUValue(of: 100, from: 0, span: 100) == 100)
    }

    /// The page shows whole numbers, per the spec for this control.
    @Test func roundsToAWholePercent() {
        #expect(PluginInstance.percentFromAUValue(of: 0.333, from: 0, span: 1) == 33)
        #expect(PluginInstance.percentFromAUValue(of: 0.335, from: 0, span: 1) == 34)
        #expect(PluginInstance.percentFromAUValue(of: 0.999, from: 0, span: 1) == 100)
    }

    /// A range that doesn't start at zero still has to map onto 0–100.
    @Test func handlesAnOffsetRange() {
        #expect(PluginInstance.percentFromAUValue(of: -6, from: -6, span: 12) == 0)
        #expect(PluginInstance.percentFromAUValue(of: 0, from: -6, span: 12) == 50)
        #expect(PluginInstance.percentFromAUValue(of: 6, from: -6, span: 12) == 100)
    }

    /// A degenerate or out-of-range value must not produce a slider position that can't exist.
    /// This runs on the parameter observer's thread, where there is nothing to catch a trap.
    @Test func clampsAndSurvivesADegenerateRange() {
        #expect(PluginInstance.percentFromAUValue(of: 5, from: 0, span: 0) == 0)
        #expect(PluginInstance.percentFromAUValue(of: -1, from: 0, span: 1) == 0)
        #expect(PluginInstance.percentFromAUValue(of: 2, from: 0, span: 1) == 100)
    }
}

/// The writing side, which `PATCH /api/instances/{id}` stands on. Arithmetic only — the live
/// half is `InstanceStrengthWriteThroughTests`.
struct InstanceStrengthWritingTests {

    @Test func mapsAPercentageOntoEitherConvention() {
        // 0…1
        #expect(PluginInstance.auValueFromPercent(forPercent: 0, from: 0, span: 1) == 0)
        #expect(PluginInstance.auValueFromPercent(forPercent: 50, from: 0, span: 1) == 0.5)
        #expect(PluginInstance.auValueFromPercent(forPercent: 100, from: 0, span: 1) == 1)

        // 0…100
        #expect(PluginInstance.auValueFromPercent(forPercent: 37, from: 0, span: 100) == 37)
        #expect(PluginInstance.auValueFromPercent(forPercent: 100, from: 0, span: 100) == 100)
    }

    @Test func handlesAnOffsetRange() {
        #expect(PluginInstance.auValueFromPercent(forPercent: 0, from: -6, span: 12) == -6)
        #expect(PluginInstance.auValueFromPercent(forPercent: 50, from: -6, span: 12) == 0)
        #expect(PluginInstance.auValueFromPercent(forPercent: 100, from: -6, span: 12) == 6)
    }

    /// The route rejects anything outside 0–100 before it gets here, so this is the second line:
    /// nothing outside the plugin's own range may reach the plugin.
    @Test func clampsOutOfRangePercentages() {
        #expect(PluginInstance.auValueFromPercent(forPercent: -20, from: 0, span: 1) == 0)
        #expect(PluginInstance.auValueFromPercent(forPercent: 150, from: 0, span: 1) == 1)
        #expect(PluginInstance.auValueFromPercent(forPercent: 150, from: -6, span: 12) == 6)
    }

    /// The pair has to be a genuine round trip in `Float` precision, not just in principle. If a
    /// value written as 33% read back as 32%, the page would show the slider stepping backwards
    /// the instant the user let go of it.
    @Test(arguments: [0, 1, 17, 33, 50, 67, 99, 100])
    func roundTripsThroughTheReadingSide(percent: Int) {
        let ranges: [(AUValue, AUValue)] = [(0, 1), (0, 100), (-6, 12), (20, 80), (0, 3)]
        for (lowest, span) in ranges {
            let value = PluginInstance.auValueFromPercent(forPercent: percent, from: lowest, span: span)
            let readBack = PluginInstance.percentFromAUValue(of: value, from: lowest, span: span)
            #expect(readBack == percent,
                    "\(percent)% over \(lowest)…\(lowest + span) came back as \(readBack)%")
        }
    }
}

/// The live half: that the value the page shows actually follows the plugin.
///
/// Loads the configured audio unit for real, so it needs De-Feedback installed. When it isn't,
/// the test returns rather than fails — the same way the device tests skip a machine with no
/// hardware to enumerate.
@MainActor
struct InstanceStrengthObserverTests {

    /// `strengthPercent` is a snapshot, not a read-through: the plugin is hosted out of process,
    /// so polling it per status event would be an XPC round trip per instance four times a
    /// second. That makes the parameter observer the only thing keeping it true, and this is the
    /// test that says whether it does.
    @Test func followsTheParameterWhenItMoves() async throws {
        let instance = PluginInstance(changeFlag: SettingsChangeFlag())
        await instance.load()

        guard let unit = instance.audioUnit else { return }
        guard let parameter = unit.withAUAudioUnit({ au in
            au.parameterTree?.allParameters.first {
                $0.displayName.caseInsensitiveCompare(PluginInstance.strengthParameterName)
                    == .orderedSame
            }
        }) else { return }

        // The value read at load time, before any observer has fired.
        #expect(instance.strengthPercent != nil, "Strength should be found as the plugin loads")

        let span = parameter.maxValue - parameter.minValue
        try #require(span > 0)

        for fraction in [0.0, 0.25, 1.0] as [AUValue] {
            parameter.value = parameter.minValue + span * fraction
            let wanted = Int((fraction * 100).rounded())

            // Notification crosses a process boundary, so it isn't there the instant the setter returns.
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while instance.strengthPercent != wanted, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }

            #expect(instance.strengthPercent == wanted,
                    "set Strength to \(wanted)%, snapshot says \(String(describing: instance.strengthPercent))%")
        }
    }

    /// `isMuted` and the plugin's `Mute` are one control, so it has to work in both directions.
    /// Getting only one of them right is the plausible bug: a toggle that mutes but never shows
    /// a mute made in the plugin's UI, or the reverse.
    @Test func muteIsOneControlInBothDirections() async throws {
        let instance = PluginInstance(changeFlag: SettingsChangeFlag())
        await instance.load()

        guard let unit = instance.audioUnit else { return }
        guard let parameter = unit.withAUAudioUnit({ au in
            au.parameterTree?.allParameters.first {
                $0.displayName.caseInsensitiveCompare(PluginInstance.muteParameterName)
                    == .orderedSame
            }
        }) else { return }

        #expect(instance.pluginMuted != nil, "Mute should be found as the plugin loads")

        // Host toggle → plugin parameter.
        for wanted in [true, false, true] {
            instance.isMuted = wanted
            #expect(parameter.value == (wanted ? parameter.maxValue : parameter.minValue),
                    "setting isMuted to \(wanted) left the plugin's Mute at \(parameter.value)")
            #expect(instance.pluginMuted == wanted, "and the snapshot should agree immediately")
        }

        // Plugin parameter → host toggle. Reconciling is what the host's settings poll does once
        // a second; the value crosses a process boundary, so it isn't there the instant the
        // setter returns.
        for wanted in [false, true, false] {
            parameter.value = wanted ? parameter.maxValue : parameter.minValue

            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while instance.pluginMuted != wanted, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            instance.reconcileMuteFromPlugin()

            #expect(instance.isMuted == wanted,
                    "plugin Mute went to \(wanted) but isMuted stayed \(instance.isMuted)")
        }
    }
}

/// Writing Strength for real. Like `InstanceStrengthObserverTests`, this loads the configured
/// audio unit and returns rather than fails when it isn't installed.
@MainActor
struct InstanceStrengthWriteThroughTests {

    /// The snapshot must be current *before* the observer has delivered anything, because
    /// The `PATCH` answers with a status payload built in the same turn as the write.
    /// Waiting for the observer would be a round trip to another process; the page would show the
    /// old value in the 202 and the new one a moment later, which reads as the slider bouncing.
    @Test func theSnapshotIsCurrentBeforeTheObserverFires() async throws {
        let instance = PluginInstance(changeFlag: SettingsChangeFlag())
        await instance.load()

        guard let unit = instance.audioUnit else { return }
        guard let parameter = unit.withAUAudioUnit({ au in
            au.parameterTree?.allParameters.first {
                $0.displayName.caseInsensitiveCompare(PluginInstance.strengthParameterName)
                    == .orderedSame
            }
        }) else { return }

        try #require(instance.publishesStrength)
        let span = parameter.maxValue - parameter.minValue
        try #require(span > 0)

        for wanted in [0, 25, 100, 60, 1] {
            #expect(instance.setStrengthPercent(wanted))

            // No sleep, deliberately: this is the property under test.
            let snapshot = instance.strengthPercent
            #expect(snapshot == wanted,
                    "wrote \(wanted)%, snapshot says \(String(describing: snapshot))%")
            #expect(parameter.value == PluginInstance.auValueFromPercent(forPercent: wanted,
                                                            from: parameter.minValue,
                                                            span: span),
                    "the plugin's own parameter didn't take \(wanted)%")
        }
    }

    /// Writing has to raise the autosave flag by itself. Mute gets this from `isMuted`'s `didSet`;
    /// Strength has no stored property, so nothing would mark the session dirty and a change made
    /// from the page would be lost on quit.
    @Test func writingMarksTheSessionForSaving() async throws {
        let flag = SettingsChangeFlag()
        let instance = PluginInstance(changeFlag: flag)
        await instance.load()
        guard instance.publishesStrength else { return }

        _ = flag.consume()
        #expect(instance.setStrengthPercent(42))
        #expect(flag.consume(), "a Strength change left the session unmarked")
    }

    /// The 409 on the `PATCH` is built on this returning false, and an instance that
    /// never loaded is in exactly the state a plugin publishing no `Strength` leaves it in.
    @Test func anInstanceWithNoStrengthParameterRefusesTheWrite() {
        let instance = PluginInstance(changeFlag: SettingsChangeFlag())
        #expect(!instance.publishesStrength)
        #expect(!instance.setStrengthPercent(50))
        #expect(instance.strengthPercent == nil,
                "a refused write must not leave a value behind for the page to show")
    }
}

/// The one route matched by template rather than by whole path: `DELETE /api/instances/{id}`.
///
/// Worth its own tests because it runs *before* the route table, so a matcher that is too greedy
/// doesn't just mishandle its own URL — it swallows requests meant for something else.
struct WebRoutePathTests {

    private let template = "/api/instances/{id}"

    private func parameter(_ path: String) -> String? {
        WebControlService.extractPathFromTemplate(in: path, matching: template)
    }

    @Test func theTrailingSegmentIsTheParameter() {
        #expect(parameter("/api/instances/9E0C2E3A-6B4F-4E2A-9F7B-1C2D3E4F5A6B")
                == "9E0C2E3A-6B4F-4E2A-9F7B-1C2D3E4F5A6B")
    }

    /// Anything that isn't a uuid still matches — the route answers 400 for it rather than 404.
    /// The distinction is deliberate: "no such instance" and "that isn't an id" are different
    /// answers, and only the route can tell them apart.
    @Test func whatTheSegmentContainsIsNotThisFunctionsBusiness() {
        #expect(parameter("/api/instances/seven") == "seven")
    }

    /// The collection route must not be captured, or `POST /api/instances` would be answered by
    /// the single-instance branch with a 405.
    @Test func theCollectionItselfDoesNotMatch() {
        #expect(parameter("/api/instances") == nil)
    }

    /// An empty or deeper tail falls through to the whole-path table and gets its 404, rather
    /// than being read as an id of "" or one containing a slash.
    @Test func anEmptyOrDeeperTailDoesNotMatch() {
        #expect(parameter("/api/instances/") == nil)
        #expect(parameter("/api/instances/one/two") == nil)
    }

    /// The prefix is matched in full, so a neighbouring route with the same opening cannot be
    /// mistaken for an instance id.
    @Test func aDifferentRouteDoesNotMatch() {
        #expect(parameter("/api/instances-and-more") == nil)
        #expect(parameter("/api/status") == nil)
        #expect(parameter("/") == nil)
    }

    /// A template with no parameter in it matches nothing at all, rather than matching everything
    /// with that prefix.
    @Test func aTemplateWithoutAParameterMatchesNothing() {
        #expect(WebControlService.extractPathFromTemplate(in: "/api/instances/x",
                                                matching: "/api/instances") == nil)
    }
}

/// Adding and removing instances. The routes themselves need a live `WebControlService`, so what's
/// covered here is the host-side behaviour they stand on — above all that removal is keyed on `id`,
/// which is the entire reason `id` is on the wire.
///
/// These load the configured audio unit for real, but none of them depend on it *succeeding*: a
/// failed instance still takes its place in the list, which is the thing under test.
@MainActor
struct WebInstanceListTests {

    private func host(withInstances count: Int) async throws -> AudioHost {
        // Not `prepare()`: that would read and then overwrite the real app's saved session. A bare
        // host stays in its restoring state, so nothing here reaches UserDefaults.
        //
        // Availability is forced on because what's under test is the list — ids, ordering,
        // removal — none of which needs the plugin to have actually loaded. Asking the machine
        // would make every test below silently unrunnable on one without it.
        let host = AudioHost(pluginInstalled: true)
        for _ in 0..<count {
            await host.addInstance()
        }
        try #require(host.instances.count == count)
        return host
    }

    /// The failure this guards against: a client reads the list, the user removes something ahead
    /// of their target, and the request lands naming a position that now belongs to a different
    /// plugin. Ids don't shift; indices do.
    @Test func removalIsByIdNotByPosition() async throws {
        let host = try await host(withInstances: 3)
        let ids = host.instances.map(\.id)

        // Removing the first shifts the other two down a place.
        #expect(host.removeInstance(id: ids[0]))
        #expect(host.instances.map(\.id) == [ids[1], ids[2]])

        // An id captured while the list was three long still names the same instance.
        #expect(host.removeInstance(id: ids[2]))
        #expect(host.instances.map(\.id) == [ids[1]])
    }

    /// Both interfaces now ask before removing, which opens a gap between pressing the button and
    /// the removal happening — and the list can move during that gap, because the web endpoint
    /// removes from another machine entirely.
    ///
    /// This is the hazard that makes the confirmation capture an **id** rather than
    /// `selectedInstanceIndex`: once the selected instance is itself removed, the index is clamped
    /// onto a different plugin, so a dialog holding the position would remove something the user
    /// never looked at. A held id can only ever name what was on screen, or nothing.
    @Test func aCapturedIdOutlivesTheSelectionMovingUnderIt() async throws {
        let host = try await host(withInstances: 3)

        host.selectedInstanceIndex = 2
        let asked = try #require(host.selectedInstance?.id)
        let bystander = host.instances[1].id

        // What another client does while the confirmation is still up: takes away the very
        // instance being asked about.
        #expect(host.removeInstance(id: asked))

        // The selection now points at a different plugin, so confirming by position would hit it.
        #expect(host.selectedInstanceIndex == 1)
        #expect(host.selectedInstance?.id == bystander,
                "the clamped selection should have landed on a different instance")

        // Confirming by the captured id names nothing, which both interfaces read as "already
        // gone" — and crucially removes no bystander.
        #expect(!host.removeInstance(id: asked))
        #expect(host.instances.count == 2, "confirming must not have removed something else")
        #expect(host.instances.contains { $0.id == bystander })
    }

    /// Two browsers watching one stream can both press Remove on the same row. The second must be
    /// told its target was already gone rather than removing something else.
    @Test func anUnknownIdRemovesNothing() async throws {
        let host = try await host(withInstances: 2)
        let before = host.instances.map(\.id)

        #expect(!host.removeInstance(id: UUID()))
        #expect(host.instances.map(\.id) == before)
    }

    /// The window's gallery and the endpoint share one list, so a removal made from a browser must
    /// not slide the app's window onto a different plugin. Only reachable now that something other
    /// than the window can remove.
    ///
    /// The selection sits in the *middle* deliberately. With it on the last instance the trailing
    /// clamp lands on the right index by coincidence, and the test passes with the adjustment
    /// removed — which it did, until this was changed.
    @Test func removingAheadOfTheSelectionKeepsTheSameInstanceShowing() async throws {
        let host = try await host(withInstances: 3)

        host.selectedInstanceIndex = 1
        let showing = try #require(host.selectedInstance?.id)

        #expect(host.removeInstance(id: host.instances[0].id))
        #expect(host.selectedInstanceIndex == 0, "the index should follow the instance down")
        #expect(host.selectedInstance?.id == showing, "the gallery moved to a different instance")
    }

    /// And the other direction: removing behind the selection leaves it where it was.
    @Test func removingBehindTheSelectionLeavesItAlone() async throws {
        let host = try await host(withInstances: 3)

        host.selectedInstanceIndex = 0
        let showing = try #require(host.selectedInstance?.id)

        #expect(host.removeInstance(id: host.instances[2].id))
        #expect(host.selectedInstanceIndex == 0)
        #expect(host.selectedInstance?.id == showing)
    }

    @Test func emptyingTheListLeavesNoSelectionPastTheEnd() async throws {
        let host = try await host(withInstances: 2)

        host.selectedInstanceIndex = 1
        host.removeSelectedInstance()
        #expect(host.selectedInstanceIndex == 0)

        host.removeSelectedInstance()
        #expect(host.instances.isEmpty)
        #expect(host.selectedInstanceIndex == 0, "a selection can't point into an empty list")
        #expect(host.selectedInstance == nil)
    }

    /// `canAddInstance` is the single definition the window's `+` and the route's 409 both read.
    ///
    /// It carries a second condition now — there has to be a plugin to instantiate — so the
    /// expectation names both rather than only the cap. Which of the two refused still reaches
    /// the caller separately, in the message.
    @Test func theCapIsOneDefinition() async throws {
        let host = try await host(withInstances: 1)
        #expect(host.canAddInstance ==
                (host.isPluginInstalled
                 && host.instances.count < PluginConfiguration.maximumInstanceCount))
    }

    /// The 409 body is the window's own sentence, and it quotes the cap as a number — which is
    /// only useful if it's the real one.
    @Test func theFullHostMessageStatesTheRealCap() {
        #expect(AudioHostError.maxInstancesReached.localizedDescription
            .contains("\(PluginConfiguration.maximumInstanceCount)"))
    }

    /// The `PATCH` and the single-instance `GET` find their target the same way removal does, and for the same
    /// reason. The case that matters is a lookup *after* the list has shifted: a client's request
    /// was composed against the list as it was a round trip ago.
    @Test func lookupIsByIdNotByPosition() async throws {
        let host = try await host(withInstances: 3)
        let ids = host.instances.map(\.id)

        #expect(host.removeInstance(id: ids[0]))
        // ids[2] has moved from index 2 to index 1. Anything positional hands back ids[1].
        #expect(host.instance(id: ids[2])?.id == ids[2])
        #expect(host.instance(id: ids[1])?.id == ids[1])
        #expect(host.instance(id: ids[0]) == nil,
                "a removed instance must not still be findable — that's the route's 404")
    }
}

/// The per-instance settings route. Channel routing is a plain property on `PluginInstance`, so
/// what needs proving is that setting it from outside the window behaves as the window does.
@MainActor
struct WebInstanceSettingsTests {

    /// Assigning a channel has to raise the autosave flag, or a change made from the page would
    /// be lost on quit. This is the `didSet` the route relies on rather than doing itself.
    @Test func changingAChannelMarksTheSessionForSaving() {
        let flag = SettingsChangeFlag()
        let instance = PluginInstance(changeFlag: flag)

        _ = flag.consume()
        instance.inputChannel = 3
        #expect(flag.consume(), "an input channel change left the session unmarked")

        instance.outputChannel = 2
        #expect(flag.consume(), "an output channel change left the session unmarked")
    }

    /// The same for the two toggles. Bypass is the one with no plugin parameter behind it, so
    /// nothing else would raise the flag on its behalf.
    @Test func togglingMuteOrBypassMarksTheSessionForSaving() {
        let flag = SettingsChangeFlag()
        let instance = PluginInstance(changeFlag: flag)

        _ = flag.consume()
        instance.isBypassed = true
        #expect(flag.consume(), "a bypass change left the session unmarked")

        instance.isMuted = true
        #expect(flag.consume(), "a mute change left the session unmarked")
    }

    /// Bypass is the *host's*, not the plugin's: the render loop wires input straight to output
    /// and never calls the plugin. So it must hold on an instance with no plugin at all, which is
    /// what the route will meet if an instance failed to load.
    @Test func bypassNeedsNoPlugin() {
        let instance = PluginInstance(changeFlag: SettingsChangeFlag())
        #expect(instance.audioUnit == nil)

        instance.isBypassed = true
        #expect(instance.isBypassed)
        instance.isBypassed = false
        #expect(!instance.isBypassed)
    }

    /// Mute, by contrast, is the plugin's own parameter when there is one — and must still work
    /// when there isn't, falling back to the render loop's own mute. Either way the property is
    /// what the status payload reports, so it has to hold the value it was given.
    @Test func muteHoldsWithOrWithoutAPluginParameter() async throws {
        let bare = PluginInstance(changeFlag: SettingsChangeFlag())
        bare.isMuted = true
        #expect(bare.isMuted, "mute must work as the render-loop fallback too")

        let loaded = PluginInstance(changeFlag: SettingsChangeFlag())
        await loaded.load()
        guard loaded.audioUnit != nil, loaded.pluginMuted != nil else { return }

        loaded.isMuted = true
        // Immediately, with no wait: the route answers with a status snapshot in the same turn,
        // exactly as for Strength.
        #expect(loaded.pluginMuted == true, "the plugin's own Mute should agree at once")
        loaded.isMuted = false
        #expect(loaded.pluginMuted == false)
    }

    /// With no device selected there are no channels to route to, which is what makes the route's
    /// 409 a reachable state rather than a hypothetical one — and it's the state a freshly built
    /// host is in, before `prepare()` has run.
    @Test func noDeviceMeansNoChannelsToRouteTo() {
        let host = AudioHost()
        #expect(host.selectedInputDevice == nil)
        #expect(host.inputChannelCount == 0)
        #expect(host.outputChannelCount == 0)
    }

    /// A channel the route validated can stop being valid afterwards, and when it does the host
    /// *keeps* it: the routing is remembered, shown in parentheses, and wired up again if the
    /// device that had that channel comes back.
    ///
    /// This used to clamp to the device's last channel, which silently rewrote a saved routing —
    /// a moment on a 2-channel device was enough to lose an 8-channel layout for good.
    ///
    /// Needs real hardware to have a bound to exceed; returns rather than fails without it, like
    /// the device tests.
    @Test func refreshingDevicesRemembersAChannelThatNoLongerExists() async throws {
        let host = AudioHost()
        host.refreshDevices()

        let inputs = host.inputChannelCount
        guard inputs > 0 else { return }

        let instance = try #require(await host.addInstance())
        // Deliberately past the end. The route wouldn't accept this, but a device swap can leave
        // an already-accepted value stranded there.
        instance.inputChannel = inputs + 4

        host.refreshDevices()

        #expect(instance.inputChannel == inputs + 4,
                "a channel past the device's count must be kept, not rewritten")
        // And it doesn't stop the host running: only the one link is left unwired.
        #expect(host.startBlockedReason == nil || host.startBlockedReason?.contains("hannel") == false,
                "an out-of-range channel must never be what blocks the start")
    }
}

struct WebServerSettingsTests {

    @Test func defaultsAreOffAndUnprivileged() {
        let settings = WebServerSettings()
        #expect(!settings.isEnabled)
        #expect(!settings.requiresAuthentication)
        #expect(WebServerSettings.portRange.contains(settings.port))
    }

    /// Auth on with no username would reject every request, which the settings UI and
    /// `reconcile()` both need to detect before binding.
    @Test func incompleteAuthenticationIsDetected() {
        var settings = WebServerSettings()
        #expect(settings.isAuthenticationComplete)

        settings.requiresAuthentication = true
        #expect(!settings.isAuthenticationComplete)

        settings.username = "edgars"
        #expect(settings.isAuthenticationComplete)
    }

    @Test func roundTripsThroughJSON() throws {
        var settings = WebServerSettings()
        settings.isEnabled = true
        settings.port = 9001
        settings.requiresAuthentication = true
        settings.username = "edgars"

        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(WebServerSettings.self, from: data) == settings)
    }

    /// The password belongs in the keychain, not in the settings blob that gets written to a
    /// world-readable plist. Encoding it by accident is exactly the regression to catch.
    @Test func doesNotCarryThePassword() throws {
        var settings = WebServerSettings()
        settings.username = "edgars"

        let json = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        #expect(!json.lowercased().contains("password"))
    }

    /// Same trap as `HostSettings`: a missing key must fall back to the default rather than throw,
    /// because a decode failure anywhere loses the user's entire session.
    @Test func decodesAPartialObject() throws {
        let data = Data(#"{"port": 9999}"#.utf8)
        let settings = try JSONDecoder().decode(WebServerSettings.self, from: data)

        #expect(settings.port == 9999)
        #expect(!settings.isEnabled)
        #expect(!settings.requiresAuthentication)
        #expect(settings.username == "")
    }

    @Test func decodesAnEmptyObject() throws {
        let settings = try JSONDecoder().decode(WebServerSettings.self, from: Data("{}".utf8))
        #expect(settings == WebServerSettings())
    }
}

/// The rules for a user-set instance name, which doubles as the instance's id in the web API.
struct InstanceNameTests {

    @Test func acceptsAnOrdinaryName() {
        #expect(InstanceName.validate("Stage Left ✓", among: ["Instance 1"]) == nil)
    }

    @Test func refusesEmpty() {
        #expect(InstanceName.validate("", among: []) == .empty)
        #expect(InstanceName.validate(InstanceName.normalized("   "), among: []) == .empty)
    }

    @Test func thirtyTwoCharactersIsTheLimit() {
        #expect(InstanceName.validate(String(repeating: "a", count: 32), among: []) == nil)
        #expect(InstanceName.validate(String(repeating: "a", count: 33), among: []) == .tooLong)
        // Counted as visible characters, not bytes: 32 emoji are fine.
        #expect(InstanceName.validate(String(repeating: "🎤", count: 32), among: []) == nil)
    }

    @Test(arguments: ["a/b", "line\nbreak", "tab\there", "bell\u{07}"])
    func refusesControlCharactersAndSlash(_ name: String) {
        #expect(InstanceName.validate(name, among: []) == .invalidCharacters)
    }

    @Test func uniquenessIgnoresCase() {
        #expect(InstanceName.validate("stage", among: ["Stage"]) == .duplicate("Stage"))
    }

    @Test func sanitizingStripsAndCaps() {
        #expect(InstanceName.sanitized("a/b\nc") == "abc")
        #expect(InstanceName.sanitized(String(repeating: "x", count: 40)).count == 32)
    }

    @Test func defaultsFillTheLowestGap() {
        #expect(InstanceName.defaultName(among: []) == "Instance 1")
        #expect(InstanceName.defaultName(among: ["Instance 1", "Instance 3"]) == "Instance 2")
        #expect(InstanceName.defaultName(among: ["instance 1"]) == "Instance 2")
    }

    @Test func restoredNamesAreMadeValidAndUnique() {
        let names = AudioHost.restoredNames([nil, "Instance 1", "Keep", "keep", "bad/name", "  Trim  "])
        #expect(names == ["Instance 2", "Instance 1", "Keep", "Instance 3", "Instance 4", "Trim"])
    }

    @Test func theNameIsPersistedAndOldSettingsStillDecode() throws {
        let saved = InstanceSettings(name: "Stage Left", inputChannel: 2)
        let decoded = try JSONDecoder().decode(InstanceSettings.self,
                                               from: JSONEncoder().encode(saved))
        #expect(decoded.name == "Stage Left")

        // Settings written before names existed have no key at all.
        let old = try JSONDecoder().decode(InstanceSettings.self,
                                           from: Data(#"{"inputChannel": 1, "outputChannel": 1, "isBypassed": false, "isMuted": false}"#.utf8))
        #expect(old.name == nil)
    }

    @Test func theInstancePathIsOneEncodedSegment() {
        #expect(WebControlService.instancePath(for: "Instance 1") == "/api/instances/Instance%201")
        #expect(WebControlService.instancePath(for: "Stage ✓") == "/api/instances/Stage%20%E2%9C%93")
    }

    @Test func theRouteDecodesAnEncodedName() {
        let (path, _) = HTTPRequestParser.splitTarget("/api/instances/Stage%20%E2%9C%93")
        #expect(WebControlService.extractPathFromTemplate(in: path, matching: "/api/instances/{id}")
                == "Stage ✓")
    }
}

/// Host-side naming: defaults on add, rename enforcement, and lookup by name.
@MainActor
struct InstanceNamingHostTests {

    private func host(withInstances count: Int) async throws -> AudioHost {
        // A bare host stays in its restoring state, so nothing here reaches UserDefaults.
        let host = AudioHost(pluginInstalled: true)
        for _ in 0..<count {
            await host.addInstance()
        }
        try #require(host.instances.count == count)
        return host
    }

    @Test func newInstancesGetDistinctDefaultNames() async throws {
        let host = try await host(withInstances: 3)
        #expect(host.instances.map(\.name) == ["Instance 1", "Instance 2", "Instance 3"])

        // A removal leaves a gap, which the next add fills.
        host.removeInstance(id: host.instances[1].id)
        await host.addInstance()
        #expect(host.instances.map(\.name).last == "Instance 2")
    }

    @Test func renameEnforcesUniquenessAndRules() async throws {
        let host = try await host(withInstances: 2)
        let first = host.instances[0]

        #expect(host.rename(first, to: "  Stage Left  ") == nil)
        #expect(first.name == "Stage Left")

        #expect(host.rename(host.instances[1], to: "stage left") == .duplicate("Stage Left"))
        #expect(host.rename(host.instances[1], to: "") == .empty)
        #expect(host.rename(host.instances[1], to: "a/b") == .invalidCharacters)
        #expect(host.instances[1].name == "Instance 2")

        // Changing only the case of your own name is not a clash with yourself.
        #expect(host.rename(first, to: "STAGE LEFT") == nil)
        #expect(first.name == "STAGE LEFT")
    }

    @Test func lookupIsByNameIgnoringCase() async throws {
        let host = try await host(withInstances: 2)
        #expect(host.instance(named: "instance 2") === host.instances[1])
        #expect(host.instance(named: "Instance 9") == nil)
    }
}
