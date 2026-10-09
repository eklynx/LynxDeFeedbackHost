//
//  DFHWorkers.cpp
//  DeFeedbackHost
//

#include "DFHWorkers.h"

#include <atomic>
#include <cstring>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_act.h>
#include <mach/thread_policy.h>
#include <new>
#include <os/workgroup.h>
#include <pthread.h>
#include <sys/sysctl.h>

// The deliberate hole in the realtime guarantee, admitted in one place and in the open.
//
// `semaphore_signal` doesn't block. `semaphore_wait` does — that is the entire point of a join, so
// no annotation can make it honest, and this is a promise rather than a proof. What bounds it: the
// only thing being waited on is a worker running at the same deadline in the same workgroup, so
// the kernel knows the I/O thread's progress depends on it. See `dfh_worker_pool_run`.
extern "C" kern_return_t semaphore_signal(semaphore_t) CA_REALTIME_API;
extern "C" kern_return_t semaphore_wait(semaphore_t) CA_REALTIME_API;

namespace {

/// Hard ceiling. Beyond a handful of workers the fan-out/join cost grows faster than the work
/// being split, and a host that grabs every core is a bad citizen on a machine also running a DAW.
constexpr int32_t kMaximumWorkerCount = 8;

struct Worker;

}  // namespace

struct DFHWorkerPoolOpaque {
    Worker* workers = nullptr;
    int32_t threadCount = 0;

    os_workgroup_t _Nullable workgroup = nullptr;
    double bufferPeriodNanoseconds = 0;

    /// Published by the I/O thread before signalling, read by workers after waking. The semaphore
    /// pair supplies the ordering, but these stay atomic so the race is expressed rather than
    /// implied.
    std::atomic<DFHWorkerTask> task{nullptr};
    std::atomic<void*> context{nullptr};

    /// Signalled once per finishing worker; the I/O thread waits on it `threadCount` times.
    semaphore_t doneSemaphore = MACH_PORT_NULL;

    std::atomic<bool> shouldRun{true};
};

namespace {

struct Worker {
    pthread_t thread{};
    semaphore_t startSemaphore = MACH_PORT_NULL;
    DFHWorkerPoolOpaque* pool = nullptr;
    int32_t index = 0;
    bool started = false;

    /// Filled in by the worker before its first wait and read from other threads afterwards.
    ///
    /// `publishedPort` is the release/acquire handshake that makes that read well-defined: the
    /// worker writes every field of `info` first and stores the port last. A reader that sees a
    /// non-zero port is therefore guaranteed to see the rest. Without it, asking about a worker
    /// before the first render cycle would be a plain data race.
    DFHWorkerInfo info{};
    std::atomic<uint32_t> publishedPort{0};
};

/// Nanoseconds to mach absolute time units.
uint64_t nanosecondsToAbsolute(double nanoseconds) {
    mach_timebase_info_data_t timebase{};
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.numer == 0) return 0;
    return (uint64_t)(nanoseconds * (double)timebase.denom / (double)timebase.numer);
}

/// Puts the calling thread in the realtime band with the I/O thread's deadline.
///
/// Belt and braces alongside the workgroup join: the workgroup tells the kernel these threads
/// share a deadline, the time-constraint policy is what actually places them in the realtime
/// scheduling band. Probe 0.2 confirmed a `pthread_create`d thread accepts both.
bool applyTimeConstraintPolicy(double bufferPeriodNanoseconds) {
    const uint64_t period = nanosecondsToAbsolute(bufferPeriodNanoseconds);
    if (period == 0) return false;

    thread_time_constraint_policy_data_t policy{};
    policy.period = (uint32_t)period;
    // Half the budget: enough that the kernel schedules us promptly, not so much that we claim
    // the whole period and crowd out the I/O thread we're working for.
    policy.computation = (uint32_t)(period / 2);
    policy.constraint = (uint32_t)period;
    policy.preemptible = 0;

    const kern_return_t status =
        thread_policy_set(pthread_mach_thread_np(pthread_self()),
                          THREAD_TIME_CONSTRAINT_POLICY,
                          (thread_policy_t)&policy,
                          THREAD_TIME_CONSTRAINT_POLICY_COUNT);
    return status == KERN_SUCCESS;
}

