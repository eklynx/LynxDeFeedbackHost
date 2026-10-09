//
//  RealtimeGraphTests.swift
//  DeFeedbackHostTests
//
//  Exercises the render path — channel routing, summing, mute, bypass, load reporting — with no
//  audio hardware and no microphone consent, by driving the C++ engine through `RealtimeGraph`.
//
//  The engine renders plugins with `AudioUnitRender`, so a stand-in can't be a fake audio unit.
//  Instead the engine takes a host-side render *function* (`DFHRenderFunction`), and `StandInPlugin`
//  below uses it to imitate a real unit closely — including pulling its input through the engine's
//  own per-slot input callback, which is what keeps the copy-into-the-provided-buffer convention
//  under test.
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import AudioToolbox
import Testing

@testable import DeFeedbackHost

// MARK: - Stand-in plugin

/// One configurable stand-in, rather than three near-identical doubles.
private final class StandInPlugin: @unchecked Sendable {

    var callCount = 0

    /// Multiplies the pulled input. Ignored when `sentinel` is set.
    var gain: Float = 1

    /// When set, writes this constant and never pulls input — so "did the plugin run" is
    /// unambiguous even when its input would be silent.
    var sentinel: Float?

    /// When set, renders here and points the host's buffer list at it, imitating a unit whose
    /// output bus allocates its own buffer.
    var ownOutputBuffer: UnsafeMutablePointer<Float>?

    /// When true, writes nothing at all, imitating a unit that claims to own its output buffer and
    /// then supplies none.
    var writesNothing = false

    /// Set by the test so the stand-in can pull exactly as its plugin would.
    var slot: CoreAudioEngineControl.Slot?

    /// Its own input buffer, as a real unit has (`shouldAllocateBuffer` defaults to true).
    let inputBuffer: UnsafeMutablePointer<Float>

    init(capacity: Int = 1024) {
        inputBuffer = .allocate(capacity: capacity)
        inputBuffer.initialize(repeating: 0, count: capacity)
    }

    deinit {
        inputBuffer.deallocate()
    }

    var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }
}

private let standInRender: DFHRenderFunction = { context, _, _, frameCount, output in
    guard let context else { return kAudioUnitErr_NoConnection }
    let plugin = Unmanaged<StandInPlugin>.fromOpaque(context).takeUnretainedValue()
    plugin.callCount += 1

    let count = Int(frameCount)
    let outputList = UnsafeMutableAudioBufferListPointer(output)

    if plugin.writesNothing { return noErr }

    if let sentinel = plugin.sentinel {
        for index in 0..<outputList.count {
            guard let destination = outputList[index].mData?
                .assumingMemoryBound(to: Float.self) else { continue }
            destination.update(repeating: sentinel, count: count)
        }
        return noErr
    }

    // Pull input the way a real unit does: hand the host a non-nil buffer of our own, zeroed
    // first, then read *our* buffer afterwards rather than following a pointer the host may have
    // substituted. A host that only rewrote the pointer would read silence here
    guard let slot = plugin.slot else { return kAudioUnitErr_NoConnection }
    plugin.inputBuffer.update(repeating: 0, count: count)

    let inputList = AudioBufferList.allocate(maximumBuffers: 1)
    defer { free(inputList.unsafeMutablePointer) }
    inputList[0] = AudioBuffer(mNumberChannels: 1,
                               mDataByteSize: UInt32(count * MemoryLayout<Float>.size),
                               mData: UnsafeMutableRawPointer(plugin.inputBuffer))
    guard slot.pullInput(frameCount: count, into: inputList) == noErr else {
        return kAudioUnitErr_NoConnection
    }

    let source = plugin.inputBuffer
    if let own = plugin.ownOutputBuffer {
        for frame in 0..<count { own[frame] = source[frame] * plugin.gain }
        for index in 0..<outputList.count {
            outputList[index].mNumberChannels = 1
            outputList[index].mDataByteSize = UInt32(count * MemoryLayout<Float>.size)
            outputList[index].mData = UnsafeMutableRawPointer(own)
        }
        return noErr
    }

    for index in 0..<outputList.count {
        guard let destination = outputList[index].mData?
            .assumingMemoryBound(to: Float.self) else { continue }
        for frame in 0..<count { destination[frame] = source[frame] * plugin.gain }
    }
    return noErr
}

