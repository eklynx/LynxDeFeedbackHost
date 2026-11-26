//
//  WebHandlerTests.swift
//  DeFeedbackHostTests
//
//  Characterization tests for the web service's request handling: routing, the 405 table, and
//  every status code and error order of the command endpoints. They describe how the service
//  behaves today so it can be restructured without changing the API (issue #41); the contract
//  itself is openapi.yaml.
//
//  They run against a bare `AudioHost` with fake devices and plugin-less instances (debug test
//  seams), so no audio hardware or Audio Unit is needed. Not covered, because they need a running
//  host or the real plugin: the "stop the host first" 409s, a successful add, and Strength values.
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import Foundation
import Testing

@testable import DeFeedbackHost

@MainActor
private struct Rig {
    let host: AudioHost
    let service: WebControlService

    init(pluginInstalled: Bool = true, withHardware: Bool = true) {
        let suite = "WebHandlerTests-\(UUID().uuidString)"
        host = AudioHost(defaults: UserDefaults(suiteName: suite)!, pluginInstalled: pluginInstalled)
        if withHardware {
            host.setHardwareForTesting(
                inputDevices: [AudioDevice(id: 101, name: "Mic", uid: "in-a",
                                           inputChannelCount: 2, outputChannelCount: 0)],
                outputDevices: [AudioDevice(id: 202, name: "Speakers", uid: "out-a",
                                            inputChannelCount: 0, outputChannelCount: 2)],
                inputSampleRates: [44100, 48000],
                outputSampleRates: [44100, 48000])
        }
        service = WebControlService(host: host)
    }

    func send(_ method: String, _ path: String, json: Any? = nil,
              contentType: String? = "application/json", rawBody: Data? = nil) async -> HTTPResponse {
        var headers = HTTPHeaders()
        if let contentType { headers.append("Content-Type", contentType) }
        let body = rawBody ?? json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let request = HTTPRequest(method: method, target: path, path: path, query: [:],
                                  headers: headers, body: body)
        guard case .respond(let response) = await service.routeEndpoint(request) else {
            Issue.record("\(method) \(path) did not produce a plain response")
            return HTTPResponse(status: 0)
        }
        return response
    }
}

private extension HTTPResponse {
    var errorText: String? {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? String
    }
    var object: [String: Any]? {
        try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}

@MainActor
@Suite("Web handlers")
struct WebHandlerTests {

    // MARK: Routing

    @Test(arguments: [
        ("POST", "/", "GET, HEAD"), ("POST", "/index.html", "GET, HEAD"),
        ("POST", "/api/status", "GET, HEAD"), ("POST", "/api/update", "GET, HEAD"),
        ("POST", "/api/events", "GET"),
        ("GET", "/api/system", "POST"), ("GET", "/api/devices", "POST"),
        ("GET", "/api/sample-rate", "POST"), ("GET", "/api/buffer-size", "POST"),
        ("DELETE", "/api/instances", "GET, HEAD, POST"),
        ("PUT", "/api/instances/Alpha", "GET, HEAD, PATCH, DELETE"),
    ])
    func wrongMethodIs405WithAnAllowHeader(method: String, path: String, allow: String) async {
        let response = await Rig().send(method, path)
        #expect(response.status == 405)
        #expect(response.headers["Allow"] == allow)
    }

    @Test func unknownPathIs404() async {
        let response = await Rig().send("GET", "/nope")
        #expect(response.status == 404)
        #expect(response.errorText == WebErrorStrings.pageNotFound(path: "/nope"))
    }

    @Test func readEndpointsAnswerGetAndHead() async {
        let rig = Rig()
        for path in ["/api/status", "/api/update", "/api/instances"] {
            for method in ["GET", "HEAD"] {
                let response = await rig.send(method, path)
                #expect(response.status == 200, "\(method) \(path)")
            }
        }
    }

    @Test func statusCarriesTheProtocolAndWarnings() async {
        let status = await Rig().send("GET", "/api/status").object
        #expect(status?["protocol"] as? Int == WebControlService.protocolVersion)
        #expect(status?["warnings"] is [Any])
        #expect(status?["running"] as? Bool == false)
    }

