//
//  SettingsStore.swift
//  DeFeedbackHost
//

import AudioToolbox
import Foundation
import Synchronization

struct PluginIdentity: Codable, Equatable {

    var type: OSType
    var subType: OSType
    var manufacturer: OSType

    static var configured: PluginIdentity {
        PluginIdentity(type: PluginConfiguration.componentType,
                       subType: PluginConfiguration.componentSubType,
                       manufacturer: PluginConfiguration.componentManufacturer)
    }
}

struct HostSettings: Codable, Equatable {

    var pluginIdentity: PluginIdentity?

    var bufferSize = PluginConfiguration.defaultBufferSize

    var inputDeviceUID: String?
    var outputDeviceUID: String?

    var inputDeviceName: String?
    var outputDeviceName: String?

    var inputSampleRate: Double?
    var outputSampleRate: Double?

    var parallelRendering = false

    var autoRunOnStartup = false

    var newInstancesStartMuted = false
    var newInstancesStartBypassed = false

    var selectedInstanceIndex = 0
    var instances: [InstanceSettings] = []

    var webServer = WebServerSettings()

}

extension HostSettings {

    /// The five settings stored as individual UserDefaults keys (see `HostPreferences`).
    var preferences: HostPreferences {
        get {
            HostPreferences(autoRunOnStartup: autoRunOnStartup,
                            newInstancesStartMuted: newInstancesStartMuted,
                            newInstancesStartBypassed: newInstancesStartBypassed,
                            parallelRendering: parallelRendering,
                            bufferSize: bufferSize)
        }
        set {
            autoRunOnStartup = newValue.autoRunOnStartup
            newInstancesStartMuted = newValue.newInstancesStartMuted
            newInstancesStartBypassed = newValue.newInstancesStartBypassed
            parallelRendering = newValue.parallelRendering
            bufferSize = newValue.bufferSize
        }
    }

    private enum CodingKeys: String, CodingKey {
        case pluginIdentity, bufferSize
        case inputDeviceUID, outputDeviceUID, inputDeviceName, outputDeviceName
        case inputSampleRate, outputSampleRate
        case parallelRendering, autoRunOnStartup, newInstancesStartMuted, newInstancesStartBypassed
        case selectedInstanceIndex, instances, webServer
    }

    /// Writes everything EXCEPT the individual-key preferences: those live in their own keys, and
    /// keeping a second copy in the blob would let the two disagree. Old blobs that still contain
    /// them are read by `init(from:)` so they can be migrated.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(pluginIdentity, forKey: .pluginIdentity)
        try container.encodeIfPresent(inputDeviceUID, forKey: .inputDeviceUID)
        try container.encodeIfPresent(outputDeviceUID, forKey: .outputDeviceUID)
        try container.encodeIfPresent(inputDeviceName, forKey: .inputDeviceName)
        try container.encodeIfPresent(outputDeviceName, forKey: .outputDeviceName)
        try container.encodeIfPresent(inputSampleRate, forKey: .inputSampleRate)
        try container.encodeIfPresent(outputSampleRate, forKey: .outputSampleRate)
        try container.encode(selectedInstanceIndex, forKey: .selectedInstanceIndex)
        try container.encode(instances, forKey: .instances)
        try container.encode(webServer, forKey: .webServer)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, default fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }

        pluginIdentity = try container.decodeIfPresent(PluginIdentity.self, forKey: .pluginIdentity)
        bufferSize = try value(.bufferSize, default: PluginConfiguration.defaultBufferSize)
        inputDeviceUID = try container.decodeIfPresent(String.self, forKey: .inputDeviceUID)
        outputDeviceUID = try container.decodeIfPresent(String.self, forKey: .outputDeviceUID)
        inputDeviceName = try container.decodeIfPresent(String.self, forKey: .inputDeviceName)
        outputDeviceName = try container.decodeIfPresent(String.self, forKey: .outputDeviceName)
        inputSampleRate = try container.decodeIfPresent(Double.self, forKey: .inputSampleRate)
        outputSampleRate = try container.decodeIfPresent(Double.self, forKey: .outputSampleRate)
        parallelRendering = try value(.parallelRendering, default: false)
        autoRunOnStartup = try value(.autoRunOnStartup, default: false)
        newInstancesStartMuted = try value(.newInstancesStartMuted, default: false)
        newInstancesStartBypassed = try value(.newInstancesStartBypassed, default: false)
        selectedInstanceIndex = try value(.selectedInstanceIndex, default: 0)
        instances = try value(.instances, default: [])
        webServer = try value(.webServer, default: WebServerSettings())
    }
}

struct WebServerSettings: Codable, Equatable {

    var isEnabled = false

    var port = 8787

    static let portRange = 1_024...65_535

    var requiresAuthentication = false

    var unauthedLocalhostAllowed = true

    var username = ""
    // Password is stored in keychain

    var isAuthenticationComplete: Bool {
        !requiresAuthentication || !username.isEmpty
    }
}

extension WebServerSettings {

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, default fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }

        isEnabled = try value(.isEnabled, default: false)
        port = try value(.port, default: 8787)
        requiresAuthentication = try value(.requiresAuthentication, default: false)
        unauthedLocalhostAllowed = try value(.unauthedLocalhostAllowed, default: true)
        username = try value(.username, default: "")
    }
}

struct InstanceSettings: Codable, Equatable {

    var name: String?

    var inputChannel = 0
    var outputChannel = 0
    var isBypassed = false
    var isMuted = false

    var pluginState: Data?

    var parameterValues: [String: Float]?
}

enum PluginStateCoding {

    static func data(from state: [String: Any]?) -> Data? {
        guard let state, !state.isEmpty else { return nil }
        return try? PropertyListSerialization.data(
            fromPropertyList: state, format: .binary, options: 0)
    }

