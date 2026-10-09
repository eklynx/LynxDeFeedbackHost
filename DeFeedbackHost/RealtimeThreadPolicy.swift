//
//  RealtimeThreadPolicy.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/20/2026.

import Darwin

/// A snapshot of how the kernel is scheduling one thread.
///
/// Exists to *verify* rather than to change anything. CoreAudio creates the device I/O threads and
/// puts them under `THREAD_TIME_CONSTRAINT_POLICY`, which is the realtime band and strictly better
/// than anything reachable with `pthread_setschedparam` or a QoS class — so the host's job is to
/// confirm its audio work is happening there, not to touch the priority.
///
///  - Created by AI to verfiy thread policy
struct RealtimeThreadPolicy: Equatable {

    /// Why two signals rather than one: neither is visible in every situation.
    enum Evidence: Equatable {
        /// `thread_policy_get` reported an explicit time-constraint policy. Only observable when
        /// the thread is queried from *itself*.
        case timeConstraintPolicy
        /// `SCHED_FIFO` above the POSIX-exposed maximum priority — the realtime band. This is what
        /// a CoreAudio I/O thread shows when queried cross-thread through its mach port.
        case realtimeSchedulingBand
        /// Neither signal present.
        case none
    }

    let evidence: Evidence

    /// `SCHED_FIFO`, `SCHED_RR` or `SCHED_OTHER`.
    let schedulingPolicy: Int32

    /// POSIX priority. Realtime audio threads sit at 63, above the 47 that
    /// `sched_get_priority_max(SCHED_FIFO)` reports, because the realtime band is above the range
    /// POSIX exposes.
    let priority: Int32

    /// Time-constraint parameters, in mach absolute time units. All zero when the policy was
    /// queried cross-thread, which does not mean the thread isn't realtime — see `Evidence`.
    let period: UInt32
    let computation: UInt32
    let constraint: UInt32
    let isPreemptible: Bool

    /// Only meaningful for the host's own render workers: the CoreAudio I/O threads are placed in
    /// the device workgroup by the system, and there's no need to ask.
    var joinedWorkgroup = false

    var isRealtime: Bool { evidence != .none }

    var summary: String {
        // Priority is omitted where it wasn't measurable rather than printed as -1.
        let detail = priority >= 0 ? ", priority \(priority)" : ""
        switch evidence {
        case .timeConstraintPolicy:
            return "realtime, time-constraint\(detail)\(workgroupSuffix)"
        case .realtimeSchedulingBand:
            return "realtime, scheduling band\(detail)\(workgroupSuffix)"
        case .none:
            return "not realtime (policy \(schedulingPolicy)\(detail))"
        }
    }

    private var workgroupSuffix: String { joinedWorkgroup ? ", in the device workgroup" : "" }

    /// Reads the policy of the thread identified by `port`.
    ///
    /// Deliberately callable from any thread *other* than the audio thread: `thread_policy_get` is
    /// a Mach trap, and a syscall has no business in a render callback. `CoreAudioEngineControl` captures
    /// the port cheaply during rendering and the main thread inspects it here.
    ///
    /// The cross-thread limitation is the reason `Evidence` exists. Measured on a live CoreAudio
    /// I/O thread: queried from the thread itself, `thread_policy_get` returns
    /// `period/computation/constraint = 256000` with `usingDefaults == 0`; queried from the main
    /// thread through the same thread's port, it returns zeros and `usingDefaults != 0` while the
    /// POSIX view still correctly shows `SCHED_FIFO` at priority 63. Trusting only the Mach answer
    /// therefore reports a healthy audio thread as non-realtime.
    static func read(port: mach_port_t) -> RealtimeThreadPolicy? {
        guard port != 0 else { return nil }

        var timeConstraint = thread_time_constraint_policy()
        var count = mach_msg_type_number_t(
            MemoryLayout<thread_time_constraint_policy>.size / MemoryLayout<integer_t>.size)
        var usingDefaults = boolean_t(0)

        let status = withUnsafeMutablePointer(to: &timeConstraint) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                thread_policy_get(port,
                                  thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY),
                                  raw, &count, &usingDefaults)
            }
        }
        guard status == KERN_SUCCESS else { return nil }

        // The POSIX view needs a pthread handle rather than a mach port. It's a second opinion, so
        // a failure here shouldn't discard the Mach answer.
        var schedulingPolicy: Int32 = -1
        var priority: Int32 = -1
        if let thread = pthread_from_mach_thread_np(port) {
            var parameters = sched_param()
            if pthread_getschedparam(thread, &schedulingPolicy, &parameters) == 0 {
                priority = parameters.sched_priority
            }
        }

        return RealtimeThreadPolicy(
            evidence: evidence(usingDefaults: usingDefaults,
                               schedulingPolicy: schedulingPolicy,
                               priority: priority),
            schedulingPolicy: schedulingPolicy,
            priority: priority,
            period: timeConstraint.period,
            computation: timeConstraint.computation,
            constraint: timeConstraint.constraint,
            isPreemptible: timeConstraint.preemptible != 0)
    }

    /// Exposed for testing so the two signals can be checked without a live audio device.
    static func evidence(usingDefaults: boolean_t,
                         schedulingPolicy: Int32,
                         priority: Int32) -> Evidence {
        if usingDefaults == 0 { return .timeConstraintPolicy }

        // Above the priority POSIX will admit to is the realtime band. `sched_get_priority_max`
        // reports 47; CoreAudio's I/O threads run at 63.
        if schedulingPolicy == SCHED_FIFO, priority > sched_get_priority_max(SCHED_FIFO) {
            return .realtimeSchedulingBand
        }

        return .none
    }
}

extension RealtimeThreadPolicy {

    /// Builds a snapshot from a render worker's own measurement of itself.
    ///
    /// In an extension so the memberwise initialiser `read(port:)` uses stays synthesised.
    ///
    /// Worker threads can't be checked the way the CoreAudio I/O threads are: both of the signals
    /// `read(port:)` relies on are unavailable here. `thread_policy_get` reports defaults when
    /// asked across threads, and the POSIX view of a Mach-set policy is wrong in the
    /// other direction — probe 0.2 measured a confirmed-realtime worker reporting `SCHED_OTHER`
    /// at priority 31. So each worker reads its own policy at start-up, where the answer is
    /// authoritative, and this carries it across.
    ///
    /// Returns `nil` for a worker that hasn't started yet.
    init?(worker: DFHWorkerInfo) {
        guard worker.machPort != 0 else { return nil }

        self.init(evidence: worker.timeConstraintApplied ? .timeConstraintPolicy : .none,
                  // Deliberately blank: the POSIX view of these threads is actively misleading,
                  // and a wrong number is worse than none.
                  schedulingPolicy: -1,
                  priority: -1,
                  period: worker.period,
                  computation: worker.computation,
                  constraint: worker.constraint,
                  isPreemptible: false,
                  joinedWorkgroup: worker.joinedWorkgroup)
    }
}
