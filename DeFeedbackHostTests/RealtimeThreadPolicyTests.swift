//
//  RealtimeThreadPolicyTests.swift
//  DeFeedbackHostTests
//
//  Two halves. The pure-function tests pin down both realtime signals without hardware. The last
//  test drives the C++ engine from a real CoreAudio output device and asserts the thread it lands
//  on is reported as realtime — that direction was a false negative until the `Evidence` split,
//  and it is the assertion that stops it regressing.
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import AudioToolbox
import Darwin
import Dispatch
import Testing

@testable import DeFeedbackHost

struct RealtimeThreadPolicyTests {

    @Test func anUnsetPortReadsAsNothingRatherThanAFalsePositive() {
        #expect(RealtimeThreadPolicy.read(port: 0) == nil)
    }

    @Test @MainActor func theMainThreadIsNotRealtime() throws {
        let policy = try #require(
            RealtimeThreadPolicy.read(port: pthread_mach_thread_np(pthread_self())))

        #expect(policy.isRealtime == false)
        #expect(policy.evidence == .none)
        #expect(policy.summary.contains("not realtime"))
    }

    /// A `userInitiated` queue is the most plausible shape of a regression — it *sounds* high
    /// priority and is nowhere near the realtime band.
    @Test func aHighQoSDispatchQueueIsStillNotRealtime() async throws {
        let port = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: pthread_mach_thread_np(pthread_self()))
            }
        }

        // The thread may have been recycled by the time this runs; only assert if it's readable.
        if let policy = RealtimeThreadPolicy.read(port: port) {
            #expect(policy.isRealtime == false,
                    "a dispatch queue must never be mistaken for a realtime audio thread")
        }
    }

    // MARK: - The two signals

    @Test func anExplicitTimeConstraintPolicyCounts() {
        // What `thread_policy_get` reports when queried on the thread itself.
        #expect(RealtimeThreadPolicy.evidence(usingDefaults: 0,
                                              schedulingPolicy: SCHED_OTHER,
                                              priority: 31) == .timeConstraintPolicy)
    }

    /// The signal that was missing. Cross-thread, a CoreAudio I/O thread reports defaults for the
    /// time-constraint policy but still shows SCHED_FIFO at priority 63.
    @Test func schedFifoAboveThePosixMaximumCounts() {
        let aboveMaximum = sched_get_priority_max(SCHED_FIFO) + 16   // 47 + 16 = 63 in practice
        #expect(RealtimeThreadPolicy.evidence(usingDefaults: 1,
                                              schedulingPolicy: SCHED_FIFO,
                                              priority: aboveMaximum) == .realtimeSchedulingBand)
    }

    @Test func ordinaryThreadsProduceNoEvidence() {
        #expect(RealtimeThreadPolicy.evidence(usingDefaults: 1,
                                              schedulingPolicy: SCHED_OTHER,
                                              priority: 31) == .none)

        // SCHED_FIFO *within* the POSIX range is elevated but not the realtime band.
        #expect(RealtimeThreadPolicy.evidence(
            usingDefaults: 1,
            schedulingPolicy: SCHED_FIFO,
            priority: sched_get_priority_max(SCHED_FIFO)) == .none)
    }

    @Test func summaryNamesWhichSignalWasFound() {
        let constraint = RealtimeThreadPolicy(
            evidence: .timeConstraintPolicy, schedulingPolicy: SCHED_FIFO, priority: 63,
            period: 256_000, computation: 256_000, constraint: 256_000, isPreemptible: true)
        #expect(constraint.summary == "realtime, time-constraint, priority 63")

        let band = RealtimeThreadPolicy(
            evidence: .realtimeSchedulingBand, schedulingPolicy: SCHED_FIFO, priority: 63,
            period: 0, computation: 0, constraint: 0, isPreemptible: true)
        #expect(band.summary == "realtime, scheduling band, priority 63")
        #expect(band.isRealtime)
    }

    // MARK: - Against a real device

    /// Drives the C++ engine's output callback from a real AUHAL output unit and checks the thread
    /// CoreAudio calls it on. Output-only, so no microphone consent is involved, and the graph has
    /// no instances so it renders silence.
    @Test @MainActor func theEngineRunsOnARealtimeThreadWhenDrivenByCoreAudio() async throws {
        let frames = 128
        let graph = try #require(CoreAudioEngineControl(maximumFrameCount: frames,
                                               inputChannelCount: 2,
                                               outputChannelCount: 2,
                                               sampleRate: 48_000))
        graph.primeWithSilence(frameCount: frames * 4)

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { return }

        var unit: AudioUnit?
        guard AudioComponentInstanceNew(component, &unit) == noErr, let unit else { return }
        defer {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }

        var format = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        guard AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                   &format,
                                   UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr
        else { return }

        var callback = AURenderCallbackStruct(inputProc: dfh_engine_output_callback,
                                             inputProcRefCon: graph.callbackRefContext)
        guard AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                                   kAudioUnitScope_Input, 0, &callback,
                                   UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr
        else { return }

        guard AudioUnitInitialize(unit) == noErr, AudioOutputUnitStart(unit) == noErr else { return }
        try? await Task.sleep(for: .milliseconds(400))

        // Read *before* stopping. Once the unit stops, CoreAudio is free to tear its I/O thread
        // down, and `thread_policy_get` on the stale port then fails — which showed up here as an
        // intermittent failure that looked like the engine losing its realtime scheduling. It is
        // also how the app really uses this: diagnostics are read during a running session.
        let cycles = graph.renderCycles
        let observed = RealtimeThreadPolicy.read(port: graph.renderThreadPort)
        AudioOutputUnitStop(unit)

        // A machine with no usable output device shouldn't fail the suite.
        guard cycles > 0 else { return }

        let policy = try #require(observed)
        #expect(policy.isRealtime,
                "CoreAudio's I/O thread must be reported as realtime: \(policy.summary)")
        #expect(policy.schedulingPolicy == SCHED_FIFO)
        #expect(policy.priority > sched_get_priority_max(SCHED_FIFO),
                "the I/O thread should sit above the POSIX-exposed priority range")
    }
}

