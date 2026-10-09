//
//  SettingsStoreTests.swift
//  DeFeedbackHostTests
//
//  Persistence round-tripping. Every test uses its own throwaway UserDefaults suite so the real
//  app's saved settings are never read or written.
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import Foundation
import Testing

@testable import DeFeedbackHost

/// An isolated defaults domain, removed when the test finishes.
private func withTemporaryDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let name = "DeFeedbackHostTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    try body(defaults)
}

struct SettingsStoreTests {

    @Test func loadingWithNothingSavedYieldsDefaults() {
        withTemporaryDefaults { defaults in
            let settings = SettingsStore.load(from: defaults)
            #expect(settings.bufferSize == PluginConfiguration.defaultBufferSize)
            #expect(settings.instances.isEmpty)
            #expect(settings.inputDeviceUID == nil)
            #expect(settings.selectedInstanceIndex == 0)
        }
    }

    @Test func settingsSurviveARoundTrip() {
        withTemporaryDefaults { defaults in
            var settings = HostSettings()
            settings.pluginIdentity = .configured
            settings.bufferSize = 64
            settings.inputDeviceUID = "SomeInputUID"
            settings.outputDeviceUID = "SomeOutputUID"
            settings.inputDeviceName = "Some Input"
            settings.outputDeviceName = "Some Output"
            settings.inputSampleRate = 88_200
            settings.outputSampleRate = 88_200
            settings.selectedInstanceIndex = 2
            settings.parallelRendering = true
            settings.autoRunOnStartup = true
            settings.newInstancesStartMuted = true
            settings.newInstancesStartBypassed = true
            settings.instances = [
                InstanceSettings(inputChannel: 0, outputChannel: 1,
                                 isBypassed: false, isMuted: true, pluginState: nil),
                InstanceSettings(inputChannel: 3, outputChannel: 7,
                                 isBypassed: true, isMuted: false,
                                 pluginState: Data([0x01, 0x02])),
                InstanceSettings(),
            ]

            SettingsStore.save(settings, to: defaults)
            #expect(SettingsStore.load(from: defaults) == settings)
        }
    }

    /// Adding a non-optional field to `HostSettings` is a trap: synthesised decoding treats a
    /// missing key as an error, and `load` turns any decode error into "no saved settings" — so
    /// a new field would wipe every existing user's session on upgrade. `HostSettings` decodes
    /// key by key to avoid that, and this is what stops someone quietly deleting it.
    @Test func aSessionSavedBeforeAFieldExistedStillLoads() {
        withTemporaryDefaults { defaults in
            // Exactly the shape the previous build wrote: no `parallelRendering` key.
            let legacy = """
                {"bufferSize":64,"selectedInstanceIndex":1,\
                "instances":[{"inputChannel":0,"outputChannel":1,\
                "isBypassed":false,"isMuted":true}]}
                """
            defaults.set(Data(legacy.utf8), forKey: SettingsStore.defaultsKey)

            let settings = SettingsStore.load(from: defaults)
            #expect(settings.bufferSize == 64, "the old session must survive, not reset")
            #expect(settings.selectedInstanceIndex == 1)
            #expect(settings.instances.count == 1)
            #expect(settings.instances.first?.isMuted == true)
            #expect(settings.parallelRendering == false, "a new field takes its default")
            #expect(settings.webServer == WebServerSettings(),
                    "the web endpoint must be off for a session that predates it")

            // These three decide what launching the app *does*, so a session that predates them
            // has to come back behaving exactly as it did — stopped, and adding plain instances.
            #expect(settings.autoRunOnStartup == false,
                    "an upgrade must not start the host by itself")
            #expect(settings.newInstancesStartMuted == false)
            #expect(settings.newInstancesStartBypassed == false)