    static func state(from data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil)
        return plist as? [String: Any]
    }
}

/// The settings that are individual UserDefaults keys, so they can be read and set from the CLI:
///
///     defaults read   com.eklynx.sound.DeFeedbackHost Host.bufferSize
///     defaults write  com.eklynx.sound.DeFeedbackHost Host.bufferSize -int 128
///     defaults write  com.eklynx.sound.DeFeedbackHost Host.autoRunOnStartup -bool true
///     defaults delete com.eklynx.sound.DeFeedbackHost Host.autoRunOnStartup   # re-created with the app's value
///
/// Bools accept `-bool`, 0/1, or the strings true/false/yes/no. A missing or invalid value is
/// ignored (never an error), so a typo can't stop the app starting. Everything else stays in the
/// `HostSettings` blob. A running app picks up changes live (`AudioHost.applyExternalPreferences`).
struct HostPreferences: Equatable {

    var autoRunOnStartup = false
    var newInstancesStartMuted = false
    var newInstancesStartBypassed = false
    var parallelRendering = false
    var bufferSize = PluginConfiguration.defaultBufferSize

    enum Key {
        static let autoRunOnStartup = "Host.autoRunOnStartup"
        static let newInstancesStartMuted = "Host.newInstancesStartMuted"
        static let newInstancesStartBypassed = "Host.newInstancesStartBypassed"
        static let parallelRendering = "Host.parallelRendering"
        static let bufferSize = "Host.bufferSize"

        static let all = [autoRunOnStartup, newInstancesStartMuted, newInstancesStartBypassed,
                          parallelRendering, bufferSize]
    }

    /// Values from `defaults`, using `fallback` for any key that is absent or invalid.
    static func read(from defaults: UserDefaults, fallback: HostPreferences) -> HostPreferences {
        var result = fallback
        if let value = bool(Key.autoRunOnStartup, in: defaults) { result.autoRunOnStartup = value }
        if let value = bool(Key.newInstancesStartMuted, in: defaults) { result.newInstancesStartMuted = value }
        if let value = bool(Key.newInstancesStartBypassed, in: defaults) { result.newInstancesStartBypassed = value }
        if let value = bool(Key.parallelRendering, in: defaults) { result.parallelRendering = value }
        if let value = int(Key.bufferSize, in: defaults), PluginConfiguration.validBufferSizes.contains(value) {
            result.bufferSize = value
        }
        return result
    }

    /// Writes every key whose value differs from `previous` (all of them when `previous` is nil).
    /// Unchanged keys are left alone so an in-app save never overwrites a CLI edit it hasn't seen.
    func write(to defaults: UserDefaults, changedFrom previous: HostPreferences?) {
        func put<T: Equatable>(_ value: T, _ old: T?, _ key: String) {
            if old == nil || old != value { defaults.set(value, forKey: key) }
        }
        put(autoRunOnStartup, previous?.autoRunOnStartup, Key.autoRunOnStartup)
        put(newInstancesStartMuted, previous?.newInstancesStartMuted, Key.newInstancesStartMuted)
        put(newInstancesStartBypassed, previous?.newInstancesStartBypassed, Key.newInstancesStartBypassed)
        put(parallelRendering, previous?.parallelRendering, Key.parallelRendering)
        put(bufferSize, previous?.bufferSize, Key.bufferSize)
    }

    private static func bool(_ key: String, in defaults: UserDefaults) -> Bool? {
        switch defaults.object(forKey: key) {
        case let number as NSNumber:
            return number.boolValue
        case let text as String:
            switch text.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default:
            return nil
        }
    }

    private static func int(_ key: String, in defaults: UserDefaults) -> Int? {
        switch defaults.object(forKey: key) {
        case let number as NSNumber: return number.intValue
        case let text as String: return Int(text)
        default: return nil
        }
    }
}

enum SettingsStore {

    static let defaultsKey = "HostSettings"

    static func load(from defaults: UserDefaults = .standard) -> HostSettings {
        var settings = HostSettings()
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(HostSettings.self, from: data) {
            settings = decoded

            if settings.pluginIdentity != .configured {
                for index in settings.instances.indices {
                    settings.instances[index].pluginState = nil
                    settings.instances[index].parameterValues = nil
                }
                settings.pluginIdentity = .configured
            }
        }

        // `settings` now holds the legacy blob values (or defaults). Individual keys win; any key that
        // doesn't exist yet is created from that value, which migrates old installs and makes every
        // key discoverable with `defaults read`.
        let legacy = settings.preferences
        settings.preferences = HostPreferences.read(from: defaults, fallback: legacy)
        let missing = HostPreferences.Key.all.filter { defaults.object(forKey: $0) == nil }
        if !missing.isEmpty {
            settings.preferences.write(to: defaults, changedFrom: nil)
        }

        return settings
    }

    /// - Parameter previous: what was last saved. Individual-key preferences are only written when
    ///   they differ from it, so saving never clobbers a CLI edit the app hasn't applied yet.
    static func save(_ settings: HostSettings, previous: HostSettings? = nil, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: defaultsKey)
        settings.preferences.write(to: defaults, changedFrom: previous?.preferences)
    }

    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
        HostPreferences.Key.all.forEach { defaults.removeObject(forKey: $0) }
    }
}

nonisolated final class SettingsChangeFlag: @unchecked Sendable {

    private let dirty = Atomic<Bool>(false)

    func markDirty() {
        dirty.store(true, ordering: .relaxed)
    }

    /// Returns if anything has changed since the last call and clears the flag.
    func consume() -> Bool {
        dirty.exchange(false, ordering: .relaxed)
    }
}
