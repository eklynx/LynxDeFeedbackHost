//
//  WebShutdownTests.swift
//  DeFeedbackHostTests
//
//  Spec rules SH6 to SH10 (docs/shutdown-spec.md): the `POST /api/shutdown` handler and the status
//  `shutdown` object. Uses fake settings and a fake `SystemShutdown`, so nothing is ever shut down.
//
import Foundation
import Testing

@testable import DeFeedbackHost

@MainActor
private final class FakeSettings: ShutdownSettings {
    var isEnabled = true
    var isTestMode = false
    var phrase = "shutdown now"
}

@MainActor
private final class FakeShutdown: SystemShutdown {
    var isTestMode = false
    var failure: ShutdownError?
    private(set) var performCount = 0

    func perform() async throws {
        performCount += 1
        if let failure { throw failure }
    }
}

@MainActor
private struct ShutdownRig {
    let settings = FakeSettings()
    let shutdown = FakeShutdown()
    let service: WebControlService

    init() {
        let suite = "WebShutdownTests-\(UUID().uuidString)"
        let host = AudioHost(defaults: UserDefaults(suiteName: suite)!, pluginInstalled: true)
        service = WebControlService(host: host)
        service.shutdownSettings = settings
        service.systemShutdown = shutdown
    }

    func post(json: Any? = nil, contentType: String? = "application/json") async -> HTTPResponse {
        var headers = HTTPHeaders()
        if let contentType { headers.append("Content-Type", contentType) }
        let body = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let request = HTTPRequest(method: "POST", target: "/api/shutdown", path: "/api/shutdown", query: [:],
                                  headers: headers, body: body)
        guard case .respond(let response) = await service.routeEndpoint(request) else {
            Issue.record("POST /api/shutdown did not produce a plain response")
            return HTTPResponse(status: 0)
        }
        return response
    }
}

private extension HTTPResponse {
    var object: [String: Any]? {
        try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
    var errorText: String? { object?["error"] as? String }
}

@MainActor
@Suite("Web shutdown")
struct WebShutdownTests {

    @Test func shutdownCheckOrder() async {
        let rig = ShutdownRig()

        rig.settings.isEnabled = false
        let disabled = await rig.post(json: ["nope": 1])
        #expect(disabled.status == 409)
        #expect(disabled.errorText == WebErrorStrings.ShutdownDisabled.rawValue)

        rig.settings.isEnabled = true
        for bad: Any in [["nope": 1], ["phrase": 5], ["phrase": NSNull()]] {
            let malformed = await rig.post(json: bad)
            #expect(malformed.status == 400)
            #expect(malformed.errorText == WebErrorStrings.ExpectedPhrase.rawValue)
        }

        for wrong in ["Shutdown now", "shutdown now ", ""] {
            let response = await rig.post(json: ["phrase": wrong])
            #expect(response.status == 403)
            #expect(response.errorText == WebErrorStrings.WrongPhrase.rawValue)
        }
        #expect(rig.shutdown.performCount == 0)
    }

    @Test func shutdownAccepted() async {
        let rig = ShutdownRig()
        let response = await rig.post(json: ["phrase": "shutdown now"])
        #expect(response.status == 202)
        #expect(response.object?["test"] as? Bool == false)
        #expect(response.object?["protocol"] as? Int == WebControlService.protocolVersion)
        #expect(rig.shutdown.performCount == 1)
    }

    @Test func shutdownInTestMode() async {
        let rig = ShutdownRig()
        rig.shutdown.isTestMode = true
        let response = await rig.post(json: ["phrase": "shutdown now"])
        #expect(response.status == 202)
        #expect(response.object?["test"] as? Bool == true)
        #expect(rig.shutdown.performCount == 1)
    }

    @Test func shutdownFailureIs500() async {
        let rig = ShutdownRig()

        rig.shutdown.failure = .notPermitted
        let denied = await rig.post(json: ["phrase": "shutdown now"])
        #expect(denied.status == 500)
        #expect(denied.errorText?.contains("System Events") == true)

        rig.shutdown.failure = .failed("The disk is on fire.")
        let failed = await rig.post(json: ["phrase": "shutdown now"])
        #expect(failed.status == 500)
        #expect(failed.errorText == WebErrorStrings.shutdownFailed("The disk is on fire."))
    }

    @Test func statusCarriesShutdown() async throws {
        let rig = ShutdownRig()
        rig.settings.phrase = "bye"
        rig.settings.isTestMode = true
        let status = rig.service.statusPayload()
        let shutdown = try #require(status["shutdown"] as? [String: Any])
        #expect(shutdown["enabled"] as? Bool == true)
        #expect(shutdown["testMode"] as? Bool == true)
        #expect(shutdown["phrase"] as? String == "bye")

        // Without injected settings shutdown reports as off.
        let bare = WebControlService(host: AudioHost(defaults: UserDefaults(suiteName: "x-\(UUID())")!,
                                                     pluginInstalled: true))
        let bareShutdown = try #require(bare.statusPayload()["shutdown"] as? [String: Any])
        #expect(bareShutdown["enabled"] as? Bool == false)
    }
}