            // The device names are the newest such field. A session that predates them has a UID
            // and no name, which is a state the menus have to cope with rather than a decode
            // failure that would take the whole session with it.
            #expect(settings.inputDeviceName == nil)
            #expect(settings.outputDeviceName == nil)
        }
    }

    /// A UID with no name is what every session saved before this feature looks like, and the
    /// host has to be able to name that device somehow — it falls back to the UID.
    @Test func aRememberedDeviceWithNoSavedNameFallsBackToItsUID() {
        withTemporaryDefaults { defaults in
            let legacy = """
                {"bufferSize":128,"inputDeviceUID":"AppleUSBAudioEngine:Absent:1,2"}
                """
            defaults.set(Data(legacy.utf8), forKey: SettingsStore.defaultsKey)

            let settings = SettingsStore.load(from: defaults)
            #expect(settings.inputDeviceUID == "AppleUSBAudioEngine:Absent:1,2")
            #expect(settings.inputDeviceName == nil)
        }
    }

    /// The web endpoint is the newest such field, so it gets the same guarantee spelled out
    /// against a session that has everything *except* it.
    @Test func webServerSettingsSurviveARoundTrip() {
        withTemporaryDefaults { defaults in
            var settings = HostSettings()
            settings.pluginIdentity = .configured
            settings.webServer.isEnabled = true
            settings.webServer.port = 9123
            settings.webServer.requiresAuthentication = true
            settings.webServer.username = "edgars"

            SettingsStore.save(settings, to: defaults)
            #expect(SettingsStore.load(from: defaults).webServer == settings.webServer)
        }
    }

    /// A half-written `webServer` object must not take the rest of the session down with it.
    @Test func aPartialWebServerObjectDoesNotFailTheWholeLoad() {
        withTemporaryDefaults { defaults in
            let legacy = """
                {"bufferSize":128,"webServer":{"isEnabled":true}}
                """
            defaults.set(Data(legacy.utf8), forKey: SettingsStore.defaultsKey)

            let settings = SettingsStore.load(from: defaults)
            #expect(settings.bufferSize == 128)
            #expect(settings.webServer.isEnabled)
            #expect(settings.webServer.port == WebServerSettings().port)
            #expect(settings.webServer.username == "")
        }
    }

    @Test func instanceCountIsPreserved() {
        withTemporaryDefaults { defaults in
            var settings = HostSettings()
            settings.instances = Array(repeating: InstanceSettings(), count: 7)
            SettingsStore.save(settings, to: defaults)

            #expect(SettingsStore.load(from: defaults).instances.count == 7)
        }
    }

    @Test func corruptDataFallsBackToDefaultsRatherThanThrowing() {
        withTemporaryDefaults { defaults in
            defaults.set(Data("not json".utf8), forKey: SettingsStore.defaultsKey)

            // A settings blob from an older build must never stop the app from opening.
            let settings = SettingsStore.load(from: defaults)
            #expect(settings == HostSettings())
        }
    }

    /// Switching `PluginConfiguration` must not hand the new plugin a state dictionary produced by
    /// the old one — but the host-level settings around it are plugin-agnostic and should survive.
    @Test func stateFromADifferentPluginIsDroppedButHostSettingsAreKept() {
        withTemporaryDefaults { defaults in
            var settings = HostSettings()
            settings.pluginIdentity = PluginIdentity(type: stringToOS4Char("aufx"),
                                                     subType: stringToOS4Char("nbeq"),
                                                     manufacturer: stringToOS4Char("appl"))
            settings.bufferSize = 256
            settings.selectedInstanceIndex = 1
            settings.instances = [
                InstanceSettings(inputChannel: 2, outputChannel: 3,
                                 isBypassed: true, isMuted: false,
                                 pluginState: Data([0xAA, 0xBB])),
                InstanceSettings(inputChannel: 1, outputChannel: 1,
                                 isBypassed: false, isMuted: true,
                                 pluginState: Data([0xCC])),
            ]
            SettingsStore.save(settings, to: defaults)

            let loaded = SettingsStore.load(from: defaults)

            #expect(loaded.instances.allSatisfy { $0.pluginState == nil },
                    "another plugin's state must not be handed to this one")
            #expect(loaded.pluginIdentity == .configured)

            // Everything that isn't plugin-specific is still there.
            #expect(loaded.bufferSize == 256)
            #expect(loaded.selectedInstanceIndex == 1)
            #expect(loaded.instances.count == 2)
            #expect(loaded.instances[0].inputChannel == 2)
            #expect(loaded.instances[0].outputChannel == 3)
            #expect(loaded.instances[0].isBypassed)
            #expect(loaded.instances[1].isMuted)
        }
    }

    @Test func stateFromTheConfiguredPluginIsPreserved() {
        withTemporaryDefaults { defaults in
            var settings = HostSettings()
            settings.pluginIdentity = .configured
            settings.instances = [
                InstanceSettings(pluginState: Data([0x01, 0x02, 0x03]),
                                 parameterValues: ["gain": 0.5, "mix": 0.25]),
            ]
            SettingsStore.save(settings, to: defaults)

            let loaded = SettingsStore.load(from: defaults)
            #expect(loaded.instances.first?.pluginState == Data([0x01, 0x02, 0x03]))
            #expect(loaded.instances.first?.parameterValues == ["gain": 0.5, "mix": 0.25])
        }
    }

    /// Parameter values are the authoritative record, so they have to survive alongside the opaque
    /// blob — a plugin that ignores `fullState` is restored entirely from these.
    @Test func parameterValuesRoundTripIndependentlyPerInstance() {
        withTemporaryDefaults { defaults in
            var settings = HostSettings()
            settings.pluginIdentity = .configured
            settings.instances = [
                InstanceSettings(parameterValues: ["2410041": 0.375, "1855960161": 0.38]),
                InstanceSettings(parameterValues: ["2410041": 0.8, "1855960161": 0.8]),
            ]
            SettingsStore.save(settings, to: defaults)

            let loaded = SettingsStore.load(from: defaults)
            #expect(loaded.instances.count == 2)
            #expect(loaded.instances[0].parameterValues?["2410041"] == 0.375)
            #expect(loaded.instances[1].parameterValues?["2410041"] == 0.8)
            #expect(loaded.instances[0].parameterValues != loaded.instances[1].parameterValues)
        }
    }

    @Test func parameterValuesFromADifferentPluginAreAlsoDropped() {
        withTemporaryDefaults { defaults in
            var settings = HostSettings()
            settings.pluginIdentity = PluginIdentity(type: stringToOS4Char("aufx"),
                                                     subType: stringToOS4Char("nbeq"),
                                                     manufacturer: stringToOS4Char("appl"))
            settings.instances = [InstanceSettings(parameterValues: ["someOtherPluginParam": 1])]
            SettingsStore.save(settings, to: defaults)

            #expect(SettingsStore.load(from: defaults).instances.first?.parameterValues == nil)
        }
    }

    /// Sessions written before the identity was tracked carry no tag, so their state can't be
    /// trusted to belong to the current plugin.
    @Test func untaggedLegacyStateIsDropped() {
        withTemporaryDefaults { defaults in
            var settings = HostSettings()
            settings.pluginIdentity = nil
            settings.bufferSize = 32
            settings.instances = [InstanceSettings(pluginState: Data([0xFF]))]
            SettingsStore.save(settings, to: defaults)

            let loaded = SettingsStore.load(from: defaults)
            #expect(loaded.instances.first?.pluginState == nil)
            #expect(loaded.bufferSize == 32)
        }
    }

    @Test func clearingRemovesTheSavedSettings() {
        withTemporaryDefaults { defaults in
            var settings = HostSettings()
            settings.bufferSize = 256
            SettingsStore.save(settings, to: defaults)
            #expect(SettingsStore.load(from: defaults).bufferSize == 256)

            SettingsStore.clear(from: defaults)
            #expect(SettingsStore.load(from: defaults) == HostSettings())
        }
    }
}