    @Test func eventsEndpointOpensAStream() async {
        let rig = Rig()
        let request = HTTPRequest(method: "GET", target: "/api/events", path: "/api/events", query: [:],
                                  headers: HTTPHeaders(), body: Data())
        guard case .stream = await rig.service.routeEndpoint(request) else {
            Issue.record("expected a stream"); return
        }
    }

    // MARK: Body checks

    @Test(arguments: [
        ("POST", "/api/system"), ("POST", "/api/devices"), ("POST", "/api/sample-rate"),
        ("POST", "/api/buffer-size"), ("POST", "/api/instances"), ("PATCH", "/api/instances/Alpha"),
    ])
    func aNonJSONBodyIs415(method: String, path: String) async {
        for type in [nil, "text/plain"] {
            let response = await Rig().send(method, path, json: ["x": 1], contentType: type)
            #expect(response.status == 415, "\(method) \(path) with \(type ?? "no type")")
            #expect(response.errorText == WebErrorStrings.WrongContentType.rawValue)
        }
    }

    @Test func aJSONBodyThatIsNotAnObjectIsTreatedAsEmpty() async {
        let response = await Rig().send("POST", "/api/devices", rawBody: Data("[1,2]".utf8))
        #expect(response.status == 400)
        #expect(response.errorText == WebErrorStrings.ExpectedDeviceUIDs.rawValue)
    }

    // MARK: POST /api/system

    @Test func systemNeedsABooleanRunning() async {
        let rig = Rig()
        for body: [String: Any] in [[:], ["running": "yes"], ["running": "true"]] {
            let response = await rig.send("POST", "/api/system", json: body)
            #expect(response.status == 400)
            #expect(response.errorText == WebErrorStrings.ExpectedRunning.rawValue)
        }
    }

    @Test func startingIsRefusedWithTheBlockedReason() async {
        let rig = Rig(pluginInstalled: false)
        let response = await rig.send("POST", "/api/system", json: ["running": true])
        #expect(response.status == 409)
        #expect(response.errorText == rig.host.startBlockedReason)
    }

    @Test func stoppingAStoppedHostIs202() async {
        let response = await Rig().send("POST", "/api/system", json: ["running": false])
        #expect(response.status == 202)
        #expect(response.object?["running"] as? Bool == false)
    }

    // MARK: POST /api/devices

    @Test func devicesNeedAnInputOrAnOutput() async {
        let response = await Rig().send("POST", "/api/devices", json: [:])
        #expect(response.status == 400)
        #expect(response.errorText == WebErrorStrings.ExpectedDeviceUIDs.rawValue)
    }

    @Test func deviceFieldsMustBeUIDStrings() async {
        let rig = Rig()
        let input = await rig.send("POST", "/api/devices", json: ["input": 5])
        #expect(input.status == 400)
        #expect(input.errorText == WebErrorStrings.InputMustBeUID.rawValue)
        let output = await rig.send("POST", "/api/devices", json: ["output": 5])
        #expect(output.status == 400)
        #expect(output.errorText == WebErrorStrings.OutputMustBeUID.rawValue)
    }

    @Test func anUnknownUIDIs404() async {
        let rig = Rig()
        let input = await rig.send("POST", "/api/devices", json: ["input": "nope"])
        #expect(input.status == 404)
        #expect(input.errorText == WebErrorStrings.noDeviceWithUID("nope", direction: "input"))
        let output = await rig.send("POST", "/api/devices", json: ["output": "nope"])
        #expect(output.status == 404)
        #expect(output.errorText == WebErrorStrings.noDeviceWithUID("nope", direction: "output"))
    }

    @Test func nothingIsAppliedWhenOneOfTheTwoIsWrong() async {
        let rig = Rig()
        let response = await rig.send("POST", "/api/devices", json: ["input": "in-a", "output": "nope"])
        #expect(response.status == 404)
        #expect(rig.host.selectedInputDeviceUID == nil)
        #expect(rig.host.selectedOutputDeviceUID == nil)
    }