// MARK: - Harness

/// Allocates device-style output buffers, renders one cycle, and returns the per-channel result.
private func renderCycle(_ graph: CoreAudioEngineControl,
                         channelCount: Int,
                         frameCount: Int) -> [[Float]] {
    let list = AudioBufferList.allocate(maximumBuffers: channelCount)
    var storage: [UnsafeMutablePointer<Float>] = []

    for channel in 0..<channelCount {
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        pointer.initialize(repeating: .nan, count: frameCount)
        storage.append(pointer)
        list[channel] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(frameCount * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(pointer))
    }

    defer {
        for pointer in storage {
            pointer.deinitialize(count: frameCount)
            pointer.deallocate()
        }
        free(list.unsafeMutablePointer)
    }

    var timestamp = AudioTimeStamp()
    _ = graph.render(timestamp: &timestamp, frameCount: UInt32(frameCount), output: list)

    return storage.map { pointer in (0..<frameCount).map { pointer[$0] } }
}

/// Pushes one block of input, where channel `c` is filled with the constant `values[c]`.
private func feedInput(_ graph: CoreAudioEngineControl, values: [Float], frameCount: Int) {
    let list = AudioBufferList.allocate(maximumBuffers: max(1, values.count))
    var storage: [UnsafeMutablePointer<Float>] = []

    for (index, value) in values.enumerated() {
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        pointer.initialize(repeating: value, count: frameCount)
        storage.append(pointer)
        list[index] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(frameCount * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(pointer))
    }

    defer {
        for pointer in storage {
            pointer.deinitialize(count: frameCount)
            pointer.deallocate()
        }
        free(list.unsafeMutablePointer)
    }

    graph.writeInput(list, frameCount: frameCount)
}

// MARK: - Tests

struct RealtimeGraphTests {

    private let frames = 64

