//
//  DeFeedbackHostTests.swift
//  DeFeedbackHostTests
//
//  Created by Edgars Klepers on 9/16/26.
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import AudioToolbox
import Testing

@testable import DeFeedbackHost

// MARK: - Helpers

/// Builds a deinterleaved `AudioBufferList` over `channels` for the duration of `body`.
private func withBufferList<R>(_ channels: [[Float]],
                               _ body: (UnsafeMutableAudioBufferListPointer) -> R) -> R {
    let frameCount = channels.first?.count ?? 0
    let list = AudioBufferList.allocate(maximumBuffers: max(1, channels.count))
    var storage: [UnsafeMutablePointer<Float>] = []

    for (index, channel) in channels.enumerated() {
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(1, frameCount))
        pointer.initialize(repeating: 0, count: max(1, frameCount))
        for (offset, sample) in channel.enumerated() {
            pointer[offset] = sample
        }
        storage.append(pointer)
        list[index] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(frameCount * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(pointer))
    }

    defer {
        for pointer in storage {
            pointer.deinitialize(count: max(1, frameCount))
            pointer.deallocate()
        }
        free(list.unsafeMutablePointer)
    }

    return body(list)
}

/// Reads `frameCount` frames out of `ring`, returning the underrun flag and the per-channel data.
private func read(_ ring: RingBuffer, frameCount: Int) -> (filled: Bool, channels: [[Float]]) {
    let capacity = ring.channelCount * frameCount
    let destination = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
    destination.initialize(repeating: .nan, count: capacity)
    defer {
        destination.deinitialize(count: capacity)
        destination.deallocate()
    }

    let filled = ring.read(into: destination, stride: frameCount, frameCount: frameCount)
    let channels = (0..<ring.channelCount).map { channel in
        (0..<frameCount).map { destination[channel * frameCount + $0] }
    }
    return (filled, channels)
}

private func ramp(_ count: Int, offset: Float = 0) -> [Float] {
    (0..<count).map { Float($0) + offset }
}

// MARK: - Ring buffer

struct RingBufferTests {

    @Test func roundTripsEachChannelIndependently() {
        let ring = RingBuffer(channelCount: 2, capacityFrames: 64)
        let left = ramp(16)
        let right = ramp(16, offset: 100)

        withBufferList([left, right]) { ring.write($0, frameCount: 16) }

        let result = read(ring, frameCount: 16)
        #expect(result.filled)
        #expect(result.channels[0] == left)
        #expect(result.channels[1] == right)
        #expect(ring.framesAvailable == 0)
    }

    @Test func underrunYieldsSilenceAndReportsFailure() {
        let ring = RingBuffer(channelCount: 1, capacityFrames: 64)

        withBufferList([ramp(8)]) { ring.write($0, frameCount: 8) }

        // Ask for more than was written.
        let result = read(ring, frameCount: 16)
        #expect(result.filled == false)
        #expect(result.channels[0].allSatisfy { $0 == 0 })
        // A failed read must not consume anything.
        #expect(ring.framesAvailable == 8)
    }

    @Test func wrapsAroundAcrossManyCycles() {
        // Capacity deliberately not a multiple of the block size, so the wrap lands mid-block.
        let ring = RingBuffer(channelCount: 1, capacityFrames: 100)
        let block = 32

        for cycle in 0..<20 {
            let expected = ramp(block, offset: Float(cycle * block))
            withBufferList([expected]) { ring.write($0, frameCount: block) }

            let result = read(ring, frameCount: block)
            #expect(result.filled, "cycle \(cycle) underran")
            #expect(result.channels[0] == expected, "cycle \(cycle) returned wrong samples")
        }
    }

    @Test func overrunDropsOldestAndStaysWithinCapacity() {
        let ring = RingBuffer(channelCount: 1, capacityFrames: 64)

        // Write 96 frames with no reader: 32 frames past capacity.
        for cycle in 0..<3 {
            withBufferList([ramp(32, offset: Float(cycle * 32))]) {
                ring.write($0, frameCount: 32)
            }
        }

        #expect(ring.framesAvailable == 64)

        // The surviving window is the most recent 64 frames, i.e. 32..<96.
        let result = read(ring, frameCount: 64)
        #expect(result.filled)
        #expect(result.channels[0] == ramp(64, offset: 32))
    }