    @Test func validDevicesAreSelected() async {
        let rig = Rig()
        let response = await rig.send("POST", "/api/devices", json: ["input": "in-a", "output": "out-a"])
        #expect(response.status == 202)
        #expect(rig.host.selectedInputDeviceUID == "in-a")
        #expect(rig.host.selectedOutputDeviceUID == "out-a")
    }

    @Test func oneDeviceCanBeSentAlone() async {
        let rig = Rig()
        let response = await rig.send("POST", "/api/devices", json: ["output": "out-a"])
        #expect(response.status == 202)
        #expect(rig.host.selectedInputDeviceUID == nil)
        #expect(rig.host.selectedOutputDeviceUID == "out-a")
    }

    // MARK: POST /api/sample-rate

    @Test func sampleRateNeedsAnInputOrAnOutput() async {
        let response = await Rig().send("POST", "/api/sample-rate", json: [:])
        #expect(response.status == 400)
        #expect(response.errorText == WebErrorStrings.ExpectedSampleRates.rawValue)
    }

    @Test func aRateMustBeAPositiveNumber() async {
        let rig = Rig()
        let text = await rig.send("POST", "/api/sample-rate", json: ["input": "fast"])
        #expect(text.status == 400)
        #expect(text.errorText == WebErrorStrings.rateMustBeHertz(direction: "input"))
        for bad in [0, -48000] {
            let response = await rig.send("POST", "/api/sample-rate", json: ["output": bad])
            #expect(response.status == 400)
            #expect(response.errorText == WebErrorStrings.rateMustBePositive(direction: "output"))
        }
    }