/// Reads back what the kernel actually did, from this thread about itself — the only vantage point
/// from which `thread_policy_get` tells the truth.
void recordOwnPolicy(DFHWorkerInfo& info) {
    info.machPort = pthread_mach_thread_np(pthread_self());

    thread_time_constraint_policy_data_t policy{};
    mach_msg_type_number_t count = THREAD_TIME_CONSTRAINT_POLICY_COUNT;
    boolean_t usingDefaults = 0;

    // `pthread_mach_thread_np` rather than `mach_thread_self`, which returns a send right the
    // caller then has to deallocate.
    const kern_return_t status = thread_policy_get(info.machPort,
                                                   THREAD_TIME_CONSTRAINT_POLICY,
                                                   (thread_policy_t)&policy,
                                                   &count,
                                                   &usingDefaults);
    if (status != KERN_SUCCESS) return;

    info.timeConstraintApplied = usingDefaults == 0;
    info.period = policy.period;
    info.computation = policy.computation;
    info.constraint = policy.constraint;
}

void* workerMain(void* argument) {
    Worker* worker = (Worker*)argument;
    DFHWorkerPoolOpaque* pool = worker->pool;

    pthread_setname_np("DeFeedbackHost render worker");

    os_workgroup_join_token_s joinToken{};
    bool joined = false;
    if (pool->workgroup != nullptr) {
        joined = os_workgroup_join(pool->workgroup, &joinToken) == 0;
    }

    applyTimeConstraintPolicy(pool->bufferPeriodNanoseconds);
    recordOwnPolicy(worker->info);
    worker->info.joinedWorkgroup = joined;
    worker->publishedPort.store(worker->info.machPort, std::memory_order_release);

    // Not CA_REALTIME_API, and honestly so: everything above genuinely blocks. The compiler's
    // guarantee applies to `task`, which is where the DSP is.
    while (true) {
        semaphore_wait(worker->startSemaphore);
        if (!pool->shouldRun.load(std::memory_order_acquire)) break;

        DFHWorkerTask task = pool->task.load(std::memory_order_acquire);
        void* context = pool->context.load(std::memory_order_relaxed);
        if (task != nullptr) task(context, worker->index, pool->threadCount + 1);

        semaphore_signal(pool->doneSemaphore);
    }

    if (joined) os_workgroup_leave(pool->workgroup, &joinToken);
    return nullptr;
}

/// The device workgroup, at +1 — the property getter hands over a reference the caller owns.
os_workgroup_t _Nullable copyWorkgroup(AudioUnit _Nullable outputUnit) {
    if (outputUnit == nullptr) return nullptr;

    os_workgroup_t workgroup = nullptr;
    UInt32 size = sizeof(workgroup);
    if (AudioUnitGetProperty(outputUnit, kAudioOutputUnitProperty_OSWorkgroup,
                             kAudioUnitScope_Global, 0, &workgroup, &size) != noErr) {
        return nullptr;
    }
    return workgroup;
}

int32_t readSysctlCount(const char* name) {
    int32_t value = 0;
    size_t size = sizeof(value);
    if (sysctlbyname(name, &value, &size, nullptr, 0) != 0) return 0;
    return value;
}

}  // namespace

extern "C" int32_t dfh_worker_pool_recommended_worker_count(void) {
    // On a CPU with separate performance and efficiency cores, only the performance ones are
    // worth using: a render partition landing on an efficiency core takes several times as long,
    // and every other worker waits for it at the join.
    int32_t cores = readSysctlCount("hw.perflevel0.logicalcpu");
    if (cores <= 0) cores = readSysctlCount("hw.ncpu");
    if (cores <= 0) cores = 1;
    return cores < kMaximumWorkerCount ? cores : kMaximumWorkerCount;
}

