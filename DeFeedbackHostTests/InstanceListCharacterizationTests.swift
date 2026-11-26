//
//  InstanceListCharacterizationTests.swift
//  DeFeedbackHostTests
//
//  Pins the parts of the host's instance list that `WebInstanceListTests` doesn't: what a new
//  instance starts with, the refusal messages, paging and which instance stays selected. Written
//  before the list moved out of `AudioHost` (issue #41) so the move can be shown to change nothing.
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import Foundation
import Testing

@testable import DeFeedbackHost

@MainActor
private func makeHost(pluginInstalled: Bool = true,
                      inputChannels: Int = 4,
                      outputChannels: Int = 6) -> AudioHost {
    let suite = "DeFeedbackHostTests.\(UUID().uuidString)"
    let host = AudioHost(defaults: UserDefaults(suiteName: suite)!, pluginInstalled: pluginInstalled)
    host.setHardwareForTesting(
        inputDevices: [AudioDevice(id: 101, name: "Mic", uid: "in-a",
                                   inputChannelCount: inputChannels, outputChannelCount: 0)],
        outputDevices: [AudioDevice(id: 202, name: "Speakers", uid: "out-a",
                                    inputChannelCount: 0, outputChannelCount: outputChannels)],
        inputSampleRates: [48000], outputSampleRates: [48000])
    host.selectedInputDeviceUID = "in-a"
    host.selectedOutputDeviceUID = "out-a"
    return host
}

@MainActor
struct InstanceListCharacterizationTests {

    // MARK: - Adding

    @Test func newInstancesGetNumberedNamesAndBecomeTheSelectedOne() async {
        let host = makeHost()
        let first = await host.addInstance()
        let second = await host.addInstance()

        #expect(first?.name == "Instance 1")
        #expect(second?.name == "Instance 2")
        #expect(host.instances.count == 2)
        #expect(host.selectedInstanceIndex == 1)
        #expect(host.selectedInstance === second)
    }

    @Test func aNewInstanceTakesTheNextChannelUpToTheDeviceLimit() async {
        let host = makeHost(inputChannels: 2, outputChannels: 3)
        var added: [PluginInstance] = []
        for _ in 0..<4 { if let instance = await host.addInstance() { added.append(instance) } }

        #expect(added.map(\.inputChannel) == [0, 1, 1, 1])
        #expect(added.map(\.outputChannel) == [0, 1, 2, 2])
    }

    @Test func withoutDevicesNewInstancesStartOnChannelZero() async {
        let suite = "DeFeedbackHostTests.\(UUID().uuidString)"
        let host = AudioHost(defaults: UserDefaults(suiteName: suite)!, pluginInstalled: true)
        await host.addInstance()
        await host.addInstance()
        #expect(host.instances.map(\.inputChannel) == [0, 0])
        #expect(host.instances.map(\.outputChannel) == [0, 0])
    }

    @Test func addingWithoutThePluginIsRefusedWithAMessage() async {
        let host = makeHost(pluginInstalled: false)
        #expect(await host.addInstance() == nil)
        #expect(host.instances.isEmpty)
        #expect(host.errorMessage == AudioHostError.pluginNotInstalled.localizedDescription)
    }

    @Test func addingBeyondTheCapIsRefusedWithAMessage() async {
        let host = makeHost()
        for _ in 0..<PluginConfiguration.maximumInstanceCount { await host.addInstance() }
        #expect(host.instances.count == PluginConfiguration.maximumInstanceCount)
        #expect(host.canAddInstance == false)

        host.errorMessage = nil
        #expect(await host.addInstance() == nil)
        #expect(host.instances.count == PluginConfiguration.maximumInstanceCount)
        #expect(host.errorMessage == AudioHostError.maxInstancesReached.localizedDescription)
    }

    // MARK: - Selection and paging

    @Test func pagingStaysWithinTheList() async {
        let host = makeHost()
        for _ in 0..<3 { await host.addInstance() }
        #expect(host.selectedInstanceIndex == 2)
        #expect(host.canShowNextInstance == false)
        #expect(host.canShowPreviousInstance)

        host.showNextInstance()
        #expect(host.selectedInstanceIndex == 2)

        host.showPreviousInstance()
        host.showPreviousInstance()
        #expect(host.selectedInstanceIndex == 0)
        #expect(host.canShowPreviousInstance == false)

        host.showPreviousInstance()
        #expect(host.selectedInstanceIndex == 0)
    }

    @Test func anEmptyListHasNothingSelectedOrToPageTo() {
        let host = makeHost()
        #expect(host.selectedInstance == nil)
        #expect(host.canShowPreviousInstance == false)
        #expect(host.canShowNextInstance == false)
    }

    /// A quirk kept as it is: paging forward on an empty list leaves the index at -1. The window
    /// never offers the chevron then, so nothing reaches it; pinned so changing it is deliberate.
    @Test func pagingForwardOnAnEmptyListLeavesMinusOne() {
        let host = makeHost()
        host.showNextInstance()
        #expect(host.selectedInstanceIndex == -1)
    }

    @Test func removingBeforeTheSelectedInstanceKeepsTheSameOneSelected() async {
        let host = makeHost()
        for _ in 0..<3 { await host.addInstance() }
        let keep = host.instances[2]
        #expect(host.selectedInstance === keep)

        host.removeInstance(id: host.instances[0].id)
        #expect(host.selectedInstance === keep)
        #expect(host.selectedInstanceIndex == 1)
    }

    @Test func removingTheSelectedLastInstanceSelectsTheNewLastOne() async {
        let host = makeHost()
        for _ in 0..<3 { await host.addInstance() }
        host.removeSelectedInstance()
        #expect(host.instances.count == 2)
        #expect(host.selectedInstanceIndex == 1)

        host.removeSelectedInstance()
        host.removeSelectedInstance()
        #expect(host.instances.isEmpty)
        #expect(host.selectedInstanceIndex == 0)
        host.removeSelectedInstance() // nothing left: must not trap
    }

    @Test func aStaleSavedSelectionIsClampedOnRestore() async {
        let suite = "DeFeedbackHostTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var settings = HostSettings()
        settings.instances = [InstanceSettings(name: "A"), InstanceSettings(name: "B")]
        settings.selectedInstanceIndex = 9
        SettingsStore.save(settings, to: defaults)

        let host = AudioHost(defaults: defaults, pluginInstalled: true)
        await host.loadApplicationState()
        #expect(host.instances.map(\.name) == ["A", "B"])
        #expect(host.selectedInstanceIndex == 1)
    }

    // MARK: - Lookup

    @Test func lookupByNameIgnoresCase() async {
        let host = makeHost()
        let first = await host.addInstance()
        #expect(host.instance(named: "instance 1") === first)
        #expect(host.instance(named: "nope") == nil)
    }

    @Test func validatingAProposedNameNeverRenames() async {
        let host = makeHost()
        let first = await host.addInstance()
        await host.addInstance()
        let name = first?.name
        #expect(host.validateName("Instance 2", for: first!) == .duplicate("Instance 2"))
        #expect(host.validateName("Instance 1", for: first!) == nil, "its own name is fine")
        #expect(first?.name == name)
    }
}
