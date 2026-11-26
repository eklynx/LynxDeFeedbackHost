//
//  EngineDiagnostics.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/20/2026.
//

/// A snapshot of how the running engine is doing, read by the control bar and the web status.
/// `AudioHost.Diagnostics` is the name callers use.
struct EngineDiagnostics {
    let captureCycles: UInt64
    let renderCycles: UInt64
    let underruns: UInt64

    /// dsp load is fraction of buffer that is used.  when this maxes we get audio glitches.
    let dspLoad: Double
    let peakDspLoad: Double

    let renderThreadPolicy: RealtimeThreadPolicy?
    let captureThreadPolicy: RealtimeThreadPolicy?

    /// The worker threads. Empty unless parallel rendering is on.
    let workerThreadPolicies: [RealtimeThreadPolicy]

    /// Whether paralell rendering is actually happening, as opposed to being permitted to but
    /// sitting under the instance threshold.
    let parallelRenderingEngaged: Bool

    var hasRendered: Bool { renderCycles > 0 }

    /// Checks if all rendering threads are set to realtime priority
    var audioThreadsAreRealtime: Bool {
        for policy in [renderThreadPolicy, captureThreadPolicy] {
            guard let policy else { continue }
            if !policy.isRealtime { return false }
        }
        return workerThreadPolicies.allSatisfy(\.isRealtime)
    }
}