    @Test func primingMakesFramesAvailableWithoutRealAudio() {
        let ring = RingBuffer(channelCount: 2, capacityFrames: 128)
        ring.primeWithSilence(frameCount: 48)

        #expect(ring.framesAvailable == 48)

        let result = read(ring, frameCount: 48)
        #expect(result.filled)
        #expect(result.channels.allSatisfy { $0.allSatisfy { $0 == 0 } })
    }

    @Test func missingHardwareChannelsAreWrittenAsSilence() {
        // Ring expects 4 channels but the device only handed over 2.
        let ring = RingBuffer(channelCount: 4, capacityFrames: 64)
        withBufferList([ramp(8), ramp(8, offset: 50)]) { ring.write($0, frameCount: 8) }

        let result = read(ring, frameCount: 8)
        #expect(result.filled)
        #expect(result.channels[0] == ramp(8))
        #expect(result.channels[1] == ramp(8, offset: 50))
        #expect(result.channels[2].allSatisfy { $0 == 0 })
        #expect(result.channels[3].allSatisfy { $0 == 0 })
    }

    @Test func writesLargerThanCapacityAreRejectedRatherThanCorrupting() {
        let ring = RingBuffer(channelCount: 1, capacityFrames: 16)
        withBufferList([ramp(32)]) { ring.write($0, frameCount: 32) }
        #expect(ring.framesAvailable == 0)
    }
}

// MARK: - Device enumeration

struct AudioHardwareTests {

    @Test @MainActor func enumeratedDevicesAreConsistentWithTheirChannelCounts() {
        let devices = AudioHardware.allDevices()

        // Every device must report at least one direction, or it shouldn't be listed at all.
        for device in devices {
            #expect(device.inputChannelCount >= 0)
            #expect(device.outputChannelCount >= 0)
            #expect(!device.name.isEmpty)
            #expect(!device.uid.isEmpty)
        }

        // This is the filter the pickers rely on.
        let inputs = devices.filter { $0.inputChannelCount > 0 }
        let outputs = devices.filter { $0.outputChannelCount > 0 }
        #expect(inputs.allSatisfy { $0.inputChannelCount > 0 })
        #expect(outputs.allSatisfy { $0.outputChannelCount > 0 })
    }

    @Test @MainActor func defaultDevicesAppearInTheEnumeratedList() {
        let devices = AudioHardware.allDevices()

        // Skipped rather than failed on a machine with no audio hardware at all.
        if let defaultOutput = AudioHardware.defaultDeviceID(input: false) {
            #expect(devices.contains { $0.id == defaultOutput })
        }
        if let defaultInput = AudioHardware.defaultDeviceID(input: true) {
            #expect(devices.contains { $0.id == defaultInput })
        }
    }

    @Test @MainActor func availableSampleRatesAreUsableMenuContents() {
        for device in AudioHardware.allDevices() {
            let rates = AudioHardware.availableSampleRates(device.id)
            guard !rates.isEmpty else { continue }

            #expect(rates.allSatisfy { $0 > 0 }, "\(device.name) offered a non-positive rate")
            #expect(rates == rates.sorted(), "\(device.name) rates came back unsorted")
            #expect(Set(rates).count == rates.count, "\(device.name) rates contain duplicates")

            // A device's current rate should be selectable from its own menu, otherwise the
            // picker would have nothing valid to show on launch.
            if let current = AudioHardware.nominalSampleRate(device.id) {
                #expect(rates.contains { abs($0 - current) <= 0.5 },
                        "\(device.name) is at \(current) Hz but offers \(rates)")
            }
        }
    }

    @Test @MainActor func bufferFrameSizeRangeCoversAtLeastOneOfferedSize() throws {
        guard let output = AudioHardware.defaultDeviceID(input: false),
              let range = AudioHardware.bufferFrameSizeRange(output) else { return }

        #expect(range.lowerBound > 0)
        #expect(range.upperBound >= range.lowerBound)

        // If none of the sizes we offer are usable, the buffer picker is a lie.
        let usable = PluginConfiguration.validBufferSizes.filter { range.contains($0) }
        #expect(!usable.isEmpty,
                "device range \(range) excludes every offered size \(PluginConfiguration.validBufferSizes)")
    }

    @Test @MainActor func bufferSizeSupportAgreesWithTheReportedRange() {
        for device in AudioHardware.allDevices() {
            guard let range = AudioHardware.bufferFrameSizeRange(device.id) else {
                // No range reported means "assume anything goes", so nothing can be rejected.
                #expect(AudioHardware.supportsBufferFrameSize(64, on: device.id))
                continue
            }

            #expect(range.lowerBound > 0)
            #expect(AudioHardware.supportsBufferFrameSize(range.lowerBound, on: device.id))
            #expect(AudioHardware.supportsBufferFrameSize(range.upperBound, on: device.id))
            #expect(!AudioHardware.supportsBufferFrameSize(range.lowerBound - 1, on: device.id))
            #expect(!AudioHardware.supportsBufferFrameSize(range.upperBound + 1, on: device.id))
        }
    }
}