// MARK: - Host reporting

struct AudioThreadReportingTests {

    private func diagnostics(render: RealtimeThreadPolicy?,
                             capture: RealtimeThreadPolicy?,
                             workers: [RealtimeThreadPolicy] = []) -> AudioHost.Diagnostics {
        AudioHost.Diagnostics(captureCycles: 10,
                              renderCycles: 10,
                              underruns: 0,
                              dspLoad: 0.1,
                              peakDspLoad: 0.2,
                              renderThreadPolicy: render,
                              captureThreadPolicy: capture,
                              workerThreadPolicies: workers,
                              parallelRenderingEngaged: !workers.isEmpty)
    }

    private let realtime = RealtimeThreadPolicy(
        evidence: .timeConstraintPolicy, schedulingPolicy: SCHED_FIFO, priority: 63,
        period: 256_000, computation: 256_000, constraint: 256_000, isPreemptible: true)

    /// What a real I/O thread looks like when read cross-thread.
    private let realtimeCrossThread = RealtimeThreadPolicy(
        evidence: .realtimeSchedulingBand, schedulingPolicy: SCHED_FIFO, priority: 63,
        period: 0, computation: 0, constraint: 0, isPreemptible: true)

    private let ordinary = RealtimeThreadPolicy(
        evidence: .none, schedulingPolicy: SCHED_OTHER, priority: 31,
        period: 0, computation: 0, constraint: 0, isPreemptible: true)

    @Test func bothThreadsRealtimePasses() {
        #expect(diagnostics(render: realtime, capture: realtime).audioThreadsAreRealtime)
    }