    @Test func aRateTheDeviceDoesNotOfferIs404() async {
        let rig = Rig()
        let response = await rig.send("POST", "/api/sample-rate", json: ["input": 96000])
        #expect(response.status == 404)
        #expect(response.errorText == WebErrorStrings.rateNotOffered(96000, direction: "input",
                                                                     offered: [44100, 48000]))
    }

    @Test func noReportedRatesIs404() async {
        let rig = Rig(withHardware: false)
        let response = await rig.send("POST", "/api/sample-rate", json: ["input": 48000])
        #expect(response.status == 404)
        #expect(response.errorText == WebErrorStrings.noRatesReported(direction: "input"))
    }

    @Test func nothingIsAppliedWhenOneRateIsWrong() async {
        let rig = Rig()
        let response = await rig.send("POST", "/api/sample-rate", json: ["input": 48000, "output": 96000])
        #expect(response.status == 404)
        #expect(rig.host.selectedInputSampleRate == nil)
    }

    @Test func offeredRatesAreSelected() async {
        let rig = Rig()
        let response = await rig.send("POST", "/api/sample-rate", json: ["input": 48000, "output": 44100])
        #expect(response.status == 202)
        #expect(rig.host.selectedInputSampleRate == 48000)
        #expect(rig.host.selectedOutputSampleRate == 44100)
    }

    // MARK: POST /api/buffer-size

    @Test func bufferSizeNeedsAValue() async {
        let response = await Rig().send("POST", "/api/buffer-size", json: [:])
        #expect(response.status == 400)
        #expect(response.errorText == WebErrorStrings.ExpectedBufferSize.rawValue)
    }

    @Test(arguments: [("big" as Any), (true as Any), (64.5 as Any)])
    func bufferSizeMustBeAWholeNumber(value: Any) async {
        let response = await Rig().send("POST", "/api/buffer-size", json: ["bufferSize": value])
        #expect(response.status == 400)
        #expect(response.errorText == WebErrorStrings.fieldMustBe("bufferSize",
                                                                  .BufferSizeDescriptionSuffix))
    }

    @Test func anUnofferedBufferSizeIs400() async {
        let response = await Rig().send("POST", "/api/buffer-size", json: ["bufferSize": 100])
        #expect(response.status == 400)
        #expect(response.errorText == WebErrorStrings.bufferSizeNotOffered(
            100, offered: PluginConfiguration.validBufferSizes))
    }

    @Test func anOfferedBufferSizeIsApplied() async {
        let rig = Rig()
        let response = await rig.send("POST", "/api/buffer-size", json: ["bufferSize": 256])
        #expect(response.status == 202)
        #expect(rig.host.bufferSize == 256)
    }

    // MARK: POST /api/instances

    @Test func addingWithoutThePluginIs409() async {
        let response = await Rig(pluginInstalled: false).send("POST", "/api/instances", json: [:])
        #expect(response.status == 409)
        #expect(response.errorText == AudioHostError.pluginNotInstalled.localizedDescription)
    }

    // MARK: Instance by name

    @Test func anUnknownInstanceIs404ForEveryMethod() async {
        let rig = Rig()
        for (method, body) in [("GET", nil), ("HEAD", nil), ("DELETE", nil),
                               ("PATCH", ["muted": true])] as [(String, [String: Any]?)] {
            let response = await rig.send(method, "/api/instances/ghost", json: body)
            #expect(response.status == 404, Comment(rawValue: method))
            #expect(response.errorText == WebErrorStrings.noInstance(id: "ghost"), Comment(rawValue: method))
        }
    }

    @Test func anInstanceIsFoundByNameIgnoringCase() async {
        let rig = Rig()
        rig.host.addBareInstanceForTesting(name: "Alpha")
        rig.host.addBareInstanceForTesting(name: "Beta")
        for method in ["GET", "HEAD"] {
            let response = await rig.send(method, "/api/instances/beta")
            #expect(response.status == 200)
        }
        let body = await rig.send("GET", "/api/instances/beta").object
        #expect(body?["id"] as? String == "Beta")
        #expect(body?["index"] as? Int == 1)
    }

    @Test func deletingRemovesTheInstance() async {
        let rig = Rig()
        rig.host.addBareInstanceForTesting(name: "Alpha")
        let response = await rig.send("DELETE", "/api/instances/Alpha")
        #expect(response.status == 202)
        #expect(rig.host.instances.isEmpty)
    }

    // MARK: PATCH /api/instances/{id}

    private func rigWithInstances() -> (Rig, PluginInstance) {
        let rig = Rig()
        let alpha = rig.host.addBareInstanceForTesting(name: "Alpha")
        rig.host.addBareInstanceForTesting(name: "Beta")
        rig.host.selectedInputDeviceUID = "in-a"
        rig.host.selectedOutputDeviceUID = "out-a"
        return (rig, alpha)
    }

    @Test func aPatchNeedsAtLeastOneKnownSetting() async {
        let (rig, _) = rigWithInstances()
        let response = await rig.send("PATCH", "/api/instances/Alpha", json: ["colour": "red"])
        #expect(response.status == 400)
        #expect(response.errorText == WebErrorStrings.ExpectedSomeSetting.rawValue)
    }

    @Test func aNameMustBeAStringAndValid() async {
        let (rig, alpha) = rigWithInstances()
        let notString = await rig.send("PATCH", "/api/instances/Alpha", json: ["name": 5])
        #expect(notString.status == 400)
        #expect(notString.errorText == WebErrorStrings.NameMustBeString.rawValue)
        let empty = await rig.send("PATCH", "/api/instances/Alpha", json: ["name": "  "])
        #expect(empty.status == 400)
        let clash = await rig.send("PATCH", "/api/instances/Alpha", json: ["name": "beta"])
        #expect(clash.status == 409, "a clash with another instance is a conflict")
        #expect(alpha.name == "Alpha")
    }

    @Test func renamingWorks() async {
        let (rig, alpha) = rigWithInstances()
        let response = await rig.send("PATCH", "/api/instances/Alpha", json: ["name": "Gamma"])
        #expect(response.status == 202)
        #expect(alpha.name == "Gamma")
    }

    @Test func strengthOnAnInstanceWithoutOneIs409WhateverWasSent() async {
        let (rig, alpha) = rigWithInstances()
        for value in [50, "loud"] as [Any] {
            let response = await rig.send("PATCH", "/api/instances/Alpha", json: ["strength": value])
            #expect(response.status == 409)
            #expect(response.errorText == WebErrorStrings.noStrengthParameter(alpha.displayName))
        }
    }

    @Test func mutedAndBypassedMustBeRealBooleans() async {
        let (rig, alpha) = rigWithInstances()
        for field in ["muted", "bypassed"] {
            for bad in ["yes", 1] as [Any] {
                let response = await rig.send("PATCH", "/api/instances/Alpha", json: [field: bad])
                #expect(response.status == 400, "\(field)=\(bad)")
                #expect(response.errorText == WebErrorStrings.mustBeBoolean(field))
            }
        }
        #expect(!alpha.isMuted && !alpha.isBypassed)
    }

    @Test func channelsAreRangeCheckedAgainstTheSelectedDevice() async {
        let (rig, alpha) = rigWithInstances()
        let high = await rig.send("PATCH", "/api/instances/Alpha", json: ["inputChannel": 2])
        #expect(high.status == 400)
        #expect(high.errorText == WebErrorStrings.channelOutOfRange("inputChannel", available: 2,
                                                                    direction: "input"))
        let negative = await rig.send("PATCH", "/api/instances/Alpha", json: ["outputChannel": -1])
        #expect(negative.status == 400)
        for bad in ["left", true] as [Any] {
            let response = await rig.send("PATCH", "/api/instances/Alpha", json: ["inputChannel": bad])
            #expect(response.status == 400)
            #expect(response.errorText == WebErrorStrings.fieldMustBe("inputChannel",
                                                                      .ChannelDescriptionSuffix))
        }
        let good = await rig.send("PATCH", "/api/instances/Alpha",
                                  json: ["inputChannel": 1, "outputChannel": 1])
        #expect(good.status == 202)
        #expect(alpha.inputChannel == 1 && alpha.outputChannel == 1)
    }

    @Test func aChannelWithNoDeviceSelectedIs409() async {
        let rig = Rig()
        rig.host.addBareInstanceForTesting(name: "Alpha")
        let response = await rig.send("PATCH", "/api/instances/Alpha", json: ["outputChannel": 0])
        #expect(response.status == 409)
        #expect(response.errorText == WebErrorStrings.noChannels(direction: "output"))
    }

    @Test func aSparseUpdateChangesOnlyWhatWasSent() async {
        let (rig, alpha) = rigWithInstances()
        let response = await rig.send("PATCH", "/api/instances/Alpha", json: ["muted": true])
        #expect(response.status == 202)
        #expect(alpha.isMuted)
        #expect(!alpha.isBypassed)
        #expect(alpha.name == "Alpha")
        #expect(alpha.inputChannel == 0)
    }

    @Test func nothingIsAppliedWhenALaterFieldIsInvalid() async {
        let (rig, alpha) = rigWithInstances()
        let response = await rig.send("PATCH", "/api/instances/Alpha",
                                      json: ["name": "Gamma", "muted": true, "bypassed": "no"])
        #expect(response.status == 400)
        #expect(alpha.name == "Alpha")
        #expect(!alpha.isMuted)
    }

    @Test func theFirstInvalidFieldInTheFixedOrderIsTheOneReported() async {
        let (rig, _) = rigWithInstances()
        // Order: name, strength, muted, bypassed, inputChannel, outputChannel.
        let mutedFirst = await rig.send("PATCH", "/api/instances/Alpha",
                                        json: ["outputChannel": "x", "bypassed": "x", "muted": "x"])
        #expect(mutedFirst.errorText == WebErrorStrings.mustBeBoolean("muted"))
        let bypassedNext = await rig.send("PATCH", "/api/instances/Alpha",
                                          json: ["outputChannel": "x", "bypassed": "x"])
        #expect(bypassedNext.errorText == WebErrorStrings.mustBeBoolean("bypassed"))
        let nameBeforeAll = await rig.send("PATCH", "/api/instances/Alpha",
                                           json: ["muted": "x", "name": 5])
        #expect(nameBeforeAll.errorText == WebErrorStrings.NameMustBeString.rawValue)
    }
}