// MARK: - Buffer size gating
//
// Read-only with respect to hardware: these inspect device ranges and the host's gate, and never
// write a buffer size to a device. Only `startAudio()` does that.
//
// Each host is given a throwaway defaults suite, so `prepare()` can't read or overwrite the real
// app's saved session.

/// A host backed by an isolated defaults domain, torn down when the test finishes.
@MainActor
private func withTemporaryHost(_ body: (AudioHost) async throws -> Void) async rethrows {
    let name = "DeFeedbackHostTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    try await body(AudioHost(defaults: defaults))
}

struct BufferSizeGateTests {

    @Test @MainActor func gateMatchesTheCachedRangesForEveryOfferedSize() async {
        await withTemporaryHost { host in
            await host.loadApplicationState()

            guard let input = host.selectedInputDevice,
                  let output = host.selectedOutputDevice else { return }

            for size in PluginConfiguration.validBufferSizes {
                host.bufferSize = size

                var expected: [String] = []
                if let range = host.inputBufferSizeRange, !range.contains(size) {
                    expected.append(input.name)
                }
                if let range = host.outputBufferSizeRange, !range.contains(size) {
                    expected.append(output.name)
                }

                #expect(host.devicesRejectingBufferSize == expected,
                        "gate disagreed with the device ranges at \(size)")
            }
        }
    }

    @Test @MainActor func aSizeNoDeviceAcceptsBlocksStart() async {
        await withTemporaryHost { host in
            await host.loadApplicationState()

            guard host.selectedInputDevice != nil, host.selectedOutputDevice != nil,
                  host.inputBufferSizeRange != nil || host.outputBufferSizeRange != nil else {
                return
            }

            // 1 frame is below every real device's minimum.
            host.bufferSize = 1
            #expect(!host.devicesRejectingBufferSize.isEmpty)
            #expect(host.canStart == false, "an unusable buffer size must block Run")
        }
    }

    @Test @MainActor func theDefaultSizeIsUsableOnTheDefaultDevices() async {
        await withTemporaryHost { host in
            await host.loadApplicationState()

            guard host.selectedInputDevice != nil,
                  host.selectedOutputDevice != nil else { return }

            host.bufferSize = PluginConfiguration.defaultBufferSize
            #expect(host.devicesRejectingBufferSize.isEmpty,
                    "the app opens on this size, so the default devices should accept it")
        }
    }
}

// MARK: - Session restore

struct SessionRestoreTests {

    @Test @MainActor func aFreshHostOpensWithNoInstances() async {
        await withTemporaryHost { host in
            await host.loadApplicationState()
            #expect(host.instances.isEmpty)
            #expect(host.bufferSize == PluginConfiguration.defaultBufferSize)
        }
    }

    @Test @MainActor func bufferSizeAndInstanceCountComeBack() async {
        let name = "DeFeedbackHostTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        // First session: two instances on distinct channels and a non-default buffer size.
        do {
            let host = AudioHost(defaults: defaults)
            await host.loadApplicationState()
            guard host.outputChannelCount >= 2 else { return }

            host.bufferSize = 64
            await host.addInstance()
            await host.addInstance()
            guard host.instances.count == 2 else { return }

            host.instances[0].outputChannel = 0
            host.instances[1].outputChannel = 1
            host.instances[1].isMuted = true
            host.instances[0].isBypassed = true
            host.saveSettings()
        }

        // Second session: same defaults, fresh host.
        do {
            let host = AudioHost(defaults: defaults)
            await host.loadApplicationState()

            #expect(host.bufferSize == 64)
            #expect(host.instances.count == 2)
            #expect(host.instances.first?.outputChannel == 0)
            #expect(host.instances.first?.isBypassed == true)
            #expect(host.instances.last?.outputChannel == 1)
            #expect(host.instances.last?.isMuted == true)
        }
    }

