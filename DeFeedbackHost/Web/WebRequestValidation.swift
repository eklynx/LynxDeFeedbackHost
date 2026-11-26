//
//  WebRequestValidation.swift
//  DeFeedbackHost
//
//  The checks the web API applies to request bodies, separate from the service so they need no host:
//  each takes the raw JSON value and returns the verified one, or throws the `WebRejection` that
//  becomes the error response. The messages and status codes are the API's contract (openapi.yaml);
//  the order the handlers call these in decides which error a bad request gets.
//  Moved out of WebControlService.swift without changing behaviour (issue #41).
//
import Foundation

/// A request the service refuses. Thrown by the checks and turned into the response by
/// `HTTPResponse.catching`.
nonisolated struct WebRejection: Error {
    let response: HTTPResponse

    init(_ status: Int, _ message: String) {
        response = .error(status, message)
    }
}

extension HTTPResponse {

    /// Runs `work`; if it throws a `WebRejection`, that rejection is the answer.
    @MainActor
    static func catching(_ work: @MainActor () async throws -> HTTPResponse) async -> HTTPResponse {
        do {
            return try await work()
        } catch let rejection as WebRejection {
            return rejection.response
        } catch {
            return .error(500, error.localizedDescription)
        }
    }
}

/// The `input` and `output` fields that a request may carry, at least one of which must be there.
struct WebDirectionFields {
    let input: Any?
    let output: Any?

    /// - Throws: 400 with `message` when neither field was sent.
    init(_ body: [String: Any], orElse message: WebErrorStrings) throws {
        input = body["input"]
        output = body["output"]
        guard input != nil || output != nil else {
            throw WebRejection(400, message.rawValue)
        }
    }
}

enum WebRequestValidation {

    /// The JSON object in the body.
    ///
    /// - Throws: 415 unless the request says it is `application/json`. A body that is not a JSON
    ///   object counts as an empty one, so the caller's own "expected ..." message answers it.
    static func jsonBody(_ request: HTTPRequest) throws -> [String: Any] {
        guard let type = request.headers["Content-Type"],
              type.lowercased().hasPrefix("application/json")
        else { throw WebRejection(415, WebErrorStrings.WrongContentType.rawValue) }

        guard let object = try? JSONSerialization.jsonObject(with: request.body),
              let dictionary = object as? [String: Any]
        else { return [:] }

        return dictionary
    }

    /// A sample rate the device offers (matched tolerantly), returned as the device's own value.
    ///
    /// - Throws: 400 when it is not a positive number, 404 when the device does not offer it.
    static func rate(_ value: Any?, offered: [Double], direction: String) throws -> Double {
        guard let number = value as? NSNumber else {
            throw WebRejection(400, WebErrorStrings.rateMustBeHertz(direction: direction))
        }

        let requested = number.doubleValue
        guard requested.isFinite, requested > 0 else {
            throw WebRejection(400, WebErrorStrings.rateMustBePositive(direction: direction))
        }

        guard let match = offered.first(where: { AudioHost.ratesMatch($0, requested) }) else {
            throw WebRejection(404, offered.isEmpty
                ? WebErrorStrings.noRatesReported(direction: direction)
                : WebErrorStrings.rateNotOffered(requested, direction: direction, offered: offered))
        }

        return match
    }

    /// A whole number. A JSON boolean is not one.
    ///
    /// - Throws: 400 with the field's description.
    static func integer(_ value: Any?, named name: String, mustBe description: WebErrorStrings) throws -> Int {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw WebRejection(400, WebErrorStrings.fieldMustBe(name, description))
        }
        guard number.doubleValue.isFinite,
              let whole = Int(exactly: number.doubleValue) else {
            throw WebRejection(400, WebErrorStrings.fieldMustBe(name, description))
        }
        return whole
    }

    /// A 0-based channel number of a device with `available` channels.
    ///
    /// - Throws: 400 when it is not a whole number or is out of range, 409 when the device has no
    ///   channels at all (none selected).
    static func channel(_ value: Any?, named name: String, available: Int, direction: String) throws -> Int {
        let channel = try integer(value, named: name, mustBe: .ChannelDescriptionSuffix)
        guard available > 0 else {
            throw WebRejection(409, WebErrorStrings.noChannels(direction: direction))
        }
        guard (0..<available).contains(channel) else {
            throw WebRejection(400, WebErrorStrings.channelOutOfRange(name,
                                                                      available: available,
                                                                      direction: direction))
        }
        return channel
    }

    /// A JSON boolean. A number is not one.
    ///
    /// - Throws: 400.
    static func boolean(_ value: Any?, named name: String) throws -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw WebRejection(400, WebErrorStrings.mustBeBoolean(name))
        }
        return number.boolValue
    }
}
