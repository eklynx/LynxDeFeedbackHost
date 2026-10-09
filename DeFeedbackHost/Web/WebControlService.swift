//
//  WebControlService.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/20/2026.
//

import AppKit
import Foundation
import Observation

// MARK: Error strings
// - AI used to refactor/extract these
enum WebErrorStrings: String {

    // MARK: - Service state

    case ServiceDisabled = "Web service is disabled"
    case IncompleteCredentials = "Set both a username and password or turn off Require sign-in."
    case ShuttingDown = "Server is shutting down"
    case IndexPageMissing = "Index page not found."

    // MARK: - Request

    case WrongContentType = "Send a JSON object with Content-Type: application/json"
    case UseGET = "Use GET"
    case UsePOST = "Use POST"
    case UseGETorPOST = "Invlaid HTTP method. Use GET or POST"
    case UseInstanceMethod = "Invalid HTTP method. Use GET, HEAD, PATCH, or DELETE"

    // MARK: - Status failed

    case ExpectedRunning = "Expected {\"running\": true|false}"
    case StartRefused = "Unable to start web host."
    case StartFailed = "The web host failed to start."

    // MARK: - Devices

    case ExpectedDeviceUIDs = """
        Expected {"input": "<uid>"} and/or {"output": "<uid>"}
        """
    case DevicesLocked = "Stop the host before changing devices."
    case InputMustBeUID = "\"input\" must be a device UID string"
    case OutputMustBeUID = "\"output\" must be a device UID string"

    // MARK: - Sample rates

    case ExpectedSampleRates = "Expected {\"input\": <hz>} and/or {\"output\": <hz>}"
    case SampleRatesLocked = "The host must be stopped before changing sample rates."

    // MARK: - Buffer size

    case ExpectedBufferSize = "Expected {\"bufferSize\": <frames>}"
    case BufferSizeLocked = "The host must be stopped before changing buffer size."

    // MARK: - Instances

    case AddFailed = "Add instance failed."
    case ExpectedSomeSetting = """
        Expected at least one of ["name", "strength", "muted", "bypassed", "inputChannel" \
        or "outputChannel"]
        """
    case NameMustBeString = "\"name\" must be a string"

    // MARK: - Field description suffixes
    //
    // Each completes `fieldMustBe(_:_:)`, so it has to read as the tail of that sentence.

    case BufferSizeDescriptionSuffix = "a valid buffer size of [32, 64, 128, 256, 512, or 1024]"
    case StrengthDescriptionSuffix = "a whole percentage from 0 to 100"
    case ChannelDescriptionSuffix = "a valid 0-based channel number"

    
    // MARK: - Parameterized errors
    static func pageNotFound(path: String) -> String {
        "Page not found: \(path)"
    }

    static func noDeviceWithUID(_ uid: String, direction: String) -> String {
        "No \(direction) device with UID \"\(uid)\""
    }

    static func bufferSizeNotOffered(_ frames: Int, offered: [Int]) -> String {
        let list = offered.map(String.init).joined(separator: ", ")
        return "\(frames) frames is not valid for the host. The host offers \(list) as valid values."
    }

    static func noInstance(id text: String) -> String {
        "No instance exists with id \"\(text)\"."
    }

    static func noStrengthParameter(_ displayName: String) -> String {
        "\(displayName) has no parameter 'Strength'."
    }

    static func strengthOutOfRange(_ percent: Int) -> String {
        "\"Strength\" must be an integer from 0 to 100"
    }

    static func rateMustBeHertz(direction: String) -> String {
        "\"\(direction)\" must be a valid sample rate in hertz"
    }

    static func rateMustBePositive(direction: String) -> String {
        "\"\(direction)\" must be a positive sample rate"
    }

    static func noRatesReported(direction: String) -> String {
        "The \(direction) device reports no sample rates."
    }

    static func rateNotOffered(_ requested: Double,
                               direction: String,
                               offered: [Double]) -> String {
        let list = offered.map { String(Int($0)) }.joined(separator: ", ")
        return "\(Int(requested))Hz is not valid for the \(direction) device. Valid values are: \(list)"
    }

    static func fieldMustBe(_ name: String, _ description: WebErrorStrings) -> String {
        "\"\(name)\" must be \(description.rawValue)"
    }

    static func mustBeBoolean(_ name: String) -> String {
        "\"\(name)\" must be true or false"
    }