    @Test @MainActor func aStaleBufferSizeIsIgnoredRatherThanRestored() async {
        let name = "DeFeedbackHostTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        // A value this build no longer offers, e.g. saved by an older version.
        var stale = HostSettings()
        stale.bufferSize = 2_048
        SettingsStore.save(stale, to: defaults)

        let host = AudioHost(defaults: defaults)
        await host.loadApplicationState()

        #expect(host.bufferSize == PluginConfiguration.defaultBufferSize,
                "an unoffered size must fall back rather than leaving the picker out of range")
    }

    @Test @MainActor func moreSavedInstancesThanTheCapAreTruncated() async {
        let name = "DeFeedbackHostTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        var settings = HostSettings()
        settings.instances = Array(repeating: InstanceSettings(),
                                   count: PluginConfiguration.maximumInstanceCount + 5)
        SettingsStore.save(settings, to: defaults)

        let host = AudioHost(defaults: defaults)
        await host.loadApplicationState()

        #expect(host.instances.count <= PluginConfiguration.maximumInstanceCount,
                "restoring must not exceed the realtime graph's slot table")
    }

    @Test @MainActor func startupAndNewInstanceDefaultsComeBack() async {
        let name = "DeFeedbackHostTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        // Saved directly rather than by toggling a first host, so `prepare()` on the host under
        // test is the only thing that could have set these — and `autoRunOnStartup` isn't left
        // on for a second host to act on.
        var settings = HostSettings()
        settings.newInstancesStartMuted = true
        settings.newInstancesStartBypassed = true
        SettingsStore.save(settings, to: defaults)

        let host = AudioHost(defaults: defaults)
        await host.loadApplicationState()

        #expect(host.newInstancesMuted)
        #expect(host.newInstancesBypassed)
        #expect(host.autoRunOnStartup == false)
        #expect(host.isRunning == false)
    }

    /// The defaults are for instances the host creates, so they have to be applied *after* the
    /// plugin loads — `PluginInstance.load()` ends by taking mute from the plugin's own parameter,
    /// which would otherwise overwrite a mute set before it.
    @Test @MainActor func aNewInstanceStartsMutedAndBypassedWhenAsked() async {
        await withTemporaryHost { host in
            await host.loadApplicationState()
            guard host.canAddInstance else { return }

            host.newInstancesMuted = true
            host.newInstancesBypassed = true

            guard let instance = await host.addInstance(),
                  instance.audioUnit != nil else { return }

            #expect(instance.isMuted, "a new instance must come up muted when the setting is on")
            #expect(instance.isBypassed)
        }
    }

    @Test @MainActor func aNewInstanceIsUnmutedAndActiveByDefault() async {
        await withTemporaryHost { host in
            await host.loadApplicationState()
            guard host.canAddInstance else { return }

            guard let instance = await host.addInstance(),
                  instance.audioUnit != nil else { return }

            #expect(instance.isMuted == false)
            #expect(instance.isBypassed == false)
        }
    }

    /// An auto-run that can't happen has to say so. Nobody pressed Run, so without a message the
    /// window shows a stopped host and no reason for it.
    @Test @MainActor func autoRunReportsWhyItCouldNotStart() async {
        let name = "DeFeedbackHostTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        var settings = HostSettings()
        settings.autoRunOnStartup = true
        SettingsStore.save(settings, to: defaults)

        // No plugin is the one blocker that can be forced without touching hardware.
        let host = AudioHost(defaults: defaults, pluginInstalled: false)
        await host.loadApplicationState()

        #expect(host.isRunning == false)
        #expect(host.errorMessage?.contains("Auto-run") == true,
                "a refused auto-run must name itself, not leave the window silent")
    }

    /// A device that isn't plugged in stays the chosen one.
    ///
    /// This is the case the feature exists for, and it used to do the opposite: the selection was
    /// replaced by the system default and the next autosave wrote that over the user's choice, so
    /// plugging the interface back in didn't bring the session back — it was gone.
    @Test @MainActor func aDeviceThatIsNotConnectedIsRememberedRatherThanReplaced() async {
        let name = "DeFeedbackHostTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        var settings = HostSettings()
        settings.inputDeviceUID = "a-device-that-does-not-exist"
        settings.inputDeviceName = "Studio Interface"
        settings.outputDeviceUID = "nor-does-this-one"
        settings.outputDeviceName = "Monitor Controller"
        SettingsStore.save(settings, to: defaults)

        let host = AudioHost(defaults: defaults)
        await host.loadApplicationState()

        #expect(host.selectedInputDeviceUID == "a-device-that-does-not-exist")
        #expect(host.selectedInputDevice == nil, "it isn't here, so nothing should resolve")
        #expect(host.selectedInputDeviceID == nil, "and it can't have an ID while it's gone")
        #expect(host.unavailableInputDevice?.name == "Studio Interface")
        #expect(host.unavailableOutputDevice?.name == "Monitor Controller")

        // Run is blocked, and the reason names the device rather than asking for a selection that
        // has already been made.
        #expect(host.canStart == false)
        #expect(host.startBlockedReason?.contains("Studio Interface") == true)
        #expect(host.startBlockedReason?.contains("connected") == true)
    }

    /// The remembered selection has to survive the autosave that follows it, or the memory only
    /// lasts as long as the session that noticed the device was missing.
    @Test @MainActor func anAbsentDeviceAndItsRateAreSavedAgainUnchanged() async {
        let name = "DeFeedbackHostTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        var settings = HostSettings()
        settings.inputDeviceUID = "absent-input"
        settings.inputDeviceName = "Studio Interface"
        settings.inputSampleRate = 96_000
        SettingsStore.save(settings, to: defaults)

        let host = AudioHost(defaults: defaults)
        await host.loadApplicationState()
        host.saveSettings()

        let saved = SettingsStore.load(from: defaults)
        #expect(saved.inputDeviceUID == "absent-input")
        #expect(saved.inputDeviceName == "Studio Interface")
        // The menu is empty while the device is away, so the selection is nil — writing that
        // over the saved rate would lose it, and the device would come back at whatever the
        // hardware happened to be sitting at.
        #expect(host.selectedInputSampleRate == nil)
        #expect(saved.inputSampleRate == 96_000)
    }

    /// Choosing a device that *is* here clears the remembered one, which is requirement 3: the
    /// absent device stays in the menu until something else is picked.
    @Test @MainActor func choosingAPresentDeviceClearsTheRememberedOne() async {
        let name = "DeFeedbackHostTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        var settings = HostSettings()
        settings.inputDeviceUID = "absent-input"
        settings.inputDeviceName = "Studio Interface"
        SettingsStore.save(settings, to: defaults)

        let host = AudioHost(defaults: defaults)
        await host.loadApplicationState()
        #expect(host.unavailableInputDevice != nil)

        guard let present = host.inputDevices.first else { return }
        host.selectedInputDeviceUID = present.uid

        #expect(host.unavailableInputDevice == nil)
        #expect(host.selectedInputDevice?.uid == present.uid)
        #expect(host.rememberedInputDeviceName == present.name)
    }

    /// Sessions saved before the device name was persisted are all UID and no name, and the menu
    /// still has to show something. Ugly, but it names the device rather than leaving an empty
    /// pair of parentheses.
    @Test @MainActor func aRememberedDeviceWithNoNameIsShownAsItsUID() async {
        let name = "DeFeedbackHostTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        var settings = HostSettings()
        settings.inputDeviceUID = "AppleUSBAudioEngine:Absent:1,2"
        SettingsStore.save(settings, to: defaults)

        let host = AudioHost(defaults: defaults)
        await host.loadApplicationState()

        #expect(host.unavailableInputDevice?.name == "AppleUSBAudioEngine:Absent:1,2")
    }

    /// An auto-run held up by hardware that isn't plugged in says it will happen later, because
    /// it will — the host arms itself and starts when the device appears.
    @Test @MainActor func autoRunWaitsForADeviceThatIsNotConnectedYet() async {
        let name = "DeFeedbackHostTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        var settings = HostSettings()
        settings.autoRunOnStartup = true
        settings.inputDeviceUID = "absent-input"
        settings.inputDeviceName = "Studio Interface"
        SettingsStore.save(settings, to: defaults)

        // Forced installed: with no plugin there'd be a second blocker, and the host deliberately
        // makes no promise it can't keep.
        let host = AudioHost(defaults: defaults, pluginInstalled: true)
        await host.loadApplicationState()

        #expect(host.isRunning == false)
        #expect(host.errorMessage?.contains("Studio Interface") == true)
        #expect(host.errorMessage?.contains("Restart will be attempted when all devices are back online") == true)
    }

    /// And the opposite: with no plugin registered, connecting the device would start nothing, so
    /// the host must not say it will.
    @Test @MainActor func autoRunPromisesNothingWhenThePluginIsAlsoMissing() async {
        let name = "DeFeedbackHostTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        var settings = HostSettings()
        settings.autoRunOnStartup = true
        settings.inputDeviceUID = "absent-input"
        settings.inputDeviceName = "Studio Interface"
        SettingsStore.save(settings, to: defaults)

        let host = AudioHost(defaults: defaults, pluginInstalled: false)
        await host.loadApplicationState()

        #expect(host.errorMessage?.contains("Auto-run") == true)
        #expect(host.errorMessage?.contains("as soon as the device is connected") != true,
                "a promise that can't come true is worse than none")
    }

    /// A routing saved against a bigger device comes back as it was saved. The engine leaves that
    /// link unwired — it feeds silence for an input channel it hasn't got and sums nothing for an
    /// output channel it hasn't got — and Run is not blocked by it.
    @Test @MainActor func aSavedChannelBeyondTheDeviceIsRestoredRatherThanClamped() async {
        let name = "DeFeedbackHostTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        var settings = HostSettings()
        settings.instances = [InstanceSettings(inputChannel: 99, outputChannel: 99)]
        SettingsStore.save(settings, to: defaults)

        let host = AudioHost(defaults: defaults)
        await host.loadApplicationState()

        guard let instance = host.instances.first else { return }
        #expect(instance.inputChannel == 99, "a saved routing must not be rewritten to fit")
        #expect(instance.outputChannel == 99)
        #expect(host.startBlockedReason?.localizedCaseInsensitiveContains("channel") != true,
                "an out-of-range channel must never be what blocks the start")
    }
}

