//
//  DFHWorkers.h
//  DeFeedbackHost
//
//  A fixed pool of realtime worker threads for rendering plugin instances in parallel.
//
//  Deliberately generic: the pool knows nothing about slots or audio units. It runs one task
//  function across N workers and waits for them all. That keeps the fan-out/join machinery — the
//  part with the interesting concurrency — separable from the render loop and testable on its own.
//
//  The workers are joined to the audio device's `os_workgroup` and given
//  THREAD_TIME_CONSTRAINT_POLICY, following "Adding Parallel Real-Time Threads to Audio
//  Workgroups". Joining tells the kernel these threads share the I/O thread's deadline; it is the
//  reason this is worth doing at all rather than just spawning high-priority threads.
//
//  Note the one honest caveat: the join at the end of a cycle blocks the I/O thread on a Mach
//  semaphore. See `dfh_worker_pool_run`.
//
//  - AI used for the C engine code to simplify setup and focus on speed and efficient resource usage

#ifndef DFHWorkers_h
#define DFHWorkers_h

#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

typedef struct DFHWorkerPoolOpaque* DFHWorkerPoolRef;

/// One worker's share of a cycle. `workerIndex` is in `[0, workerCount)`, and index 0 is always
/// the calling I/O thread, so a task partitions its work by those two numbers alone.
typedef void (*DFHWorkerTask)(void* _Nullable context,
                              int32_t workerIndex,
                              int32_t workerCount) CA_REALTIME_API;

/// What a worker observed about its own scheduling, recorded once at start-up.
///
/// Self-reported on purpose. `thread_policy_get` only returns the real answer when a thread asks
/// about *itself* — queried across threads it reports defaults, which is what made the host's
/// realtime check produce a false negative once already. A worker measuring itself and publishing
/// the result sidesteps that entirely.
typedef struct {
    /// Mach port of the worker thread. Zero until the thread has started.
    uint32_t machPort;
    /// Whether `os_workgroup_join` succeeded. False when no workgroup was supplied.
    bool joinedWorkgroup;
    /// Whether the thread confirmed a non-default time-constraint policy on itself.
    bool timeConstraintApplied;
    /// The time-constraint parameters as the kernel reports them, in mach absolute time units.
    uint32_t period;
    uint32_t computation;
    uint32_t constraint;
} DFHWorkerInfo;

/// Creates and starts `threadCount` worker threads.
///
/// - Parameters:
///   - threadCount: extra threads beyond the calling I/O thread. Zero is valid and yields a pool
///     that runs everything inline.
///   - outputUnit: the output AUHAL, used to fetch the device workgroup. May be NULL, in which
///     case the workers still get a time-constraint policy but join no workgroup — that is the
///     shape the tests use, and it is a genuinely weaker configuration.
///   - bufferPeriodNanoseconds: the I/O deadline, used for the time-constraint policy.
///
/// Called from the main thread while stopped: it allocates and creates threads.
DFHWorkerPoolRef _Nullable dfh_worker_pool_create(int32_t threadCount,
                                                  AudioUnit _Nullable outputUnit,
                                                  double bufferPeriodNanoseconds);

/// Stops and joins every worker, then frees the pool. Must not overlap a `dfh_worker_pool_run`.
void dfh_worker_pool_destroy(DFHWorkerPoolRef pool);

/// Total participants in a cycle: the worker threads plus the calling thread.
///
/// Annotated because the render loop needs it to walk the accumulators. It is a null check and a
/// field read — cheaper than caching a copy in the engine and then having two places to keep in
/// step.
int32_t dfh_worker_pool_worker_count(DFHWorkerPoolRef pool) CA_REALTIME_API;

/// How many cores the machine would sensibly dedicate to rendering, including the I/O thread.
/// Counts performance cores where the CPU distinguishes them — scheduling audio onto efficiency
/// cores is worse than not parallelising at all.
int32_t dfh_worker_pool_recommended_worker_count(void);

/// Runs `task` on every worker and returns once they have all finished.
///
/// The calling thread runs worker 0 itself rather than idling, so the pool costs one wake-up per
/// *extra* worker.
///
/// **This is the one place the realtime guarantee is relaxed by design.** The join is a
/// `semaphore_wait` on the I/O thread: a blocking call, admitted here by an explicit trust
/// declaration rather than proven by the compiler. The wait is bounded by the slowest worker, and
/// the workers run at the same deadline in the same workgroup, so the kernel understands the
/// dependency — but it is a hole, and it is here rather than scattered.
void dfh_worker_pool_run(DFHWorkerPoolRef pool,
                         DFHWorkerTask task,
                         void* _Nullable context) CA_REALTIME_API;

/// Scheduling as worker `index` measured it on itself. Out-of-range indices return a zeroed struct.
DFHWorkerInfo dfh_worker_pool_worker_info(DFHWorkerPoolRef pool, int32_t index);

/// Number of worker *threads* — one less than `dfh_worker_pool_worker_count`.
int32_t dfh_worker_pool_thread_count(DFHWorkerPoolRef pool);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif /* DFHWorkers_h */