// MARK: - Plugin state

struct PluginStateCodingTests {

    @Test func plainDictionaryRoundTrips() throws {
        let state: [String: Any] = [
            "type": 1_635_083_896,
            "subtype": 1_852_797_234,
            "name": "Untitled",
            "version": 0,
        ]

        let data = try #require(PluginStateCoding.data(from: state))
        let restored = try #require(PluginStateCoding.state(from: data))

        #expect(restored["name"] as? String == "Untitled")
        #expect(restored["type"] as? Int == 1_635_083_896)
        #expect(restored.keys.count == state.keys.count)
    }

    /// Audio units nest arrays, data blobs and further dictionaries inside `fullState`, so the
    /// container has to carry all of it without the host knowing what any of it means.
    @Test func nestedPluginShapedStateRoundTrips() throws {
        let state: [String: Any] = [
            "name": "Preset",
            "data": Data([0xDE, 0xAD, 0xBE, 0xEF]),
            "params": [0.5, 1.0, -3.25] as [Double],
            "nested": ["enabled": true, "count": 3] as [String: Any],
        ]

        let data = try #require(PluginStateCoding.data(from: state))
        let restored = try #require(PluginStateCoding.state(from: data))

        #expect(restored["data"] as? Data == Data([0xDE, 0xAD, 0xBE, 0xEF]))
        #expect(restored["params"] as? [Double] == [0.5, 1.0, -3.25])
        #expect((restored["nested"] as? [String: Any])?["count"] as? Int == 3)
        #expect((restored["nested"] as? [String: Any])?["enabled"] as? Bool == true)
    }

    @Test func absentOrEmptyStateEncodesToNothing() {
        #expect(PluginStateCoding.data(from: nil) == nil)
        #expect(PluginStateCoding.data(from: [:]) == nil)
        #expect(PluginStateCoding.state(from: nil) == nil)
    }

    @Test func garbageDataDecodesToNilInsteadOfCrashing() {
        #expect(PluginStateCoding.state(from: Data([0x00, 0x01, 0x02, 0x03])) == nil)
    }

    /// The point of storing an opaque dictionary: a plugin whose parameter set changed between
    /// versions still gets a well-formed dictionary back, with unknown keys carried through and
    /// the plugin free to ignore what it no longer understands.
    @Test func keysTheHostDoesNotUnderstandArePreserved() throws {
        let state: [String: Any] = [
            "aParameterThisVersionDropped": 42,
            "aParameterThisVersionAdded": "new",
        ]

        let data = try #require(PluginStateCoding.data(from: state))
        let restored = try #require(PluginStateCoding.state(from: data))

        #expect(restored["aParameterThisVersionDropped"] as? Int == 42)
        #expect(restored["aParameterThisVersionAdded"] as? String == "new")
    }
}

// MARK: - Change flag

struct SettingsChangeFlagTests {

    @Test func startsCleanAndReportsASingleChangeOnce() {
        let flag = SettingsChangeFlag()
        #expect(flag.consume() == false)

        flag.markDirty()
        #expect(flag.consume() == true)
        #expect(flag.consume() == false, "consuming must clear the flag")
    }

    @Test func aBurstOfChangesCoalescesIntoOneSave() {
        let flag = SettingsChangeFlag()
        for _ in 0..<500 { flag.markDirty() }

        #expect(flag.consume() == true)
        #expect(flag.consume() == false)
    }

    @Test func marksFromConcurrentThreadsAreNotLost() async {
        let flag = SettingsChangeFlag()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { for _ in 0..<1_000 { flag.markDirty() } }
            }
        }

        #expect(flag.consume() == true)
    }
}