    /// The regression this guards: cross-thread reads produce no time-constraint values, and the
    /// UI must not shout NOT REALTIME at a healthy session because of it.
    @Test func crossThreadEvidenceIsAcceptedAsRealtime() {
        #expect(diagnostics(render: realtimeCrossThread,
                            capture: realtimeCrossThread).audioThreadsAreRealtime)
    }

    @Test func eitherThreadFallingOffRealtimeIsReported() {
        #expect(diagnostics(render: ordinary, capture: realtime).audioThreadsAreRealtime == false)
        #expect(diagnostics(render: realtime, capture: ordinary).audioThreadsAreRealtime == false)
        #expect(diagnostics(render: ordinary, capture: ordinary).audioThreadsAreRealtime == false)
    }

    /// A thread that hasn't reported in yet is unknown, not broken — the check must not cry wolf
    /// between pressing Run and the device's first callback.
    @Test func threadsThatHaveNotRunYetAreNotTreatedAsFailures() {
        #expect(diagnostics(render: nil, capture: nil).audioThreadsAreRealtime)
        #expect(diagnostics(render: realtime, capture: nil).audioThreadsAreRealtime)
    }

    // MARK: - Render workers

    /// A worker that missed its time-constraint policy is the worst case parallel rendering can
    /// produce: an ordinary thread doing DSP that the I/O thread then blocks waiting for. It must
    /// not be able to hide behind two healthy I/O threads.
    @Test func aWorkerThatIsNotRealtimeFailsTheCheck() {
        #expect(diagnostics(render: realtime, capture: realtime,
                            workers: [realtime, ordinary]).audioThreadsAreRealtime == false)
    }

    @Test func realtimeWorkersPass() {
        #expect(diagnostics(render: realtime, capture: realtime,
                            workers: [realtime, realtime, realtime]).audioThreadsAreRealtime)
    }
}

// MARK: - Worker self-reports

struct WorkerThreadPolicyTests {

    private func info(port: UInt32 = 1234,
                      joined: Bool = true,
                      timeConstraint: Bool = true) -> DFHWorkerInfo {
        DFHWorkerInfo(machPort: port, joinedWorkgroup: joined,
                      timeConstraintApplied: timeConstraint,
                      period: 256_000, computation: 128_000, constraint: 256_000)
    }

    @Test func aWorkerThatHasNotStartedReportsNothing() {
        #expect(RealtimeThreadPolicy(worker: info(port: 0)) == nil)
    }

    @Test func aConfiguredWorkerIsRealtime() throws {
        let policy = try #require(RealtimeThreadPolicy(worker: info()))

        #expect(policy.isRealtime)
        #expect(policy.evidence == .timeConstraintPolicy)
        #expect(policy.joinedWorkgroup)
        #expect(policy.period == 256_000)
    }

    /// The POSIX view of these threads is wrong (probe 0.2 saw SCHED_OTHER at 31 on a confirmed
    /// realtime worker), so the summary must not quote a priority at all.
    @Test func theSummaryOmitsThePriorityItCannotMeasure() throws {
        let policy = try #require(RealtimeThreadPolicy(worker: info()))

        #expect(policy.summary == "realtime, time-constraint, in the device workgroup")
        #expect(!policy.summary.contains("priority"))
    }

    /// Joining the workgroup is an optimisation; failing to get a time-constraint policy is not.
    @Test func aWorkerOutsideTheWorkgroupIsStillRealtime() throws {
        let policy = try #require(RealtimeThreadPolicy(worker: info(joined: false)))

        #expect(policy.isRealtime)
        #expect(policy.summary == "realtime, time-constraint")
    }

    @Test func aWorkerWithoutATimeConstraintPolicyIsNotRealtime() throws {
        let policy = try #require(RealtimeThreadPolicy(worker: info(timeConstraint: false)))
        #expect(policy.isRealtime == false)
    }
}