    private func makeGraph(inputChannels: Int,
                           outputChannels: Int,
                           frames: Int,
                           sampleRate: Double = 48_000) throws -> CoreAudioEngineControl {
        try #require(CoreAudioEngineControl(maximumFrameCount: frames,
                                   inputChannelCount: inputChannels,
                                   outputChannelCount: outputChannels,
                                   sampleRate: sampleRate))
    }

    /// Installs a stand-in and wires it to its slot so it can pull like a real unit.
    private func install(_ plugin: StandInPlugin,
                         into graph: CoreAudioEngineControl,
                         inputChannel: Int = 0,
                         outputChannel: Int = 0,
                         busChannelCount: Int = 1,
                         providesOwnOutputBuffer: Bool = false,
                         muted: Bool = false,
                         bypassed: Bool = false) throws -> CoreAudioEngineControl.Slot {
        let slot = try #require(graph.claimSlot())
        plugin.slot = slot
        slot.setInputChannel(inputChannel)
        slot.setOutputChannel(outputChannel)
        slot.setMuted(muted)
        slot.setBypassed(bypassed)
        graph.installFunction(standInRender,
                              context: plugin.context,
                              busChannelCount: busChannelCount,
                              providesOwnOutputBuffer: providesOwnOutputBuffer,
                              into: slot)
        return slot
    }

    @Test func slotTableMatchesTheConfiguredInstanceCap() {
        #expect(CoreAudioEngineControl.maximumSlotCount == PluginConfiguration.maximumInstanceCount,
                "a mismatch would silently cap instances with no explanation")
    }

    @Test func routesTheSelectedInputChannelToTheSelectedOutputChannel() throws {
        let graph = try makeGraph(inputChannels: 4, outputChannels: 4, frames: frames)
        let plugin = StandInPlugin()
        _ = try install(plugin, into: graph, inputChannel: 2, outputChannel: 3)

        feedInput(graph, values: [0.1, 0.2, 0.3, 0.4], frameCount: frames)
        let output = renderCycle(graph, channelCount: 4, frameCount: frames)

        #expect(plugin.callCount == 1)
        // Input channel index 2 carried 0.3, and it must land on output index 3 only.
        #expect(output[3].allSatisfy { abs($0 - 0.3) < 1e-6 })
        #expect(output[0].allSatisfy { $0 == 0 })
        #expect(output[1].allSatisfy { $0 == 0 })
        #expect(output[2].allSatisfy { $0 == 0 })
    }

    @Test func sumsInstancesSharingAnOutputChannel() throws {
        let graph = try makeGraph(inputChannels: 2, outputChannels: 2, frames: frames)
        var plugins: [StandInPlugin] = []

        for _ in 0..<3 {
            let plugin = StandInPlugin()
            plugins.append(plugin)
            _ = try install(plugin, into: graph, inputChannel: 0, outputChannel: 1)
        }

        feedInput(graph, values: [0.25, 0], frameCount: frames)
        let output = renderCycle(graph, channelCount: 2, frameCount: frames)

        #expect(plugins.allSatisfy { $0.callCount == 1 })
        // Three instances of 0.25 summed onto the same channel.
        #expect(output[1].allSatisfy { abs($0 - 0.75) < 1e-6 })
        #expect(output[0].allSatisfy { $0 == 0 })
    }

    @Test func muteSilencesOnlyTheMutedInstanceAndStillRendersIt() throws {
        let graph = try makeGraph(inputChannels: 2, outputChannels: 2, frames: frames)

        let muted = StandInPlugin()
        _ = try install(muted, into: graph, inputChannel: 0, outputChannel: 0, muted: true)

        let audible = StandInPlugin()
        _ = try install(audible, into: graph, inputChannel: 1, outputChannel: 1)

        feedInput(graph, values: [0.5, 0.6], frameCount: frames)
        let output = renderCycle(graph, channelCount: 2, frameCount: frames)

        #expect(output[0].allSatisfy { $0 == 0 }, "muted instance must not reach the device")
        #expect(output[1].allSatisfy { abs($0 - 0.6) < 1e-6 }, "other instance must be unaffected")

        // Muting still renders the plugin, so its internal state stays continuous.
        #expect(muted.callCount == 1)
        #expect(audible.callCount == 1)
    }

    @Test func bypassWiresInputStraightToOutputWithoutInvokingThePlugin() throws {
        let graph = try makeGraph(inputChannels: 2, outputChannels: 2, frames: frames)

        // A stand-in that would write 9s, so "did the plugin run" is unambiguous.
        let plugin = StandInPlugin()
        plugin.sentinel = 9
        _ = try install(plugin, into: graph, inputChannel: 0, outputChannel: 0, bypassed: true)

        feedInput(graph, values: [0.42, 0], frameCount: frames)
        let output = renderCycle(graph, channelCount: 2, frameCount: frames)

        #expect(plugin.callCount == 0, "bypass must skip the plugin entirely")
        #expect(output[0].allSatisfy { abs($0 - 0.42) < 1e-6 }, "input must arrive untouched")
    }

    @Test func bypassRespectsTheSelectedChannelsRatherThanTheDefaults() throws {
        let graph = try makeGraph(inputChannels: 4, outputChannels: 4, frames: frames)
        let plugin = StandInPlugin()
        plugin.sentinel = 9
        _ = try install(plugin, into: graph, inputChannel: 1, outputChannel: 3, bypassed: true)

        feedInput(graph, values: [0.1, 0.2, 0.3, 0.4], frameCount: frames)
        let output = renderCycle(graph, channelCount: 4, frameCount: frames)

        #expect(plugin.callCount == 0)
        #expect(output[3].allSatisfy { abs($0 - 0.2) < 1e-6 },
                "bypass must route the selected input channel to the selected output channel")
        #expect(output[0].allSatisfy { $0 == 0 })
        #expect(output[1].allSatisfy { $0 == 0 })
        #expect(output[2].allSatisfy { $0 == 0 })
    }

    @Test func aBypassedInstanceIsStillSilencedByMute() throws {
        let graph = try makeGraph(inputChannels: 1, outputChannels: 1, frames: frames)
        let plugin = StandInPlugin()
        plugin.sentinel = 9
        _ = try install(plugin, into: graph, muted: true, bypassed: true)

        feedInput(graph, values: [0.5], frameCount: frames)
        let output = renderCycle(graph, channelCount: 1, frameCount: frames)

        #expect(output[0].allSatisfy { $0 == 0 }, "mute must win over bypass")
    }

    @Test func retiredSlotsStopContributing() throws {
        let graph = try makeGraph(inputChannels: 1, outputChannels: 1, frames: frames)
        let plugin = StandInPlugin()
        let slot = try install(plugin, into: graph)

        feedInput(graph, values: [0.3], frameCount: frames)
        let before = renderCycle(graph, channelCount: 1, frameCount: frames)
        #expect(before[0].allSatisfy { abs($0 - 0.3) < 1e-6 })

        graph.retire(slot)

        feedInput(graph, values: [0.3], frameCount: frames)
        let after = renderCycle(graph, channelCount: 1, frameCount: frames)
        #expect(after[0].allSatisfy { $0 == 0 })
        #expect(plugin.callCount == 1, "a retired slot must not be rendered again")
    }

    @Test func channelSelectionOutsideTheDeviceRangeYieldsSilenceNotCorruption() throws {
        let graph = try makeGraph(inputChannels: 2, outputChannels: 2, frames: frames)
        let plugin = StandInPlugin()
        // Stale selection pointing past the end of the current device.
        _ = try install(plugin, into: graph, inputChannel: 7, outputChannel: 0)

        feedInput(graph, values: [0.5, 0.5], frameCount: frames)
        let output = renderCycle(graph, channelCount: 2, frameCount: frames)

        #expect(output[0].allSatisfy { $0 == 0 })
        #expect(output[1].allSatisfy { $0 == 0 })
    }

    @Test func outOfRangeOutputChannelIsDroppedRatherThanWritingOutOfBounds() throws {
        // Graph built for 8 channels, but the device only presents 2 buffers this cycle.
        let graph = try makeGraph(inputChannels: 2, outputChannels: 8, frames: frames)
        let plugin = StandInPlugin()
        _ = try install(plugin, into: graph, inputChannel: 0, outputChannel: 6)

        feedInput(graph, values: [0.5, 0.5], frameCount: frames)
        let output = renderCycle(graph, channelCount: 2, frameCount: frames)

        #expect(output.allSatisfy { $0.allSatisfy { $0 == 0 } })
    }

    @Test func stereoFallbackReadsChannelZeroOfThePluginOutput() throws {
        let graph = try makeGraph(inputChannels: 1, outputChannels: 1, frames: frames)
        let plugin = StandInPlugin()
        plugin.gain = 2
        // A plugin that refused mono gets two buses; the host takes bus 0 back out.
        _ = try install(plugin, into: graph, busChannelCount: 2)

        feedInput(graph, values: [0.25], frameCount: frames)
        let output = renderCycle(graph, channelCount: 1, frameCount: frames)

        #expect(output[0].allSatisfy { abs($0 - 0.5) < 1e-6 })
    }

    @Test func aPluginsOwnOutputBufferIsReadRatherThanTheHostScratch() throws {
        let graph = try makeGraph(inputChannels: 1, outputChannels: 1, frames: frames)

        let own = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        own.initialize(repeating: 0, count: frames)
        defer { own.deallocate() }

        let plugin = StandInPlugin()
        plugin.ownOutputBuffer = own
        plugin.gain = 3
        _ = try install(plugin, into: graph, providesOwnOutputBuffer: true)

        feedInput(graph, values: [0.25], frameCount: frames)
        let output = renderCycle(graph, channelCount: 1, frameCount: frames)

        #expect(plugin.callCount == 1)
        #expect(output[0].allSatisfy { abs($0 - 0.75) < 1e-6 },
                "the host must read back the buffer the plugin rendered into")
    }

    @Test func aPluginGivenANullOutputPointerThatWritesNothingYieldsSilence() throws {
        let graph = try makeGraph(inputChannels: 1, outputChannels: 1, frames: frames)

        // Claims to own its output buffer but never supplies one: must not read stale memory.
        let plugin = StandInPlugin()
        plugin.writesNothing = true
        _ = try install(plugin, into: graph, providesOwnOutputBuffer: true)

        feedInput(graph, values: [0.9], frameCount: frames)
        let output = renderCycle(graph, channelCount: 1, frameCount: frames)

        #expect(plugin.callCount == 1)
        #expect(output[0].allSatisfy { $0 == 0 })
    }

    @Test func emptyRingBufferCountsAnUnderrunAndOutputsSilence() throws {
        let graph = try makeGraph(inputChannels: 2, outputChannels: 2, frames: frames)

        // No input fed at all.
        let output = renderCycle(graph, channelCount: 2, frameCount: frames)

        #expect(graph.underruns == 1)
        #expect(graph.renderCycles == 1)
        #expect(output.allSatisfy { $0.allSatisfy { $0 == 0 } })
    }

    @Test func slotsAreFiniteAndClaimingStopsAtTheCap() throws {
        let graph = try makeGraph(inputChannels: 1, outputChannels: 1, frames: frames)

        var claimed = 0
        while graph.claimSlot() != nil {
            claimed += 1
            if claimed > PluginConfiguration.maximumInstanceCount { break }
        }

        #expect(claimed == PluginConfiguration.maximumInstanceCount)
        #expect(graph.claimSlot() == nil)
    }

    @Test func releasingASlotReturnsItToThePool() throws {
        let graph = try makeGraph(inputChannels: 1, outputChannels: 1, frames: frames)

        var slots: [CoreAudioEngineControl.Slot] = []
        while let slot = graph.claimSlot() { slots.append(slot) }
        #expect(graph.claimSlot() == nil)

        graph.retire(slots[0])
        graph.release(slots[0])

        #expect(graph.claimSlot() != nil, "a released slot must be reusable")
    }

    // MARK: - Load reporting

    @Test func bufferPeriodIsTheFrameCountOverTheSampleRate() throws {
        // 128 frames at 48 kHz is 2.666… ms of audio; that's the render callback's whole budget.
        let graph = try makeGraph(inputChannels: 1, outputChannels: 1, frames: 128)
        #expect(abs(graph.bufferPeriodNanoseconds - 2_666_666.67) < 1)

        // Halving the frames halves the budget; doubling the rate halves it again.
        let small = try makeGraph(inputChannels: 1, outputChannels: 1, frames: 64)
        #expect(abs(small.bufferPeriodNanoseconds - 1_333_333.33) < 1)

        let fast = try makeGraph(inputChannels: 1, outputChannels: 1, frames: 128,
                                 sampleRate: 96_000)
        #expect(abs(fast.bufferPeriodNanoseconds - 1_333_333.33) < 1)
    }

    @Test func aNonsenseSampleRateYieldsNoBudgetRatherThanDividingByZero() throws {
        let graph = try makeGraph(inputChannels: 1, outputChannels: 1, frames: 128, sampleRate: 0)
        #expect(graph.bufferPeriodNanoseconds == 0)
    }

    /// No timing assertions — those would be flaky. Just that rendering records *something*, that
    /// the peak can't be below the smoothed average, and that an idle graph reports nothing.
    @Test func renderingPopulatesTheLoadFigures() throws {
        let graph = try makeGraph(inputChannels: 1, outputChannels: 1, frames: frames)

        #expect(graph.smoothedRenderNanoseconds == 0,
                "a graph that has never rendered must not report a load")
        #expect(graph.peakRenderNanoseconds == 0)

        let plugin = StandInPlugin()
        _ = try install(plugin, into: graph)

        for _ in 0..<50 {
            feedInput(graph, values: [0.25], frameCount: frames)
            _ = renderCycle(graph, channelCount: 1, frameCount: frames)
        }

        #expect(graph.smoothedRenderNanoseconds > 0,
                "rendering should have recorded some elapsed time")
        #expect(graph.peakRenderNanoseconds >= graph.smoothedRenderNanoseconds,
                "the worst callback can't be faster than the average")

        // Sanity bound: 50 trivial callbacks must not each take a whole second.
        #expect(graph.peakRenderNanoseconds < 1_000_000_000)
    }
}

