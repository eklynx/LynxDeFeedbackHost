//
//  WebControlService+Commands.swift
//  DeFeedbackHost
//
//  The command and instance endpoints of the web API. Each handler checks its request with
//  `WebRequestValidation` (a failed check throws the `WebRejection` that becomes the error
//  response), changes the host only after every check has passed, then answers with the fresh
//  status. The order of the checks decides which error a request with several mistakes gets, and
//  WebHandlerTests pins it. Moved out of WebControlService.swift (issue #41).
//
import Foundation

extension WebControlService {

    /// The answer to a command that worked: the fresh status, also pushed to event listeners.
    func accepted(status: Int = 202) -> HTTPResponse {
        pushStatus(force: true)
        return .json(statusPayload(), status: status)
    }

    /// - Throws: 409 with `message` while the audio system is running.
    private func requireStopped(_ message: WebErrorStrings) throws {
        guard !host.isRunning else { throw WebRejection(409, message.rawValue) }
    }

    // MARK: - System

    func controlSystem(_ request: HTTPRequest) async -> HTTPResponse {
        await HTTPResponse.catching {
            let body = try WebRequestValidation.jsonBody(request)
            guard let running = body["running"] as? Bool else {
                throw WebRejection(400, WebErrorStrings.ExpectedRunning.rawValue)
            }
            if running {
                try await startHost()
            } else {
                host.stop()
            }
            return accepted()
        }
    }

    private func startHost() async throws {
        guard host.canStart else {
            throw WebRejection(409, host.startBlockedReason ?? WebErrorStrings.StartRefused.rawValue)
        }
        await host.start()
        // `start()` reports failures by setting `errorMessage` rather than throwing, so
        // make sure to check this when starting.
        if !host.isRunning {
            throw WebRejection(409, host.errorMessage ?? WebErrorStrings.StartFailed.rawValue)
        }
    }

    // MARK: - Shutdown

    /// `POST /api/shutdown` (spec rules SH6 to SH9). Checks run in order, the first failure decides:
    /// disabled (409), body not `{"phrase": string}` (400), wrong phrase (403). Only then is
    /// `SystemShutdown.perform()` called; the response says whether that was only a test.
    func shutdownSystem(_ request: HTTPRequest) async -> HTTPResponse {
        await HTTPResponse.catching {
            guard let settings = shutdownSettings, settings.isEnabled else {
                throw WebRejection(409, WebErrorStrings.ShutdownDisabled.rawValue)
            }
            let body = try WebRequestValidation.jsonBody(request)
            guard let phrase = body["phrase"] as? String else {
                throw WebRejection(400, WebErrorStrings.ExpectedPhrase.rawValue)
            }
            guard ShutdownPhrase.matches(phrase, expected: settings.phrase) else {
                throw WebRejection(403, WebErrorStrings.WrongPhrase.rawValue)
            }
            guard let shutdown = systemShutdown else {
                throw WebRejection(500, WebErrorStrings.shutdownFailed("no shutdown mechanism is available."))
            }

            let isTest = shutdown.isTestMode
            do {
                try await shutdown.perform()
            } catch ShutdownError.notPermitted {
                throw WebRejection(500, WebErrorStrings.ShutdownNotPermitted.rawValue)
            } catch ShutdownError.failed(let reason) {
                throw WebRejection(500, WebErrorStrings.shutdownFailed(reason))
            }

            pushStatus(force: true)
            var payload = statusPayload()
            payload["test"] = isTest
            return .json(payload, status: 202)
        }
    }

    // MARK: - Devices, sample rate, buffer size

    func setDevices(_ request: HTTPRequest) async -> HTTPResponse {
        await HTTPResponse.catching {
            let body = try WebRequestValidation.jsonBody(request)
            try requireStopped(.DevicesLocked)
            let fields = try WebDirectionFields(body, orElse: .ExpectedDeviceUIDs)

            let input = try fields.input.map { try device($0, direction: .input) }
            let output = try fields.output.map { try device($0, direction: .output) }

            if let input { host.selectedInputDeviceUID = input.uid }
            if let output { host.selectedOutputDeviceUID = output.uid }
            return accepted()
        }
    }