extern "C" DFHWorkerPoolRef dfh_worker_pool_create(int32_t threadCount,
                                                   AudioUnit outputUnit,
                                                   double bufferPeriodNanoseconds) {
    if (threadCount < 0) threadCount = 0;
    if (threadCount > kMaximumWorkerCount - 1) threadCount = kMaximumWorkerCount - 1;

    DFHWorkerPoolOpaque* pool = new (std::nothrow) DFHWorkerPoolOpaque();
    if (pool == nullptr) return nullptr;

    pool->threadCount = threadCount;
    pool->bufferPeriodNanoseconds = bufferPeriodNanoseconds;
    pool->workgroup = copyWorkgroup(outputUnit);

    if (threadCount == 0) return (DFHWorkerPoolRef)pool;

    if (semaphore_create(mach_task_self(), &pool->doneSemaphore, SYNC_POLICY_FIFO, 0) !=
        KERN_SUCCESS) {
        dfh_worker_pool_destroy((DFHWorkerPoolRef)pool);
        return nullptr;
    }

    pool->workers = new (std::nothrow) Worker[threadCount];
    if (pool->workers == nullptr) {
        dfh_worker_pool_destroy((DFHWorkerPoolRef)pool);
        return nullptr;
    }

    for (int32_t index = 0; index < threadCount; ++index) {
        Worker& worker = pool->workers[index];
        worker.pool = pool;
        // Index 0 is the I/O thread, so the threads are 1..threadCount.
        worker.index = index + 1;

        if (semaphore_create(mach_task_self(), &worker.startSemaphore, SYNC_POLICY_FIFO, 0) !=
            KERN_SUCCESS) {
            dfh_worker_pool_destroy((DFHWorkerPoolRef)pool);
            return nullptr;
        }
        if (pthread_create(&worker.thread, nullptr, workerMain, &worker) != 0) {
            dfh_worker_pool_destroy((DFHWorkerPoolRef)pool);
            return nullptr;
        }
        worker.started = true;
    }

    return (DFHWorkerPoolRef)pool;
}

extern "C" void dfh_worker_pool_destroy(DFHWorkerPoolRef opaque) {
    DFHWorkerPoolOpaque* pool = (DFHWorkerPoolOpaque*)opaque;
    if (pool == nullptr) return;

    pool->shouldRun.store(false, std::memory_order_release);

    if (pool->workers != nullptr) {
        // Wake every worker so it can observe shouldRun and fall out of its loop.
        for (int32_t index = 0; index < pool->threadCount; ++index) {
            if (pool->workers[index].startSemaphore != MACH_PORT_NULL) {
                semaphore_signal(pool->workers[index].startSemaphore);
            }
        }
        for (int32_t index = 0; index < pool->threadCount; ++index) {
            Worker& worker = pool->workers[index];
            if (worker.started) pthread_join(worker.thread, nullptr);
            if (worker.startSemaphore != MACH_PORT_NULL) {
                semaphore_destroy(mach_task_self(), worker.startSemaphore);
            }
        }
        delete[] pool->workers;
    }

    if (pool->doneSemaphore != MACH_PORT_NULL) {
        semaphore_destroy(mach_task_self(), pool->doneSemaphore);
    }
    if (pool->workgroup != nullptr) os_release(pool->workgroup);

    delete pool;
}

extern "C" int32_t dfh_worker_pool_worker_count(DFHWorkerPoolRef opaque) CA_REALTIME_API {
    DFHWorkerPoolOpaque* pool = (DFHWorkerPoolOpaque*)opaque;
    return pool == nullptr ? 1 : pool->threadCount + 1;
}

extern "C" int32_t dfh_worker_pool_thread_count(DFHWorkerPoolRef opaque) {
    DFHWorkerPoolOpaque* pool = (DFHWorkerPoolOpaque*)opaque;
    return pool == nullptr ? 0 : pool->threadCount;
}

extern "C" void dfh_worker_pool_run(DFHWorkerPoolRef opaque, DFHWorkerTask task,
                                    void* context) CA_REALTIME_API {
    DFHWorkerPoolOpaque* pool = (DFHWorkerPoolOpaque*)opaque;
    if (pool == nullptr || task == nullptr) return;

    const int32_t threadCount = pool->threadCount;
    if (threadCount == 0) {
        task(context, 0, 1);
        return;
    }

    pool->context.store(context, std::memory_order_relaxed);
    pool->task.store(task, std::memory_order_release);

    for (int32_t index = 0; index < threadCount; ++index) {
        semaphore_signal(pool->workers[index].startSemaphore);
    }

    // The I/O thread takes a share rather than idling through the cycle.
    task(context, 0, threadCount + 1);

    for (int32_t index = 0; index < threadCount; ++index) {
        semaphore_wait(pool->doneSemaphore);
    }
}

extern "C" DFHWorkerInfo dfh_worker_pool_worker_info(DFHWorkerPoolRef opaque, int32_t index) {
    DFHWorkerPoolOpaque* pool = (DFHWorkerPoolOpaque*)opaque;
    DFHWorkerInfo empty{};
    if (pool == nullptr || pool->workers == nullptr) return empty;
    if (index < 0 || index >= pool->threadCount) return empty;

    // A worker that hasn't finished configuring itself reports nothing rather than half of
    // something. Callers treat a zero port as "hasn't started yet".
    if (pool->workers[index].publishedPort.load(std::memory_order_acquire) == 0) return empty;
    return pool->workers[index].info;
}
