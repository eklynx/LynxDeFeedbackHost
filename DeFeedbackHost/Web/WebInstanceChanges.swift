//
//  WebInstanceChanges.swift
//  DeFeedbackHost
//
//  The body of `PATCH /api/instances/{id}`: a sparse update where only the fields that were sent
//  change. Parsing checks every field before anything is applied, so a bad later field leaves the
//  instance untouched. Fields are checked in a fixed order (name, strength, muted, bypassed,
//  inputChannel, outputChannel), which decides which error a request with several mistakes gets.
//  Moved out of WebControlService.swift without changing behaviour (issue #41).
//
import Foundation

struct WebInstanceChanges {

    private(set) var name: String?
    private(set) var strength: Int?
    private(set) var muted: Bool?
    private(set) var bypassed: Bool?
    private(set) var inputChannel: Int?
    private(set) var outputChannel: Int?

    static let fieldNames = ["name", "strength", "muted", "bypassed", "inputChannel", "outputChannel"]

    /// - Throws: a `WebRejection` for the first field that is wrong, or 400 when no known field was sent.
    @MainActor
    init(body: [String: Any], instance: PluginInstance, host: AudioHost) throws {
        guard Self.fieldNames.contains(where: { body[$0] != nil }) else {
            throw WebRejection(400, WebErrorStrings.ExpectedSomeSetting.rawValue)
        }

        if let raw = body["name"] {
            name = try Self.checkedName(raw, for: instance, in: host)
        }
        if let raw = body["strength"] {
            strength = try Self.checkedStrength(raw, of: instance)
        }
        if let raw = body["muted"] {
            muted = try WebRequestValidation.boolean(raw, named: "muted")
        }
        if let raw = body["bypassed"] {
            bypassed = try WebRequestValidation.boolean(raw, named: "bypassed")
        }
        if let raw = body["inputChannel"] {
            inputChannel = try WebRequestValidation.channel(raw, named: "inputChannel",
                                                            available: host.inputChannelCount,
                                                            direction: "input")
        }
        if let raw = body["outputChannel"] {
            outputChannel = try WebRequestValidation.channel(raw, named: "outputChannel",
                                                             available: host.outputChannelCount,
                                                             direction: "output")
        }
    }

    /// Applies the fields that were sent.
    @MainActor
    func apply(to instance: PluginInstance, in host: AudioHost) {
        if let name { host.rename(instance, to: name) }
        if let strength { instance.setStrengthPercent(strength) }
        if let muted { instance.isMuted = muted }
        if let bypassed { instance.isBypassed = bypassed }
        if let inputChannel { instance.inputChannel = inputChannel }
        if let outputChannel { instance.outputChannel = outputChannel }
    }

    @MainActor
    private static func checkedName(_ raw: Any, for instance: PluginInstance, in host: AudioHost) throws -> String {
        guard let proposed = raw as? String else {
            throw WebRejection(400, WebErrorStrings.NameMustBeString.rawValue)
        }
        if let error = host.validateName(proposed, for: instance) {
            // A clash with another instance is a conflict; anything else is a malformed name.
            if case .duplicate = error {
                throw WebRejection(409, error.localizedDescription)
            }
            throw WebRejection(400, error.localizedDescription)
        }
        return proposed
    }

    /// Checked before the value is even read, so a plugin with no Strength gives the same answer
    /// whatever number was sent.
    @MainActor
    private static func checkedStrength(_ raw: Any, of instance: PluginInstance) throws -> Int {
        guard instance.publishesStrength else {
            throw WebRejection(409, WebErrorStrings.noStrengthParameter(instance.displayName))
        }
        let percent = try WebRequestValidation.integer(raw, named: "strength",
                                                       mustBe: .StrengthDescriptionSuffix)
        guard (0...100).contains(percent) else {
            throw WebRejection(400, WebErrorStrings.strengthOutOfRange(percent))
        }
        return percent
    }
}
