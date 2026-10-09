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

enum SettingsStore {

    static let defaultsKey = "HostSettings"

    static func load(from defaults: UserDefaults = .standard) -> HostSettings {
        guard let data = defaults.data(forKey: defaultsKey) else { return HostSettings() }
        guard var settings = try? JSONDecoder().decode(HostSettings.self, from: data) else {
            return HostSettings()
        }

        if settings.pluginIdentity != .configured {
            for index in settings.instances.indices {
                settings.instances[index].pluginState = nil
                settings.instances[index].parameterValues = nil
            }
            settings.pluginIdentity = .configured
        }

        return settings
    }

    static func save(_ settings: HostSettings, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
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