    /// The device with the UID in `value`.
    ///
    /// - Throws: 400 when it is not a string, 404 when no such device is attached.
    private func device(_ value: Any, direction: AudioHost.AudioDirection) throws -> AudioDevice {
        let (devices, mustBeUID, name) = switch direction {
        case .input: (host.inputDevices, WebErrorStrings.InputMustBeUID, "input")
        case .output: (host.outputDevices, WebErrorStrings.OutputMustBeUID, "output")
        }
        guard let uid = value as? String else {
            throw WebRejection(400, mustBeUID.rawValue)
        }
        guard let device = devices.first(where: { $0.uid == uid }) else {
            throw WebRejection(404, WebErrorStrings.noDeviceWithUID(uid, direction: name))
        }
        return device
    }

    func setSampleRate(_ request: HTTPRequest) async -> HTTPResponse {
        await HTTPResponse.catching {
            let body = try WebRequestValidation.jsonBody(request)
            try requireStopped(.SampleRatesLocked)
            let fields = try WebDirectionFields(body, orElse: .ExpectedSampleRates)

            let input = try fields.input.map {
                try WebRequestValidation.rate($0, offered: host.inputSampleRates, direction: "input")
            }
            let output = try fields.output.map {
                try WebRequestValidation.rate($0, offered: host.outputSampleRates, direction: "output")
            }

            // Rate has resolved for both devices, proceed to save.
            if let input { host.selectedInputSampleRate = input }
            if let output { host.selectedOutputSampleRate = output }
            return accepted()
        }
    }

    func setBufferSize(_ request: HTTPRequest) async -> HTTPResponse {
        await HTTPResponse.catching {
            let body = try WebRequestValidation.jsonBody(request)
            try requireStopped(.BufferSizeLocked)
            guard let raw = body["bufferSize"] else {
                throw WebRejection(400, WebErrorStrings.ExpectedBufferSize.rawValue)
            }

            let frames = try WebRequestValidation.integer(raw, named: "bufferSize",
                                                          mustBe: .BufferSizeDescriptionSuffix)
            let offered = PluginConfiguration.validBufferSizes
            guard offered.contains(frames) else {
                throw WebRejection(400, WebErrorStrings.bufferSizeNotOffered(frames, offered: offered))
            }
            host.bufferSize = frames
            return accepted()
        }
    }

    // MARK: - Instances

    /// Adds an instance of the plugin.
    ///
    /// Note: this can take a second or two; this method will wait until done before replying.
    func addInstance(_ request: HTTPRequest) async -> HTTPResponse {
        await HTTPResponse.catching {
            _ = try WebRequestValidation.jsonBody(request)

            guard host.isPluginInstalled else {
                throw WebRejection(409, AudioHostError.pluginNotInstalled.localizedDescription)
            }
            guard host.canAddInstance else {
                throw WebRejection(409, AudioHostError.maxInstancesReached.localizedDescription)
            }
            guard let instance = await host.addInstance() else {
                throw WebRejection(409, host.errorMessage ?? WebErrorStrings.AddFailed.rawValue)
            }

            var response = accepted(status: 201)
            response.headers.append("Location", Self.instancePath(for: instance.name))
            return response
        }
    }

    /// The `/api/instances/{id}` URL for an instance name, percent-encoded as a single path segment.
    nonisolated static func instancePath(for name: String) -> String {
        var segment = CharacterSet.urlPathAllowed
        segment.remove(charactersIn: "/")
        let encoded = name.addingPercentEncoding(withAllowedCharacters: segment) ?? name
        return "/api/instances/\(encoded)"
    }

    /// Removes an instance of the plugin.
    func removeInstance(id text: String) -> HTTPResponse {
        guard let instance = host.instance(named: text),
              host.removeInstance(id: instance.id) else {
            return .error(404, WebErrorStrings.noInstance(id: text))
        }
        return accepted()
    }

    /// Gets the settings of a single instance.
    func instanceResponse(id text: String) -> HTTPResponse {
        // The index rather than the instance, since the representation carries it.
        guard let index = host.instances.firstIndex(where: { InstanceName.matches($0.name, text) }) else {
            return .error(404, WebErrorStrings.noInstance(id: text))
        }
        return .json(WebStatusPayload.instanceJSON(host.instances[index], at: index))
    }

    /// Sparse updates a plugin instance.
    func updateInstance(id text: String, _ request: HTTPRequest) async -> HTTPResponse {
        await HTTPResponse.catching {
            let body = try WebRequestValidation.jsonBody(request)
            guard let instance = host.instance(named: text) else {
                throw WebRejection(404, WebErrorStrings.noInstance(id: text))
            }
            let changes = try WebInstanceChanges(body: body, instance: instance, host: host)
            changes.apply(to: instance, in: host)
            return accepted()
        }
    }
}
