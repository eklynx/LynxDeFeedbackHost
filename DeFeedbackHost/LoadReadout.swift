//
//  LoadReadout.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/16/26.
//

import SwiftUI

/// What the control bar says about the running engine: sample rate, DSP load, underruns, and
/// whether the audio threads are really realtime.
///
/// The text, colour and tooltip are pure functions of `AudioHost.Diagnostics` so they can be
/// tested without a window; `StatusReadout` only lays them out.
enum LoadReadout {

    static func summary(_ diagnostics: AudioHost.Diagnostics?) -> String {
        guard let diagnostics, diagnostics.hasRendered else {
            return "— CPU · waiting for the device"
        }

        var summary = "\(percent(diagnostics.dspLoad)) DSP Load · \(diagnostics.underruns) underruns"
        // Loud, because audio work off a realtime thread will glitch under any load at all.
        if !diagnostics.audioThreadsAreRealtime {
            summary += " · NOT REALTIME"
        }
        return summary
    }

    /// Warn if DSP load is over 80%.
    static func color(_ diagnostics: AudioHost.Diagnostics?) -> Color {
        guard let diagnostics, diagnostics.hasRendered else { return .secondary }
        if !diagnostics.audioThreadsAreRealtime { return .red }
        if diagnostics.underruns > 0 || diagnostics.dspLoad > 0.8 { return .orange }
        return .secondary
    }

    static func help(_ diagnostics: AudioHost.Diagnostics?, parallelRendering: Bool) -> String {
        guard let diagnostics, diagnostics.hasRendered else {
            return "Waiting for the output device's first callback."
        }

        var lines = [
            "DSP load history:",
            "Peak so far: \(percent(diagnostics.peakDspLoad)). Underruns: \(diagnostics.underruns)."
        ]
        if let render = diagnostics.renderThreadPolicy {
            lines.append("Render thread: \(render.summary).")
        }
        if let capture = diagnostics.captureThreadPolicy {
            lines.append("Capture thread: \(capture.summary).")
        }

        if diagnostics.workerThreadPolicies.isEmpty {
            if parallelRendering {
                lines.append("Parallel rendering on, but rendering serially on one core.")
            }
        } else {
            let state = diagnostics.parallelRenderingEngaged ? "in use" : "idle, below threshold"
            lines.append("\(diagnostics.workerThreadPolicies.count) render workers (\(state)).")
            // Listed individually rather than summarised: one worker missing its policy is the
            // failure that matters, and a count would hide it.
            for (index, worker) in diagnostics.workerThreadPolicies.enumerated() {
                lines.append("  Worker \(index + 1): \(worker.summary).")
            }
        }

        return lines.joined(separator: "\n")
    }

    static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite, fraction > 0 else { return "0%" }
        if fraction < 0.01 { return "<1%" }
        return "\(Int((fraction * 100).rounded()))%"
    }
}