    static func noChannels(direction: String) -> String {
        "No \(direction) device is selected"
    }

    static func channelOutOfRange(_ name: String,
                                  available: Int,
                                  direction: String) -> String {
        """
        Channel "\(name)" is not available on the \(direction) device.
        Specify a channel between  0 and \(available - 1).
        """
    }
}

// MARK: -
// MARK: WebControlService

/// The web service that allows for control of the host and plugin instances.  POST is used for command sending,
///  and EventStreams are used for status updates. JSON is used for the data format.
///
///  - AI used for framework, most features added by human.
@Observable
@MainActor
final class WebControlService {

    /// How often to take the status snaphot
    static let statusInterval: Duration = .milliseconds(250)

    /// Keep alive interval for the web connection
    static let statusKeepAlive: Duration = .seconds(2)

    /// History:
    ///  - 1: initial version.
    static let protocolVersion = 1

    @ObservationIgnored private let host: AudioHost

    @ObservationIgnored private var server: HTTPServer?
    @ObservationIgnored private let events = EventStream()
    @ObservationIgnored private let authGuard = BasicAuth.Guard()

    @ObservationIgnored private var activeSettings: (settings: WebServerSettings, password: String)?

    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var lastSentPayload: Data?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?

    @ObservationIgnored private var cachedIndexPage: Data?

    
    // MARK: - Observable state, for the settings window

    private(set) var state: HTTPServer.State = .stopped

    private(set) var connectedClients = 0

    var isListening: Bool {
        if case .listening = state { return true }
        return false
    }

    var listeningPort: UInt16? {
        if case .listening(let port) = state { return port }
        return nil
    }

    var errorMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    var reachableURL: String? {
        guard let port = listeningPort else { return nil }
        var name = ProcessInfo.processInfo.hostName
        if name.hasSuffix(".") { name.removeLast() }
        if name.isEmpty { name = "localhost" }
        return "http://\(name):\(port)/"
    }

