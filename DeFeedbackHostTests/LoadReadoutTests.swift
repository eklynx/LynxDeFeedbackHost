//
//  LoadReadoutTests.swift
//  DeFeedbackHostTests
//
//  Pins the text and colour of the control bar's engine readout, written when it was lifted out
//  of `ContentView` (issue #41) so the move can be shown to change nothing.
//
//  - Tests initially created with AI with human edits, but all reviewed by human

import SwiftUI
import Testing

@testable import DeFeedbackHost

private func policy(_ evidence: RealtimeThreadPolicy.Evidence = .realtimeSchedulingBand,
                    workgroup: Bool = false) -> RealtimeThreadPolicy {
    RealtimeThreadPolicy(evidence: evidence, schedulingPolicy: 4, priority: 63, period: 0,
                         computation: 0, constraint: 0, isPreemptible: true,
                         joinedWorkgroup: workgroup)
}

private func diagnostics(renderCycles: UInt64 = 100,
                         underruns: UInt64 = 0,
                         load: Double = 0.25,
                         peak: Double = 0.5,
                         render: RealtimeThreadPolicy? = policy(),
                         capture: RealtimeThreadPolicy? = policy(),
                         workers: [RealtimeThreadPolicy] = [],
                         engaged: Bool = false) -> AudioHost.Diagnostics {
    AudioHost.Diagnostics(captureCycles: 1, renderCycles: renderCycles, underruns: underruns,
                          dspLoad: load, peakDspLoad: peak, renderThreadPolicy: render,
                          captureThreadPolicy: capture, workerThreadPolicies: workers,
                          parallelRenderingEngaged: engaged)
}

struct LoadReadoutTests {

    // MARK: - Summary

    @Test func waitsForTheDeviceBeforeTheFirstCallback() {
        #expect(LoadReadout.summary(nil) == "— CPU · waiting for the device")
        #expect(LoadReadout.summary(diagnostics(renderCycles: 0)) == "— CPU · waiting for the device")
    }

    @Test func summarisesLoadAndUnderruns() {
        #expect(LoadReadout.summary(diagnostics(underruns: 3, load: 0.256))
                == "26% DSP Load · 3 underruns")
    }

    @Test func shoutsWhenAThreadIsNotRealtime() {
        let text = LoadReadout.summary(diagnostics(render: policy(.none)))
        #expect(text == "25% DSP Load · 0 underruns · NOT REALTIME")
    }

    @Test func aNonRealtimeWorkerAlsoShouts() {
        let text = LoadReadout.summary(diagnostics(workers: [policy(), policy(.none)]))
        #expect(text.hasSuffix("NOT REALTIME"))
    }

    // MARK: - Colour

    @Test func isSecondaryWhenWaiting() {
        #expect(LoadReadout.color(nil) == .secondary)
        #expect(LoadReadout.color(diagnostics(renderCycles: 0)) == .secondary)
    }

    @Test func isSecondaryWhenHealthy() {
        #expect(LoadReadout.color(diagnostics(load: 0.8)) == .secondary)
    }

    @Test func isOrangeOverEightyPercentOrWithUnderruns() {
        #expect(LoadReadout.color(diagnostics(load: 0.81)) == .orange)
        #expect(LoadReadout.color(diagnostics(underruns: 1)) == .orange)
    }

    @Test func isRedWhenNotRealtimeEvenIfOtherwiseHealthy() {
        #expect(LoadReadout.color(diagnostics(render: policy(.none))) == .red)
        #expect(LoadReadout.color(diagnostics(underruns: 5, render: policy(.none))) == .red)
    }

    // MARK: - Help text

    @Test func helpWhileWaiting() {
        #expect(LoadReadout.help(nil, parallelRendering: true)
                == "Waiting for the output device's first callback.")
    }

    @Test func helpListsPeakAndBothThreads() {
        let text = LoadReadout.help(diagnostics(underruns: 2, peak: 0.5), parallelRendering: false)
        #expect(text == """
            DSP load history:
            Peak so far: 50%. Underruns: 2.
            Render thread: realtime, scheduling band, priority 63.
            Capture thread: realtime, scheduling band, priority 63.
            """)
    }

    @Test func helpOmitsThreadsThatWereNotMeasured() {
        let text = LoadReadout.help(diagnostics(render: nil, capture: nil), parallelRendering: false)
        #expect(text == "DSP load history:\nPeak so far: 50%. Underruns: 0.")
    }

    @Test func helpExplainsParallelRenderingThatFellBackToSerial() {
        let text = LoadReadout.help(diagnostics(), parallelRendering: true)
        #expect(text.hasSuffix("Parallel rendering on, but rendering serially on one core."))
    }

    @Test func helpListsEveryWorkerIndividually() {
        let workers = [policy(workgroup: true), policy(.none)]
        let text = LoadReadout.help(diagnostics(workers: workers, engaged: true),
                                    parallelRendering: true)
        #expect(text.contains("2 render workers (in use)."))
        #expect(text.contains("  Worker 1: realtime, scheduling band, priority 63, in the device workgroup."))
        #expect(text.contains("  Worker 2: not realtime (policy 4, priority 63)."))
    }

    @Test func helpSaysWhenWorkersAreIdleBelowTheThreshold() {
        let text = LoadReadout.help(diagnostics(workers: [policy()], engaged: false),
                                    parallelRendering: true)
        #expect(text.contains("1 render workers (idle, below threshold)."))
    }

    // MARK: - Percent

    @Test(arguments: [(0.0, "0%"), (-0.5, "0%"), (Double.nan, "0%"), (Double.infinity, "0%"),
                      (0.004, "<1%"), (0.01, "1%"), (0.254, "25%"), (0.255, "26%"), (1.0, "100%"),
                      (1.5, "150%")])
    func formatsPercent(_ fraction: Double, _ text: String) {
        #expect(LoadReadout.percent(fraction) == text)
    }

    // MARK: - Error banner rule

    @Test func deniedMicrophoneErrorIsHiddenOnlyWhileThePermissionBannerShows() {
        let denied = AudioHostError.microphoneAccessDenied.localizedDescription
        #expect(ContentView.visibleError(denied, microphoneNeedsPermission: true) == nil)
        #expect(ContentView.visibleError(denied, microphoneNeedsPermission: false) == denied)
        #expect(ContentView.visibleError("Other", microphoneNeedsPermission: true) == "Other")
        #expect(ContentView.visibleError(nil, microphoneNeedsPermission: false) == nil)
    }
}