// MARK: - Sample rate gating
//
// Pure functions, so these run without touching — or worse, reconfiguring — real hardware.

struct SampleRateGateTests {

    @Test func matchingRequiresBothRatesToBeKnown() {
        #expect(AudioHost.ratesMatch(nil, nil) == false)
        #expect(AudioHost.ratesMatch(48_000, nil) == false)
        #expect(AudioHost.ratesMatch(nil, 48_000) == false)
    }

    @Test func equalRatesMatchAndUnequalRatesDoNot() {
        #expect(AudioHost.ratesMatch(48_000, 48_000))
        #expect(AudioHost.ratesMatch(44_100, 44_100))
        #expect(AudioHost.ratesMatch(44_100, 48_000) == false)
        #expect(AudioHost.ratesMatch(48_000, 96_000) == false)

        // Adjacent standard rates must never be conflated, however close.
        #expect(AudioHost.ratesMatch(88_200, 96_000) == false)
    }

    @Test func ratesWithinHALRoundTripToleranceStillMatch() {
        // The HAL hands back Doubles that have been through a device round trip; a fraction of a
        // hertz apart is the same rate, not a mismatch that should block Run.
        #expect(AudioHost.ratesMatch(48_000, 48_000.4))
        #expect(AudioHost.ratesMatch(44_100, 44_099.7))
        #expect(AudioHost.ratesMatch(48_000, 48_001) == false)
    }

    @Test func menuSelectionPrefersTheDevicesCurrentRate() {
        let rates: [Double] = [44_100, 48_000, 88_200, 96_000]
        #expect(AudioHost.menuSelection(forCurrent: 88_200, from: rates) == 88_200)
        #expect(AudioHost.menuSelection(forCurrent: 44_100, from: rates) == 44_100)
    }

    @Test func menuSelectionReportsTheHardwareEvenWhenItIsNotOffered() {
        // Better to show an unlisted truth than to claim the device is at a rate it isn't.
        #expect(AudioHost.menuSelection(forCurrent: 64_000, from: [44_100, 48_000]) == 64_000)
    }

    @Test func menuSelectionFallsBackToTheFirstRateWhenTheDeviceIsSilentAboutIts() {
        #expect(AudioHost.menuSelection(forCurrent: nil, from: [44_100, 48_000]) == 44_100)
        #expect(AudioHost.menuSelection(forCurrent: nil, from: []) == nil)
    }
}