    init(host: AudioHost) {
        self.host = host

        events.onClientCountChanged = { [weak self] count in
            guard let self else { return }
            Task { @MainActor in
                self.clientCountChanged(count)
            }
        }

        // make sure we shut down fully when terminating
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.shutDown()
            }
        }
    }

    
    // MARK: - Lifecycle

    func reconcile() {
        let settings = host.webServerSettings
        let password = settings.requiresAuthentication ? (KeychainPassword.read() ?? "") : ""

        guard settings.isEnabled else {
            shutDown()
            state = .failed(WebErrorStrings.ServiceDisabled.rawValue)
            return
        }
        
        let authValid = settings.isAuthenticationComplete
            && (!settings.requiresAuthentication
                || !password.isEmpty)

        guard authValid else {
            if settings.isEnabled, !settings.isAuthenticationComplete || password.isEmpty {
                shutDown()
                state = .failed(WebErrorStrings.IncompleteCredentials.rawValue)
            } else {
                shutDown()
            }
            return
        }

        authGuard.require(settings.requiresAuthentication
                          ? BasicAuth.Credentials(username: settings.username, password: password)
                          : nil,
                          allowingLoopback: settings.unauthedLocalhostAllowed)

        if let activeSettings, activeSettings.settings.port == settings.port, server != nil {
            self.activeSettings = (settings, password)
            return
        }

        startListener(on: settings.port)
        activeSettings = (settings, password)
    }

    private func startListener(on port: Int) {
        stopListener()

        let server = HTTPServer(router: { [weak self] request in
            if let rejection = self?.authGuard.reject(request) {
                return .respond(rejection)
            }
            guard let self else {
                return .respond(.error(503, WebErrorStrings.ShuttingDown.rawValue,
                                       closeConnection: true))
            }
            return await routeEndpoint(request)
        }, onStateChange: { [weak self] newState in
            guard let self else { return }
            Task { @MainActor in
                self.state = newState
            }
        })

        self.server = server
        server.start(port: UInt16(clamping: port))
    }

    private func stopListener() {
        statusTask?.cancel()
        statusTask = nil
        lastSentPayload = nil

        events.closeAll()
        server?.stop()
        server = nil
    }

    func shutDown() {
        stopListener()
        activeSettings = nil
        connectedClients = 0
        state = .stopped
    }

    
    // MARK: - Endpoints


    // endpoint routing
    private func routeEndpoint(_ request: HTTPRequest) async -> HTTPServer.RouteOutcome {

        
        if let id = Self.extractPathFromTemplate(in: request.path, matching: "/api/instances/{id}") {
            switch request.method {
            case "GET", "HEAD":
                return .respond(instanceResponse(id: id))
            case "PATCH":
                return .respond(updateInstance(id: id, request))
            case "DELETE":
                return .respond(removeInstance(id: id))
            default:
                return .respond(.error(405, WebErrorStrings.UseInstanceMethod.rawValue,
                                       headers: [("Allow", "GET, HEAD, PATCH, DELETE")]))
            }
        }

        switch (request.method, request.path) {

        // Web Interface
        case ("GET", "/"), ("HEAD", "/"), ("GET", "/index.html"):
            return .respond(pageResponse())

        // status
        case ("GET", "/api/status"), ("HEAD", "/api/status"):
            return .respond(.json(statusPayload()))

        // Instance list
        case ("GET", "/api/instances"), ("HEAD", "/api/instances"):
            return .respond(.json(Self.getInstanceList(host.instances)))

        // event stream
        case ("GET", "/api/events"):
            return .stream(EventStream.preamble) { [weak self] stream in
                guard let self else { return }
                Task { @MainActor in
                    self.attachStream(stream)
                }
            }

        // Settings updates
        case ("POST", "/api/system"):
            return .respond(await controlSystem(request))

        case ("POST", "/api/devices"):
            return .respond(setDevices(request))

        case ("POST", "/api/sample-rate"):
            return .respond(setSampleRate(request))

        case ("POST", "/api/buffer-size"):
            return .respond(setBufferSize(request))

        case ("POST", "/api/instances"):
            return .respond(await addInstance(request))

        // Incorrect http method used.
        case (_, "/"), (_, "/index.html"):
            return .respond(.error(405, WebErrorStrings.UseGET.rawValue,
                                   headers: [("Allow", "GET, HEAD")]))
        case (_, "/api/status"):
            return .respond(.error(405, WebErrorStrings.UseGET.rawValue,
                                   headers: [("Allow", "GET, HEAD")]))
        case (_, "/api/events"):
            return .respond(.error(405, WebErrorStrings.UseGET.rawValue,
                                   headers: [("Allow", "GET")]))
        case (_, "/api/system"), (_, "/api/devices"), (_, "/api/sample-rate"),
             (_, "/api/buffer-size"):
            return .respond(.error(405, WebErrorStrings.UsePOST.rawValue,
                                   headers: [("Allow", "POST")]))
        case (_, "/api/instances"):
            return .respond(.error(405, WebErrorStrings.UseGETorPOST.rawValue,
                                   headers: [("Allow", "GET, HEAD, POST")]))

        // Default
        default:
            return .respond(.error(404, WebErrorStrings.pageNotFound(path: request.path)))
        }
    }

    /// Extracts the path from a templated URL.
    nonisolated static func extractPathFromTemplate(in path: String, matching template: String) -> String? {
        guard let brace = template.lastIndex(of: "{") else { return nil }
        let prefix = template[template.startIndex..<brace]

        guard path.hasPrefix(prefix) else { return nil }
        let tail = path.dropFirst(prefix.count)
        guard !tail.isEmpty, !tail.contains("/") else { return nil }

        return String(tail)
    }

    private func pageResponse() -> HTTPResponse {
        if let cachedIndexPage {
            return .html(cachedIndexPage)
        }
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html"),
              let data = try? Data(contentsOf: url) else {
            return .error(500, WebErrorStrings.IndexPageMissing.rawValue)
        }
        cachedIndexPage = data
        return .html(data)
    }

    // MARK: - Commands

    private func controlSystem(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = decodeJSONBody(request) else {
            return .error(415, WebErrorStrings.WrongContentType.rawValue)
        }
        guard let running = body["running"] as? Bool else {
            return .error(400, WebErrorStrings.ExpectedRunning.rawValue)
        }

        if running {
            guard host.canStart else {
                return .error(409, host.startBlockedReason
                              ?? WebErrorStrings.StartRefused.rawValue)
            }
            await host.start()
            // `start()` reports failures by setting `errorMessage` rather than throwing, so
            // make sure to check this when starting.
            if !host.isRunning {
                return .error(409, host.errorMessage ?? WebErrorStrings.StartFailed.rawValue)
            }
        } else {
            host.stop()
        }

        pushStatus(force: true)
        return .json(statusPayload(), status: 202)
    }


    private func setDevices(_ request: HTTPRequest) -> HTTPResponse {
        guard let body = decodeJSONBody(request) else {
            return .error(415, WebErrorStrings.WrongContentType.rawValue)
        }

        guard !host.isRunning else {
            return .error(409, WebErrorStrings.DevicesLocked.rawValue)
        }

        let containsInput = body["input"] != nil
        let containsOutput = body["output"] != nil
        guard containsInput || containsOutput else {
            return .error(400, WebErrorStrings.ExpectedDeviceUIDs.rawValue)
        }

        var inputDevice: AudioDevice?
        var outputDevice: AudioDevice?

        if containsInput {
            guard let uid = body["input"] as? String else {
                return .error(400, WebErrorStrings.InputMustBeUID.rawValue)
            }
            guard let device = host.inputDevices.first(where: { $0.uid == uid }) else {
                return .error(404, WebErrorStrings.noDeviceWithUID(uid, direction: "input"))
            }
            inputDevice = device
        }

        if containsOutput {
            guard let uid = body["output"] as? String else {
                return .error(400, WebErrorStrings.OutputMustBeUID.rawValue)
            }
            guard let device = host.outputDevices.first(where: { $0.uid == uid }) else {
                return .error(404, WebErrorStrings.noDeviceWithUID(uid, direction: "output"))
            }
            outputDevice = device
        }

        if let inputDevice { host.selectedInputDeviceUID = inputDevice.uid }
        if let outputDevice { host.selectedOutputDeviceUID = outputDevice.uid }

        pushStatus(force: true)
        return .json(statusPayload(), status: 202)
    }


    private func setSampleRate(_ request: HTTPRequest) -> HTTPResponse {
        guard let body = decodeJSONBody(request) else {
            return .error(415, WebErrorStrings.WrongContentType.rawValue)
        }

        guard !host.isRunning else {
            return .error(409, WebErrorStrings.SampleRatesLocked.rawValue)
        }

        let containsInput = body["input"] != nil
        let containsOutput = body["output"] != nil
        guard containsInput || containsOutput else {
            return .error(400, WebErrorStrings.ExpectedSampleRates.rawValue)
        }

        var inputSampleRate: Double?
        var outputSampleRate: Double?

        if containsInput {
            switch validateRate(body["input"], requestedRate: host.inputSampleRates, direction: "input") {
            case .verifiedValue(let rate): inputSampleRate = rate
            case .rejected(let response): return response
            }
        }

        if containsOutput {
            switch validateRate(body["output"], requestedRate: host.outputSampleRates,
                               direction: "output") {
            case .verifiedValue(let rate): outputSampleRate = rate
            case .rejected(let response): return response
            }
        }

        // Rate has resolved for both devices, proceed to save.
        if let inputSampleRate { host.selectedInputSampleRate = inputSampleRate }
        if let outputSampleRate { host.selectedOutputSampleRate = outputSampleRate }

        pushStatus(force: true)
        return .json(statusPayload(), status: 202)
    }


    private func setBufferSize(_ request: HTTPRequest) -> HTTPResponse {
        guard let body = decodeJSONBody(request) else {
            return .error(415, WebErrorStrings.WrongContentType.rawValue)
        }

        guard !host.isRunning else {
            return .error(409, WebErrorStrings.BufferSizeLocked.rawValue)
        }

        guard body["bufferSize"] != nil else {
            return .error(400, WebErrorStrings.ExpectedBufferSize.rawValue)
        }

        switch verifyInteger(body["bufferSize"], named: "bufferSize",
                              mustBe: .BufferSizeDescriptionSuffix) {

        case .rejected(let response):
            return response

        case .verifiedValue(let frames):
            let requestedBufferSize = PluginConfiguration.validBufferSizes
            guard requestedBufferSize.contains(frames) else {
                return .error(400, WebErrorStrings.bufferSizeNotOffered(frames, offered: requestedBufferSize))
            }
            host.bufferSize = frames
        }

        pushStatus(force: true)
        return .json(statusPayload(), status: 202)
    }


    /// Adds an instance of the plugin.
    ///
    /// Note: this can take a second or two; this method will wait until done before replying.
    private func addInstance(_ request: HTTPRequest) async -> HTTPResponse {

        guard decodeJSONBody(request) != nil else {
            return .error(415, WebErrorStrings.WrongContentType.rawValue)
        }

        guard host.isPluginInstalled else {
            return .error(409, AudioHostError.pluginNotInstalled.localizedDescription)
        }
        guard host.canAddInstance else {
            return .error(409, AudioHostError.maxInstancesReached.localizedDescription)
        }

        guard let instance = await host.addInstance() else {
            return .error(409, host.errorMessage ?? WebErrorStrings.AddFailed.rawValue)
        }

        pushStatus(force: true)
        var response = HTTPResponse.json(statusPayload(), status: 201)
        response.headers.append("Location", Self.instancePath(for: instance.name))
        return response
    }

    /// The `/api/instances/{id}` URL for an instance name, percent-encoded as a single path segment.
    nonisolated static func instancePath(for name: String) -> String {
        var segment = CharacterSet.urlPathAllowed
        segment.remove(charactersIn: "/")
        let encoded = name.addingPercentEncoding(withAllowedCharacters: segment) ?? name
        return "/api/instances/\(encoded)"
    }


    /// Removes an instance of the plugin.
    private func removeInstance(id text: String) -> HTTPResponse {
        guard let instance = host.instance(named: text),
              host.removeInstance(id: instance.id) else {
            return .error(404, WebErrorStrings.noInstance(id: text))
        }

        pushStatus(force: true)
        return .json(statusPayload(), status: 202)
    }

    /// Gets the settings of a single intsance.
    private func instanceResponse(id text: String) -> HTTPResponse {
        // The index rather than the instance, since the representation carries it.
        guard let index = host.instances.firstIndex(where: { InstanceName.matches($0.name, text) }) else {
            return .error(404, WebErrorStrings.noInstance(id: text))
        }
        return .json(Self.getInstance(host.instances[index], at: index))
    }

    /// Sparse updates a plugin instance.
    private func updateInstance(id text: String, _ request: HTTPRequest) -> HTTPResponse {
        guard let body = decodeJSONBody(request) else {
            return .error(415, WebErrorStrings.WrongContentType.rawValue)
        }
        guard let instance = host.instance(named: text) else {
            return .error(404, WebErrorStrings.noInstance(id: text))
        }

        let containsName = body["name"] != nil
        let containsStrength = body["strength"] != nil
        let containsMuted = body["muted"] != nil
        let containsBypassed = body["bypassed"] != nil
        let containsInputChannel = body["inputChannel"] != nil
        let containsOutputChannel = body["outputChannel"] != nil
        guard containsName || containsStrength || containsMuted || containsBypassed
                || containsInputChannel || containsOutputChannel else {
            return .error(400, WebErrorStrings.ExpectedSomeSetting.rawValue)
        }

        var name: String?
        var strength: Int?
        var muted: Bool?
        var bypassed: Bool?
        var input: Int?
        var output: Int?

        if containsName {
            guard let proposed = body["name"] as? String else {
                return .error(400, WebErrorStrings.NameMustBeString.rawValue)
            }
            if let error = host.validateName(proposed, for: instance) {
                // A clash with another instance is a conflict; anything else is a malformed name.
                if case .duplicate = error {
                    return .error(409, error.localizedDescription)
                }
                return .error(400, error.localizedDescription)
            }
            name = proposed
        }

        if containsStrength {
            // Checked before the value is even read, so a plugin with no Strength gives the same
            // answer whatever number was sent.
            guard instance.publishesStrength else {
                return .error(409,
                              WebErrorStrings.noStrengthParameter(instance.displayName))
            }
            switch verifyInteger(body["strength"], named: "strength",
                                  mustBe: .StrengthDescriptionSuffix) {
            case .rejected(let response): return response
            case .verifiedValue(let percent):
                guard (0...100).contains(percent) else {
                    return .error(400, WebErrorStrings.strengthOutOfRange(percent))
                }
                strength = percent
            }
        }

        if containsMuted {
            switch verifyBoolean(body["muted"], named: "muted") {
            case .rejected(let response): return response
            case .verifiedValue(let value): muted = value
            }
        }

        if containsBypassed {
            switch verifyBoolean(body["bypassed"], named: "bypassed") {
            case .rejected(let response): return response
            case .verifiedValue(let value): bypassed = value
            }
        }

        if containsInputChannel {
            switch verifyChannel(body["inputChannel"], named: "inputChannel",
                                  available: host.inputChannelCount, direction: "input") {
            case .rejected(let response): return response
            case .verifiedValue(let channel): input = channel
            }
        }

        if containsOutputChannel {
            switch verifyChannel(body["outputChannel"], named: "outputChannel",
                                  available: host.outputChannelCount, direction: "output") {
            case .rejected(let response): return response
            case .verifiedValue(let channel): output = channel
            }
        }

        if let name { host.rename(instance, to: name) }
        if let strength { instance.setStrengthPercent(strength) }
        if let muted { instance.isMuted = muted }
        if let bypassed { instance.isBypassed = bypassed }
        if let input { instance.inputChannel = input }
        if let output { instance.outputChannel = output }

        pushStatus(force: true)
        return .json(statusPayload(), status: 202)
    }

    // Certain values might not be accepted by the devices. This enum contains either a verified
    // value or the reason it was rejected.
    private enum CheckedValue<Value> {
        case verifiedValue(Value)
        case rejected(HTTPResponse)
    }

    /// Validates a sample rate is valid for the device.
    private func validateRate(_ value: Any?,
                             requestedRate: [Double],
                             direction: String) -> CheckedValue<Double> {
        guard let number = value as? NSNumber else {
            return .rejected(.error(400, WebErrorStrings.rateMustBeHertz(direction: direction)))
        }

        let requested = number.doubleValue
        guard requested.isFinite, requested > 0 else {
            return .rejected(.error(400, WebErrorStrings.rateMustBePositive(direction: direction)))
        }

        guard let match = requestedRate.first(where: { AudioHost.ratesMatch($0, requested) }) else {
            return .rejected(.error(404, requestedRate.isEmpty
                ? WebErrorStrings.noRatesReported(direction: direction)
                : WebErrorStrings.rateNotOffered(requested,
                                                 direction: direction,
                                                 offered: requestedRate)))
        }

        return .verifiedValue(match)
    }

    private func verifyInteger(_ value: Any?,
                                named name: String,
                                mustBe description: WebErrorStrings) -> CheckedValue<Int> {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return .rejected(.error(400, WebErrorStrings.fieldMustBe(name, description)))
        }
        guard number.doubleValue.isFinite,
              let whole = Int(exactly: number.doubleValue) else {
            return .rejected(.error(400, WebErrorStrings.fieldMustBe(name, description)))
        }
        return .verifiedValue(whole)
    }


    private func verifyChannel(_ value: Any?,
                                named name: String,
                                available: Int,
                                direction: String) -> CheckedValue<Int> {
        switch verifyInteger(value, named: name, mustBe: .ChannelDescriptionSuffix) {
        case .rejected(let response):
            return .rejected(response)

        case .verifiedValue(let channel):
            guard available > 0 else {
                return .rejected(.error(409,
                                        WebErrorStrings.noChannels(direction: direction)))
            }
            guard (0..<available).contains(channel) else {
                return .rejected(.error(400,
                                        WebErrorStrings.channelOutOfRange(name,
                                                                          available: available,
                                                                          direction: direction)))
            }
            return .verifiedValue(channel)
        }
    }

    private func verifyBoolean(_ value: Any?, named name: String) -> CheckedValue<Bool> {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return .rejected(.error(400, WebErrorStrings.mustBeBoolean(name)))
        }
        return .verifiedValue(number.boolValue)
    }

    private func decodeJSONBody(_ request: HTTPRequest) -> [String: Any]? {
        guard let type = request.headers["Content-Type"],
              type.lowercased().hasPrefix("application/json")
        else { return nil }

        guard let object = try? JSONSerialization.jsonObject(with: request.body),
              let dictionary = object as? [String: Any]
        else { return [:] }

        return dictionary
    }

    
    // MARK: - Status

    /// gets the status of the host.  All values are retrieved from the host even if they could be calculated locally.
    private func statusPayload() -> [String: Any] {
        let diagnostics = host.diagnostics

        return [
            "protocol": Self.protocolVersion,
            "running": host.isRunning,
            "canStart": host.canStart,
            "blockedReason": host.startBlockedReason ?? NSNull(),
            "sampleRate": host.isRunning
                ? finiteVal(host.runningSampleRate)
                : finiteVal(host.selectedOutputSampleRate ?? 0),
            "bufferSize": host.bufferSize,
            "bufferSizeChoices": PluginConfiguration.validBufferSizes,
            "bufferSizeAccepted": host.devicesRejectingBufferSize.isEmpty,
            "pluginInstalled": host.isPluginInstalled,
            "pluginMessage": host.isPluginInstalled
                ? NSNull()
                : AudioHostError.pluginNotInstalled.localizedDescription,
            "pluginURL": PluginConfiguration.pluginHomepage.absoluteString,
            "instances": Self.getInstanceList(host.instances),
            "instanceCount": host.instances.count,
            "maxInstanceCount": PluginConfiguration.maximumInstanceCount,
            "inputDevice": host.selectedInputDevice?.name
                ?? host.unavailableInputDevice?.name ?? NSNull(),
            "outputDevice": host.selectedOutputDevice?.name
                ?? host.unavailableOutputDevice?.name ?? NSNull(),
            "inputDeviceUID": host.selectedInputDeviceUID ?? NSNull(),
            "outputDeviceUID": host.selectedOutputDeviceUID ?? NSNull(),
            "inputDeviceMissing": host.unavailableInputDevice != nil,
            "outputDeviceMissing": host.unavailableOutputDevice != nil,
            "inputDevices": Self.getDeviceList(host.inputDevices, channels: \.inputChannelCount),
            "outputDevices": Self.getDeviceList(host.outputDevices, channels: \.outputChannelCount),
            "inputChannelCount": host.inputChannelCount,
            "outputChannelCount": host.outputChannelCount,
            "inputSampleRate": host.selectedInputSampleRate.map(finiteVal) ?? NSNull(),
            "outputSampleRate": host.selectedOutputSampleRate.map(finiteVal) ?? NSNull(),
            "inputSampleRates": host.inputSampleRates.map(finiteVal),
            "outputSampleRates": host.outputSampleRates.map(finiteVal),
            "sampleRatesMatch": host.doSampleRatesMatch,
            "dspLoad": finiteVal(diagnostics?.dspLoad ?? 0),
            "peakDspLoad": finiteVal(diagnostics?.peakDspLoad ?? 0),
            "underruns": diagnostics?.underruns ?? 0,
            "hasRendered": diagnostics?.hasRendered ?? false,
            "realtime": diagnostics?.audioThreadsAreRealtime ?? true,
            "error": host.errorMessage ?? NSNull(),
        ]
    }

    private static func getDeviceList(_ devices: [AudioDevice],
                                 channels: KeyPath<AudioDevice, Int>) -> [[String: Any]] {
        devices.map { device in
            ["uid": device.uid,
             "name": device.name,
             "channels": device[keyPath: channels]]
        }
    }

    private static func getInstanceList(_ instances: [PluginInstance]) -> [[String: Any]] {
        instances.enumerated().map { index, instance in
            getInstance(instance, at: index)
        }
    }

    private static func getInstance(_ instance: PluginInstance, at index: Int) -> [String: Any] {
        [
            "index": index,
            "id": instance.name,
            "pluginName": instance.displayName,
            "strength": instance.strengthPercent ?? NSNull(),
            "muted": instance.isMuted,
            "bypassed": instance.isBypassed,
            "inputChannel": instance.inputChannel,
            "outputChannel": instance.outputChannel,
            "error": instance.loadError ?? NSNull(),
        ]
    }

    private func finiteVal(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }

    private func attachStream(_ stream: HTTPStream) {
        events.add(stream)
        pushStatus(force: true)
    }

    private func clientCountChanged(_ count: Int) {
        connectedClients = count
        if count > 0 {
            startStatusLoop()
        } else {
            statusTask?.cancel()
            statusTask = nil
            lastSentPayload = nil
        }
    }

    private func startStatusLoop() {
        guard statusTask == nil else { return }

        statusTask = Task { [weak self] in
            var ticksSinceSend = 0
            let ticksPerKeepAlive = max(1, Int(Self.statusKeepAlive / Self.statusInterval))

            while !Task.isCancelled {
                try? await Task.sleep(for: Self.statusInterval)
                guard let self, !Task.isCancelled else { return }

                ticksSinceSend += 1
                let force = ticksSinceSend >= ticksPerKeepAlive
                if pushStatus(force: force) {
                    ticksSinceSend = 0
                }
            }
        }
    }

    @discardableResult
    private func pushStatus(force: Bool) -> Bool {
        guard connectedClients > 0 else { return false }
        guard let payload = try? JSONSerialization.data(withJSONObject: statusPayload(),
                                                        options: [.sortedKeys]) else {
            return false
        }

        if !force, payload == lastSentPayload { return false }

        lastSentPayload = payload
        events.broadcast(event: "status", json: payload)
        return true
    }
}