// MARK: - Parallel rendering

/// The same render path, fanned out across worker threads. What matters is that it is the *same*
/// path: these tests re-check routing, summing, mute and bypass rather than trusting that
/// splitting the slot loop by stride preserved them.
struct ParallelRenderingTests {

    private let frames = 64

    private func makeGraph(inputChannels: Int,
                           outputChannels: Int,
                           parallelThreshold: Int?) throws -> CoreAudioEngineControl {
        let graph = try #require(CoreAudioEngineControl(maximumFrameCount: frames,
                                               inputChannelCount: inputChannels,
                                               outputChannelCount: outputChannels,
                                               sampleRate: 48_000))
        if let parallelThreshold {
            graph.setParallelRendering(true, instanceThreshold: parallelThreshold)
            // No output unit, so the workers get a time-constraint policy but join no workgroup.
            graph.startWorkers()
        }
        return graph
    }

    @discardableResult
    private func install(_ plugin: StandInPlugin,
                         into graph: CoreAudioEngineControl,
                         inputChannel: Int,
                         outputChannel: Int,
                         muted: Bool = false,
                         bypassed: Bool = false) throws -> CoreAudioEngineControl.Slot {
        let slot = try #require(graph.claimSlot())
        plugin.slot = slot
        slot.setInputChannel(inputChannel)
        slot.setOutputChannel(outputChannel)
        slot.setMuted(muted)
        slot.setBypassed(bypassed)
        graph.installFunction(standInRender, context: plugin.context,
                              busChannelCount: 1, providesOwnOutputBuffer: false, into: slot)
        return slot
    }

    /// Index within `populate`'s instances that is bypassed, and so never rendered at all.
    private static let bypassedIndex = 5

    /// Asserts each instance rendered once per cycle — with the bypassed one at zero, since
    /// bypass skips the plugin entirely while mute still renders it.
    private func expectRendered(_ plugins: [StandInPlugin], cycles: Int) {
        for (index, plugin) in plugins.enumerated() {
            let expected = index == Self.bypassedIndex ? 0 : cycles
            #expect(plugin.callCount == expected,
                    "instance \(index) rendered \(plugin.callCount) times, expected \(expected)")
        }
    }

    /// Builds a graph with `count` instances routed round-robin over four output channels, with
    /// one muted and one bypassed so those paths are covered under fan-out too.
    ///
    /// The returned plugins **must be kept alive** for as long as the graph renders: the engine
    /// holds an unretained context pointer to each, so dropping them is a use-after-free on the
    /// next cycle. Callers end with an assertion that touches them, which keeps that honest
    /// rather than relying on where the optimiser chooses to release.
    private func populate(_ graph: CoreAudioEngineControl, count: Int) throws -> [StandInPlugin] {
        var plugins: [StandInPlugin] = []
        for index in 0..<count {
            let plugin = StandInPlugin()
            plugin.gain = Float(index % 3) + 1
            plugins.append(plugin)
            try install(plugin, into: graph,
                        inputChannel: index % 4,
                        outputChannel: (index * 3) % 4,
                        muted: index == 2,
                        bypassed: index == Self.bypassedIndex)
        }
        return plugins
    }

    // MARK: Equivalence

    /// The headline claim. Same instances, same input, rendered serially and in parallel.
    ///
    /// Compared with a tolerance rather than bit-for-bit, and that is not laziness: float addition
    /// isn't associative, so summing per-worker partials in worker order gives a different — not a
    /// worse — last bit than one straight pass. 1e-6 is far below audibility and far above the
    /// error being tolerated.
    @Test func parallelRenderingMatchesSerialRendering() throws {
        let instances = 16
        let input: [Float] = [0.1, 0.2, 0.3, 0.4]

        let serial = try makeGraph(inputChannels: 4, outputChannels: 4, parallelThreshold: nil)
        let serialPlugins = try populate(serial, count: instances)
        feedInput(serial, values: input, frameCount: frames)
        let expected = renderCycle(serial, channelCount: 4, frameCount: frames)
        #expect(serial.isParallelRenderingEngaged == false)

        let parallel = try makeGraph(inputChannels: 4, outputChannels: 4, parallelThreshold: 1)
        try #require(parallel.workerThreadCount > 0, "single-core machine; nothing to compare")
        let parallelPlugins = try populate(parallel, count: instances)
        feedInput(parallel, values: input, frameCount: frames)
        let actual = renderCycle(parallel, channelCount: 4, frameCount: frames)

        #expect(parallel.isParallelRenderingEngaged)
        for channel in 0..<4 {
            for frame in 0..<frames {
                #expect(abs(actual[channel][frame] - expected[channel][frame]) < 1e-6,
                        "channel \(channel) frame \(frame) diverged")
            }
        }

        // Non-trivial output, or the comparison above proves nothing.
        #expect(expected.contains { $0.contains { $0 != 0 } })

        // Every instance rendered exactly once in both, so no slot was dropped or double-counted
        // by the stride partitioning.
        expectRendered(serialPlugins, cycles: 1)
        expectRendered(parallelPlugins, cycles: 1)
    }

    /// Repeated cycles: catches an accumulator that isn't cleared between cycles, which would
    /// show up as output growing rather than as a first-cycle mismatch.
    @Test func repeatedParallelCyclesStayStable() throws {
        let graph = try makeGraph(inputChannels: 4, outputChannels: 4, parallelThreshold: 1)
        try #require(graph.workerThreadCount > 0)
        let plugins = try populate(graph, count: 12)

        var first: [[Float]]?
        for _ in 0..<20 {
            feedInput(graph, values: [0.1, 0.2, 0.3, 0.4], frameCount: frames)
            let output = renderCycle(graph, channelCount: 4, frameCount: frames)
            if let first {
                #expect(output.elementsEqual(first) { $0.elementsEqual($1) },
                        "a stale accumulator would make each cycle differ from the last")
            } else {
                first = output
            }
        }

        expectRendered(plugins, cycles: 20)
    }

    // MARK: Threshold

    @Test func belowTheThresholdItRendersSerially() throws {
        let graph = try makeGraph(inputChannels: 2, outputChannels: 2, parallelThreshold: 8)
        try #require(graph.workerThreadCount > 0)
        let plugins = try populate(graph, count: 3)

        feedInput(graph, values: [0.5, 0.5], frameCount: frames)
        _ = renderCycle(graph, channelCount: 2, frameCount: frames)

        #expect(graph.isParallelRenderingEngaged == false,
                "three instances aren't worth fanning out")
        expectRendered(plugins, cycles: 1)
    }

    /// Crossing the threshold mid-session must engage it without a restart — instances are added
    /// while running.
    @Test func addingInstancesCrossesTheThresholdWithoutARestart() throws {
        let graph = try makeGraph(inputChannels: 2, outputChannels: 2, parallelThreshold: 4)
        try #require(graph.workerThreadCount > 0)

        var plugins = try populate(graph, count: 3)
        feedInput(graph, values: [0.5, 0.5], frameCount: frames)
        _ = renderCycle(graph, channelCount: 2, frameCount: frames)
        #expect(graph.isParallelRenderingEngaged == false)

        let extra = StandInPlugin()
        plugins.append(extra)
        try install(extra, into: graph, inputChannel: 0, outputChannel: 0)

        feedInput(graph, values: [0.5, 0.5], frameCount: frames)
        _ = renderCycle(graph, channelCount: 2, frameCount: frames)
        #expect(graph.isParallelRenderingEngaged, "the fourth instance should have engaged it")

        #expect(plugins.dropLast().allSatisfy { $0.callCount == 2 })
        #expect(extra.callCount == 1)
    }

    @Test func parallelRenderingOffMeansNoWorkersAtAll() throws {
        let graph = try makeGraph(inputChannels: 2, outputChannels: 2, parallelThreshold: nil)
        let plugins = try populate(graph, count: 16)

        feedInput(graph, values: [0.5, 0.5], frameCount: frames)
        _ = renderCycle(graph, channelCount: 2, frameCount: frames)

        #expect(graph.workerThreadCount == 0)
        #expect(graph.isParallelRenderingEngaged == false)
        expectRendered(plugins, cycles: 1)
    }

    // MARK: Active slot count

    /// The threshold is compared against this, so drift here silently changes when fan-out
    /// happens. Retiring twice is legal and must not double-decrement.
    @Test func theActiveSlotCountTracksInstallAndRetire() throws {
        let graph = try makeGraph(inputChannels: 2, outputChannels: 2, parallelThreshold: nil)
        #expect(graph.activeSlotCount == 0)

        let plugins = (0..<4).map { _ in StandInPlugin() }
        var slots: [CoreAudioEngineControl.Slot] = []
        for plugin in plugins {
            slots.append(try install(plugin, into: graph, inputChannel: 0, outputChannel: 0))
        }
        #expect(graph.activeSlotCount == 4)

        graph.retire(slots[0])
        #expect(graph.activeSlotCount == 3)

        graph.retire(slots[0])
        #expect(graph.activeSlotCount == 3, "retiring an already-retired slot must not drift")

        for slot in slots.dropFirst() { graph.retire(slot) }
        #expect(graph.activeSlotCount == 0)
    }

    // MARK: Worker scheduling

    /// Workers doing DSP on an ordinary thread, with the I/O thread blocked waiting for them,
    /// would be worse than not parallelising at all.
    @Test func workersAreRealtimeScheduled() throws {
        let graph = try makeGraph(inputChannels: 2, outputChannels: 2, parallelThreshold: 1)
        try #require(graph.workerThreadCount > 0)

        // One cycle first, rather than a sleep. Each worker configures itself before its first
        // wait, and `run` doesn't return until every worker has signalled completion — so this
        // is a guarantee that all of them have reported, not a hope that they have.
        let plugin = StandInPlugin()
        try install(plugin, into: graph, inputChannel: 0, outputChannel: 0)
        feedInput(graph, values: [0.5, 0.5], frameCount: frames)
        _ = renderCycle(graph, channelCount: 2, frameCount: frames)

        let policies = graph.workerThreadPolicies
        #expect(policies.count == graph.workerThreadCount,
                "every worker should have reported its own policy by now")
        for (index, policy) in policies.enumerated() {
            #expect(policy.isRealtime, "worker \(index) is not realtime: \(policy.summary)")
        }
    }

    /// No device here, so there is no workgroup to join — the tests exercise a deliberately
    /// weaker configuration than production, and this pins that down rather than leaving it
    /// looking like a failure.
    @Test func withoutADeviceThereIsNoWorkgroupToJoin() throws {
        let graph = try makeGraph(inputChannels: 2, outputChannels: 2, parallelThreshold: 1)
        try #require(graph.workerThreadCount > 0)

        let plugin = StandInPlugin()
        try install(plugin, into: graph, inputChannel: 0, outputChannel: 0)
        feedInput(graph, values: [0.5, 0.5], frameCount: frames)
        _ = renderCycle(graph, channelCount: 2, frameCount: frames)

        let policies = graph.workerThreadPolicies
        #expect(policies.count == graph.workerThreadCount)
        #expect(policies.allSatisfy { !$0.joinedWorkgroup })
    }

    @Test func stoppingWorkersReturnsToSerialRendering() throws {
        let graph = try makeGraph(inputChannels: 2, outputChannels: 2, parallelThreshold: 1)
        try #require(graph.workerThreadCount > 0)
        let plugins = try populate(graph, count: 8)

        feedInput(graph, values: [0.5, 0.5], frameCount: frames)
        _ = renderCycle(graph, channelCount: 2, frameCount: frames)
        #expect(graph.isParallelRenderingEngaged)

        graph.stopWorkers()
        #expect(graph.workerThreadCount == 0)

        feedInput(graph, values: [0.5, 0.5], frameCount: frames)
        let output = renderCycle(graph, channelCount: 2, frameCount: frames)

        #expect(graph.isParallelRenderingEngaged == false)
        #expect(output.contains { $0.contains { $0 != 0 } },
                "rendering must carry on serially, not fall silent")
        expectRendered(plugins, cycles: 2)
    }
}
