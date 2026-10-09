//
//  DFHEngine.cpp
//  DeFeedbackHost
//
//  The realtime audio engine control in pure C++. No conversion to swift interop so we dont deal with
//  delays due to ARC.  Thread should be run in realtime priority scheduling, and non-blocking.
//
//  - AI used for the C engine code to simplify setup and focus on speed and efficient resource usage

#include "DFHEngine.h"
#include "DFHRingBuffer.h"

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <mach/mach_init.h>
#include <new>
#include <pthread.h>
#include <time.h>

// libc/pthread entry points we choose to trust, admitted one at a time. CoreAudio needs none of
// this: the SDK already marks AudioUnitRender, AURenderCallback and the rest CA_REALTIME_API.
// - Thanks to AI for helping me through this.
extern "C" uint64_t clock_gettime_nsec_np(clockid_t) CA_REALTIME_API;
extern "C" pthread_t pthread_self(void) CA_REALTIME_API;
extern "C" mach_port_t pthread_mach_thread_np(pthread_t) CA_REALTIME_API;

namespace {

constexpr int32_t kMaximumSlotCount = 32;
constexpr int32_t kMaximumBusChannels = 2;

AudioBufferList* allocateBufferList(int32_t bufferCount) {
    const size_t bytes =
        sizeof(AudioBufferList) + sizeof(AudioBuffer) * (size_t)(bufferCount > 0 ? bufferCount - 1 : 0);
    AudioBufferList* list = (AudioBufferList*)std::calloc(1, bytes);
    if (list != nullptr) list->mNumberBuffers = (UInt32)bufferCount;
    return list;
}

}  // namespace


// MARK: - Slot

struct DFHSlotOpaque {
    std::atomic<bool> isActive{false};
    std::atomic<bool> isMuted{false};
    std::atomic<bool> isBypassed{false};
    std::atomic<int32_t> inputChannel{0};
    std::atomic<int32_t> outputChannel{0};

    bool isClaimed = false;

    AudioUnit unit = nullptr;
    DFHRenderFunction renderFunction = nullptr;
    void* renderContext = nullptr;
    int32_t busChannelCount = 1;
    bool providesOwnOutputBuffer = false;
    AudioBufferList* outputBufferList = nullptr;

    // fallabck scratch buffer
    float* outputScratch = nullptr;

    int32_t maximumFrameCount = 0;
    struct DFHEngineOpaque* engine = nullptr;

    void prepareOutputBuffers(int32_t frameCount) CA_REALTIME_API {
        outputBufferList->mNumberBuffers = (UInt32)busChannelCount;
        for (int32_t index = 0; index < busChannelCount; ++index) {
            outputBufferList->mBuffers[index].mNumberChannels = 1;
            if (providesOwnOutputBuffer) {
                // Null means "render into your own buffer and tell us where it is".
                outputBufferList->mBuffers[index].mDataByteSize = 0;
                outputBufferList->mBuffers[index].mData = nullptr;
            } else {
                outputBufferList->mBuffers[index].mDataByteSize =
                    (UInt32)((size_t)frameCount * sizeof(float));
                outputBufferList->mBuffers[index].mData =
                    outputScratch + (size_t)index * maximumFrameCount;
            }
        }
    }
};


// MARK: - Engine

struct DFHEngineOpaque {
    int32_t maximumFrameCount = 0;
    int32_t inputChannelCount = 0;
    int32_t outputChannelCount = 0;
    double sampleRate = 0;

    dfh::RingBuffer* ringBuffer = nullptr;

    float* inputScratch = nullptr;

    float* silence = nullptr;

    AudioBufferList* captureBufferList = nullptr;
    float* captureScratch = nullptr;

    DFHSlotOpaque* slots = nullptr;

    AudioUnit inputUnit = nullptr;

    
    // MARK: Parallel rendering

    DFHWorkerPoolRef workers = nullptr;
    bool parallelRequested = false;
    int32_t parallelThreshold = 0;

    std::atomic<int32_t> activeSlotCount{0};
    std::atomic<bool> parallelEngaged{false};

    float* workerAccumulators = nullptr;
    size_t accumulatorStride = 0;

    float** workerDestinations = nullptr;
    float** deviceDestinations = nullptr;

    std::atomic<uint64_t> captureCycleCount{0};
    std::atomic<uint64_t> renderCycleCount{0};
    std::atomic<uint64_t> underrunCount{0};
    std::atomic<uint64_t> smoothedRenderNanoseconds{0};
    std::atomic<uint64_t> peakRenderNanoseconds{0};
    std::atomic<uint32_t> renderThreadPort{0};
    std::atomic<uint32_t> captureThreadPort{0};

    
    void recordRenderDuration(uint64_t nanoseconds) CA_REALTIME_API {
        const int64_t sample = (int64_t)nanoseconds;
        const int64_t previous = (int64_t)smoothedRenderNanoseconds.load(std::memory_order_relaxed);

        const int64_t smoothed = previous <= 0 ? sample : previous + (sample - previous) / 8;
        smoothedRenderNanoseconds.store((uint64_t)smoothed, std::memory_order_relaxed);

        if (nanoseconds > peakRenderNanoseconds.load(std::memory_order_relaxed)) {
            peakRenderNanoseconds.store(nanoseconds, std::memory_order_relaxed);
        }
    }
};

namespace {

OSStatus slotInputCallback(void* refCon, AudioUnitRenderActionFlags*, const AudioTimeStamp*,
                           UInt32, UInt32 frameCount,
                           AudioBufferList* ioData) CA_REALTIME_API {
    DFHSlotOpaque* slot = (DFHSlotOpaque*)refCon;
    if (ioData == nullptr || slot == nullptr || slot->engine == nullptr) return noErr;

    DFHEngineOpaque* engine = slot->engine;
    const int32_t channel = slot->inputChannel.load(std::memory_order_relaxed);
    const float* source = (channel >= 0 && channel < engine->inputChannelCount)
                              ? engine->inputScratch + (size_t)channel * engine->maximumFrameCount
                              : engine->silence;

    const size_t count = frameCount < (UInt32)slot->maximumFrameCount
                             ? (size_t)frameCount
                             : (size_t)slot->maximumFrameCount;

    for (uint32_t index = 0; index < ioData->mNumberBuffers; ++index) {
        ioData->mBuffers[index].mNumberChannels = 1;
        if (ioData->mBuffers[index].mData != nullptr) {
            //copy data from the buffer
            std::memcpy(ioData->mBuffers[index].mData, source, count * sizeof(float));
        } else {
            ioData->mBuffers[index].mData = (void*)source;
        }
        ioData->mBuffers[index].mDataByteSize = (UInt32)(count * sizeof(float));
    }
    return noErr;
}

/// Try mono first, then stereo. Units that insist on stereo get the mono signal in both channels.
int32_t negotiateBuses(AudioUnit unit, double sampleRate) {
    for (int32_t channels = 1; channels <= kMaximumBusChannels; ++channels) {
        AudioStreamBasicDescription format{};
        format.mSampleRate = sampleRate;
        format.mFormatID = kAudioFormatLinearPCM;
        format.mFormatFlags =
            kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
        format.mBytesPerPacket = sizeof(float);
        format.mFramesPerPacket = 1;
        format.mBytesPerFrame = sizeof(float);
        format.mChannelsPerFrame = (UInt32)channels;
        format.mBitsPerChannel = 32;

        if (AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                 &format, sizeof(format)) != noErr) {
            continue;
        }
        if (AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0,
                                 &format, sizeof(format)) != noErr) {
            continue;
        }
        return channels;
    }
    return 0;
}

}  // namespace


// MARK: - Ring buffer

extern "C" DFHRingBufferRef dfh_ring_buffer_create(int32_t channelCount, int32_t capacityFrames) {
    return (DFHRingBufferRef)new (std::nothrow) dfh::RingBuffer(channelCount, capacityFrames);
}

extern "C" void dfh_ring_buffer_destroy(DFHRingBufferRef ringBuffer) {
    delete (dfh::RingBuffer*)ringBuffer;
}

extern "C" int32_t dfh_ring_buffer_channel_count(DFHRingBufferRef ringBuffer) {
    return ringBuffer == nullptr ? 0 : ((dfh::RingBuffer*)ringBuffer)->channelCount();
}

extern "C" int32_t dfh_ring_buffer_capacity_frames(DFHRingBufferRef ringBuffer) {
    return ringBuffer == nullptr ? 0 : ((dfh::RingBuffer*)ringBuffer)->capacityFrames();
}

extern "C" int32_t dfh_ring_buffer_frames_available(DFHRingBufferRef ringBuffer) {
    return ringBuffer == nullptr ? 0 : ((dfh::RingBuffer*)ringBuffer)->framesAvailable();
}

extern "C" void dfh_ring_buffer_prime_with_silence(DFHRingBufferRef ringBuffer,
                                                   int32_t frameCount) {
    if (ringBuffer != nullptr) ((dfh::RingBuffer*)ringBuffer)->primeWithSilence(frameCount);
}

extern "C" void dfh_ring_buffer_write(DFHRingBufferRef ringBuffer,
                                      const AudioBufferList* bufferList, int32_t frameCount) {
    if (ringBuffer != nullptr) ((dfh::RingBuffer*)ringBuffer)->write(bufferList, frameCount);
}

extern "C" bool dfh_ring_buffer_read(DFHRingBufferRef ringBuffer, float* destination,
                                     int32_t stride, int32_t frameCount) {
    if (ringBuffer == nullptr) return false;
    return ((dfh::RingBuffer*)ringBuffer)->read(destination, stride, frameCount);
}


// MARK: - Engine lifecycle

extern "C" int32_t dfh_engine_maximum_slot_count(void) { return kMaximumSlotCount; }

extern "C" DFHEngineRef dfh_engine_create(int32_t maximumFrameCount,
                                          int32_t inputChannelCount,
                                          int32_t outputChannelCount,
                                          double sampleRate,
                                          int32_t ringBufferDepthInBuffers) {
    DFHEngineOpaque* engine = new (std::nothrow) DFHEngineOpaque();
    if (engine == nullptr) return nullptr;

    engine->maximumFrameCount = maximumFrameCount > 1 ? maximumFrameCount : 1;
    engine->inputChannelCount = inputChannelCount > 1 ? inputChannelCount : 1;
    engine->outputChannelCount = outputChannelCount > 1 ? outputChannelCount : 1;
    engine->sampleRate = sampleRate;

    const int32_t depth = ringBufferDepthInBuffers > 1 ? ringBufferDepthInBuffers : 1;
    engine->ringBuffer = new (std::nothrow)
        dfh::RingBuffer(engine->inputChannelCount, engine->maximumFrameCount * depth);

    const size_t scratchCount = (size_t)engine->inputChannelCount * engine->maximumFrameCount;
    engine->inputScratch = new (std::nothrow) float[scratchCount]();
    engine->captureScratch = new (std::nothrow) float[scratchCount]();
    engine->silence = new (std::nothrow) float[engine->maximumFrameCount]();

    engine->deviceDestinations = new (std::nothrow) float*[engine->outputChannelCount]();

    engine->captureBufferList = allocateBufferList(engine->inputChannelCount);
    if (engine->captureBufferList != nullptr) {
        for (int32_t channel = 0; channel < engine->inputChannelCount; ++channel) {
            engine->captureBufferList->mBuffers[channel].mNumberChannels = 1;
            engine->captureBufferList->mBuffers[channel].mDataByteSize =
                (UInt32)((size_t)engine->maximumFrameCount * sizeof(float));
            engine->captureBufferList->mBuffers[channel].mData =
                engine->captureScratch + (size_t)channel * engine->maximumFrameCount;
        }
    }

    engine->slots = new (std::nothrow) DFHSlotOpaque[kMaximumSlotCount];
    if (engine->slots != nullptr) {
        for (int32_t index = 0; index < kMaximumSlotCount; ++index) {
            DFHSlotOpaque& slot = engine->slots[index];
            slot.engine = engine;
            slot.maximumFrameCount = engine->maximumFrameCount;
            slot.outputScratch =
                new (std::nothrow) float[(size_t)engine->maximumFrameCount * kMaximumBusChannels]();
            slot.outputBufferList = allocateBufferList(kMaximumBusChannels);
        }
    }

    if (engine->ringBuffer == nullptr || engine->inputScratch == nullptr ||
        engine->captureScratch == nullptr || engine->silence == nullptr ||
        engine->captureBufferList == nullptr || engine->slots == nullptr ||
        engine->deviceDestinations == nullptr) {
        dfh_engine_destroy((DFHEngineRef)engine);
        return nullptr;
    }

    return (DFHEngineRef)engine;
}

extern "C" void dfh_engine_destroy(DFHEngineRef opaque) {
    DFHEngineOpaque* engine = (DFHEngineOpaque*)opaque;
    if (engine == nullptr) return;

    dfh_engine_stop_workers(opaque);
    delete[] engine->deviceDestinations;

    if (engine->slots != nullptr) {
        for (int32_t index = 0; index < kMaximumSlotCount; ++index) {
            delete[] engine->slots[index].outputScratch;
            std::free(engine->slots[index].outputBufferList);
        }
        delete[] engine->slots;
    }

    std::free(engine->captureBufferList);
    delete[] engine->captureScratch;
    delete[] engine->inputScratch;
    delete[] engine->silence;
    delete engine->ringBuffer;
    delete engine;
}

extern "C" int32_t dfh_engine_maximum_frame_count(DFHEngineRef opaque) {
    DFHEngineOpaque* engine = (DFHEngineOpaque*)opaque;
    return engine == nullptr ? 0 : engine->maximumFrameCount;
}

extern "C" double dfh_engine_sample_rate(DFHEngineRef opaque) {
    DFHEngineOpaque* engine = (DFHEngineOpaque*)opaque;
    return engine == nullptr ? 0 : engine->sampleRate;
}

extern "C" double dfh_engine_buffer_period_nanoseconds(DFHEngineRef opaque) {
    DFHEngineOpaque* engine = (DFHEngineOpaque*)opaque;
    if (engine == nullptr || engine->sampleRate <= 0) return 0;
    return (double)engine->maximumFrameCount / engine->sampleRate * 1e9;
}

extern "C" void dfh_engine_set_input_unit(DFHEngineRef opaque, AudioUnit inputUnit) {
    DFHEngineOpaque* engine = (DFHEngineOpaque*)opaque;
    if (engine != nullptr) engine->inputUnit = inputUnit;
}

extern "C" void dfh_engine_prime_with_silence(DFHEngineRef opaque, int32_t frameCount) {
    DFHEngineOpaque* engine = (DFHEngineOpaque*)opaque;
    if (engine != nullptr) engine->ringBuffer->primeWithSilence(frameCount);
}

extern "C" int32_t dfh_engine_frames_available(DFHEngineRef opaque) {
    DFHEngineOpaque* engine = (DFHEngineOpaque*)opaque;
    return engine == nullptr ? 0 : engine->ringBuffer->framesAvailable();
}

extern "C" void dfh_engine_write_input(DFHEngineRef opaque, const AudioBufferList* bufferList,
                                       int32_t frameCount) {
    DFHEngineOpaque* engine = (DFHEngineOpaque*)opaque;
    if (engine != nullptr) engine->ringBuffer->write(bufferList, frameCount);
}


// MARK: - Realtime priority

extern "C" OSStatus dfh_engine_input_callback(void* _Nonnull refCon,
                                              AudioUnitRenderActionFlags* _Nonnull actionFlags,
                                              const AudioTimeStamp* _Nonnull timestamp,
                                              UInt32 busNumber,
                                              UInt32 frameCount,
                                              AudioBufferList* _Nullable) CA_REALTIME_API {
    DFHEngineOpaque* engine = (DFHEngineOpaque*)refCon;
    if (engine == nullptr || engine->inputUnit == nullptr) return noErr;

    if (engine->captureThreadPort.load(std::memory_order_relaxed) == 0) {
        engine->captureThreadPort.store(pthread_mach_thread_np(pthread_self()),
                                        std::memory_order_relaxed);
    }

    const int32_t frames = frameCount < (UInt32)engine->maximumFrameCount
                               ? (int32_t)frameCount
                               : engine->maximumFrameCount;
    const UInt32 byteSize = (UInt32)((size_t)frames * sizeof(float));

    engine->captureBufferList->mNumberBuffers = (UInt32)engine->inputChannelCount;
    for (int32_t channel = 0; channel < engine->inputChannelCount; ++channel) {
        engine->captureBufferList->mBuffers[channel].mNumberChannels = 1;
        engine->captureBufferList->mBuffers[channel].mDataByteSize = byteSize;
        engine->captureBufferList->mBuffers[channel].mData =
            engine->captureScratch + (size_t)channel * engine->maximumFrameCount;
    }

    const OSStatus status = AudioUnitRender(engine->inputUnit, actionFlags, timestamp, busNumber,
                                            (UInt32)frames, engine->captureBufferList);
    if (status != noErr) return status;

    engine->ringBuffer->write(engine->captureBufferList, frames);
    engine->captureCycleCount.fetch_add(1, std::memory_order_relaxed);
    return noErr;
}

/// Renders the slots `firstSlot, firstSlot + slotStride, ...` and sums them into `destinations`.
///
/// The stride is what makes one function serve both paths: the I/O thread alone walks every slot
/// with a stride of one, while N workers each take every Nth slot. Round-robin rather than
/// contiguous blocks because retired instances leave holes in the table, and round-robin spreads
/// those holes evenly instead of handing one worker a dead range.
///
/// `destinations` must already be zeroed for `frames`.
static void renderSlots(DFHEngineOpaque* engine, const AudioTimeStamp* timestamp, int32_t frames,
                        float* const* destinations, int32_t destinationCount, int32_t firstSlot,
                        int32_t slotStride) CA_REALTIME_API {
    for (int32_t index = firstSlot; index < kMaximumSlotCount; index += slotStride) {
        DFHSlotOpaque& slot = engine->slots[index];
        if (!slot.isActive.load(std::memory_order_acquire)) continue;

        const int32_t inputChannel = slot.inputChannel.load(std::memory_order_relaxed);
        const float* source = nullptr;

        if (slot.isBypassed.load(std::memory_order_relaxed)) {
            // Bypassed: the input channel goes straight to the output channel, untouched.
            if (inputChannel >= 0 && inputChannel < engine->inputChannelCount) {
                source = engine->inputScratch + (size_t)inputChannel * engine->maximumFrameCount;
            }
        } else {
            slot.prepareOutputBuffers(frames);
            AudioUnitRenderActionFlags flags = 0;
            OSStatus status = kAudioUnitErr_NoConnection;

            if (slot.unit != nullptr) {
                status = AudioUnitRender(slot.unit, &flags, timestamp, 0, (UInt32)frames,
                                         slot.outputBufferList);
            } else if (slot.renderFunction != nullptr) {
                status = slot.renderFunction(slot.renderContext, &flags, timestamp,
                                             (uint32_t)frames, slot.outputBufferList);
            }

            if (status == noErr) {
                source = (const float*)slot.outputBufferList->mBuffers[0].mData;
            }
        }

        if (source == nullptr || slot.isMuted.load(std::memory_order_relaxed)) continue;

        const int32_t channel = slot.outputChannel.load(std::memory_order_relaxed);
        if (channel < 0 || channel >= destinationCount) continue;

        float* destination = destinations[channel];
        if (destination == nullptr) continue;

        // Instances sharing an output channel are summed. Note: should we block this from being possible?
        for (int32_t frame = 0; frame < frames; ++frame) destination[frame] += source[frame];
    }
}


namespace {

struct ParallelJob {
    DFHEngineOpaque* engine;
    const AudioTimeStamp* timestamp;
    int32_t frames;
};


void renderPartition(void* context, int32_t workerIndex, int32_t workerCount) CA_REALTIME_API {
    ParallelJob* job = (ParallelJob*)context;
    DFHEngineOpaque* engine = job->engine;

    const int32_t channels = engine->outputChannelCount;
    float* accumulator = engine->workerAccumulators + (size_t)workerIndex * engine->accumulatorStride;
    float** destinations = engine->workerDestinations + (size_t)workerIndex * channels;

    for (int32_t channel = 0; channel < channels; ++channel) {
        float* buffer = accumulator + (size_t)channel * engine->maximumFrameCount;
        std::memset(buffer, 0, (size_t)job->frames * sizeof(float));
        destinations[channel] = buffer;
    }

    renderSlots(engine, job->timestamp, job->frames, destinations, channels, workerIndex,
                workerCount);
}

bool shouldRenderInParallel(DFHEngineOpaque* engine) CA_REALTIME_API {
    if (engine->workers == nullptr || engine->workerAccumulators == nullptr) return false;
    return engine->activeSlotCount.load(std::memory_order_relaxed) >= engine->parallelThreshold;
}

}  // namespace

/// The render loop. Called from the output device's I/O thread.
static OSStatus renderEngine(DFHEngineOpaque* engine, const AudioTimeStamp* timestamp,
                             uint32_t frameCount, AudioBufferList* output) CA_REALTIME_API {
    const uint64_t startedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);

    if (engine->renderThreadPort.load(std::memory_order_relaxed) == 0) {
        engine->renderThreadPort.store(pthread_mach_thread_np(pthread_self()),
                                       std::memory_order_relaxed);
    }

    const int32_t frames = frameCount < (uint32_t)engine->maximumFrameCount
                               ? (int32_t)frameCount
                               : engine->maximumFrameCount;
    engine->renderCycleCount.fetch_add(1, std::memory_order_relaxed);

    // This cycle's input, for every channel the input device offers.
    if (!engine->ringBuffer->read(engine->inputScratch, engine->maximumFrameCount, frames)) {
        engine->underrunCount.fetch_add(1, std::memory_order_relaxed);
    }

    // Instances sum into the device buffers, so start from silence.
    const uint32_t bufferCount = output->mNumberBuffers;
    for (uint32_t index = 0; index < bufferCount; ++index) {
        if (output->mBuffers[index].mData != nullptr) {
            std::memset(output->mBuffers[index].mData, 0, (size_t)frames * sizeof(float));
        }
    }

    const int32_t channels = bufferCount < (uint32_t)engine->outputChannelCount
                                 ? (int32_t)bufferCount
                                 : engine->outputChannelCount;
    for (int32_t channel = 0; channel < channels; ++channel) {
        engine->deviceDestinations[channel] = (float*)output->mBuffers[channel].mData;
    }

    if (shouldRenderInParallel(engine)) {
        ParallelJob job{engine, timestamp, frames};
        dfh_worker_pool_run(engine->workers, renderPartition, &job);

        // Fold the per-worker accumulators in, in worker order. Doing the summing here rather
        // than in the workers keeps it deterministic — and float addition isn't associative, so
        // "deterministic" is worth more than it sounds.
        const int32_t workerCount = dfh_worker_pool_worker_count(engine->workers);
        for (int32_t worker = 0; worker < workerCount; ++worker) {
            const float* accumulator =
                engine->workerAccumulators + (size_t)worker * engine->accumulatorStride;
            for (int32_t channel = 0; channel < channels; ++channel) {
                float* destination = engine->deviceDestinations[channel];
                if (destination == nullptr) continue;
                const float* source = accumulator + (size_t)channel * engine->maximumFrameCount;
                for (int32_t frame = 0; frame < frames; ++frame) destination[frame] += source[frame];
            }
        }
        engine->parallelEngaged.store(true, std::memory_order_relaxed);
    } else {
        renderSlots(engine, timestamp, frames, engine->deviceDestinations, channels, 0, 1);
        engine->parallelEngaged.store(false, std::memory_order_relaxed);
    }

    engine->recordRenderDuration(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - startedAt);
    return noErr;
}

extern "C" OSStatus dfh_engine_output_callback(void* _Nonnull refCon,
                                               AudioUnitRenderActionFlags* _Nonnull,
                                               const AudioTimeStamp* _Nonnull timestamp, UInt32,
                                               UInt32 frameCount,
                                               AudioBufferList* _Nullable ioData)
    CA_REALTIME_API {
    DFHEngineOpaque* engine = (DFHEngineOpaque*)refCon;
    if (engine == nullptr || ioData == nullptr) return noErr;
    return renderEngine(engine, timestamp, frameCount, ioData);
}

extern "C" OSStatus dfh_engine_render(DFHEngineRef opaque, const AudioTimeStamp* timestamp,
                                      uint32_t frameCount, AudioBufferList* output) {
    DFHEngineOpaque* engine = (DFHEngineOpaque*)opaque;
    if (engine == nullptr || output == nullptr) return noErr;
    return renderEngine(engine, timestamp, frameCount, output);
}

// MARK: - Slots

extern "C" DFHSlotRef dfh_engine_claim_slot(DFHEngineRef opaque) {
    DFHEngineOpaque* engine = (DFHEngineOpaque*)opaque;
    if (engine == nullptr) return nullptr;

    for (int32_t index = 0; index < kMaximumSlotCount; ++index) {
        DFHSlotOpaque& slot = engine->slots[index];
        if (!slot.isClaimed) {
            slot.isClaimed = true;
            return (DFHSlotRef)&slot;
        }
    }
    return nullptr;
}

extern "C" int32_t dfh_engine_install_audiounit(DFHEngineRef opaque, DFHSlotRef slotRef,
                                           AudioUnit unit) {
    DFHEngineOpaque* engine = (DFHEngineOpaque*)opaque;
    DFHSlotOpaque* slot = (DFHSlotOpaque*)slotRef;
    if (engine == nullptr || slot == nullptr || unit == nullptr) return 0;

    // Swift may have left v3 render resources allocated; the engine owns the render configuration
    // from here, so start from an uninitialized unit.
    AudioUnitUninitialize(unit);

    const int32_t channels = negotiateBuses(unit, engine->sampleRate);
    if (channels == 0) return 0;

    UInt32 maximumFrames = (UInt32)engine->maximumFrameCount;
    AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                         &maximumFrames, sizeof(maximumFrames));

    AURenderCallbackStruct callback{};
    callback.inputProc = slotInputCallback;
    callback.inputProcRefCon = slot;
    if (AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                             &callback, sizeof(callback)) != noErr) {
        return 0;
    }

    if (AudioUnitInitialize(unit) != noErr) return 0;

    // Does the unit allocate its own output buffer? If so it is handed a null pointer and the host
    // reads back whichever buffer it rendered into, saving a copy.
    UInt32 shouldAllocate = 1;
    UInt32 size = sizeof(shouldAllocate);
    if (AudioUnitGetProperty(unit, kAudioUnitProperty_ShouldAllocateBuffer, kAudioUnitScope_Output,
                             0, &shouldAllocate, &size) != noErr) {
        shouldAllocate = 1;
    }

    slot->unit = unit;
    slot->renderFunction = nullptr;
    slot->renderContext = nullptr;
    slot->busChannelCount = channels;
    slot->providesOwnOutputBuffer = shouldAllocate != 0;
    if (!slot->isActive.exchange(true, std::memory_order_release)) {
        engine->activeSlotCount.fetch_add(1, std::memory_order_relaxed);
    }
    return channels;
}

extern "C" void dfh_engine_install_function(DFHEngineRef opaque, DFHSlotRef slotRef,
                                            DFHRenderFunction function, void* context,
                                            int32_t busChannelCount,
                                            bool providesOwnOutputBuffer) {
    DFHEngineOpaque* engine = (DFHEngineOpaque*)opaque;
    DFHSlotOpaque* slot = (DFHSlotOpaque*)slotRef;
    if (engine == nullptr || slot == nullptr) return;

    slot->unit = nullptr;
    slot->renderFunction = function;
    slot->renderContext = context;
    slot->busChannelCount = busChannelCount < 1 ? 1
                            : (busChannelCount > kMaximumBusChannels ? kMaximumBusChannels
                                                                     : busChannelCount);
    slot->providesOwnOutputBuffer = providesOwnOutputBuffer;
    if (!slot->isActive.exchange(true, std::memory_order_release)) {
        engine->activeSlotCount.fetch_add(1, std::memory_order_relaxed);
    }
}

extern "C" void dfh_engine_retire_slot(DFHEngineRef opaque, DFHSlotRef slotRef) {
    DFHEngineOpaque* engine = (DFHEngineOpaque*)opaque;
    DFHSlotOpaque* slot = (DFHSlotOpaque*)slotRef;
    if (slot == nullptr) return;

    // Exchange rather than store: retiring an already-retired slot is legal and must not make the
    // active count drift, which would in turn corrupt the parallel-rendering threshold.
    if (slot->isActive.exchange(false, std::memory_order_release) && engine != nullptr) {
        engine->activeSlotCount.fetch_sub(1, std::memory_order_relaxed);
    }
}

extern "C" void dfh_engine_release_slot(DFHEngineRef, DFHSlotRef slotRef) {
    DFHSlotOpaque* slot = (DFHSlotOpaque*)slotRef;
    if (slot == nullptr) return;

    slot->unit = nullptr;
    slot->renderFunction = nullptr;
    slot->renderContext = nullptr;
    slot->isClaimed = false;
}

// MARK: - Test seams

extern "C" const float* dfh_engine_input_channel(DFHEngineRef opaque, int32_t channel) {
    DFHEngineOpaque* engine = (DFHEngineOpaque*)opaque;
    if (engine == nullptr || channel < 0 || channel >= engine->inputChannelCount) return nullptr;
    return engine->inputScratch + (size_t)channel * engine->maximumFrameCount;
}

extern "C" OSStatus dfh_slot_pull_input(DFHSlotRef slotRef, uint32_t frameCount,
                                        AudioBufferList* inputData) {
    DFHSlotOpaque* slot = (DFHSlotOpaque*)slotRef;
    if (slot == nullptr || inputData == nullptr) return kAudioUnitErr_NoConnection;

    AudioUnitRenderActionFlags flags = 0;
    AudioTimeStamp timestamp{};
    timestamp.mFlags = kAudioTimeStampSampleTimeValid;
    return slotInputCallback(slot, &flags, &timestamp, 0, frameCount, inputData);
}

extern "C" void dfh_slot_set_input_channel(DFHSlotRef slotRef, int32_t channel) {
    DFHSlotOpaque* slot = (DFHSlotOpaque*)slotRef;
    if (slot != nullptr) slot->inputChannel.store(channel, std::memory_order_relaxed);
}

extern "C" void dfh_slot_set_output_channel(DFHSlotRef slotRef, int32_t channel) {
    DFHSlotOpaque* slot = (DFHSlotOpaque*)slotRef;
    if (slot != nullptr) slot->outputChannel.store(channel, std::memory_order_relaxed);
}

extern "C" void dfh_slot_set_muted(DFHSlotRef slotRef, bool muted) {
    DFHSlotOpaque* slot = (DFHSlotOpaque*)slotRef;
    if (slot != nullptr) slot->isMuted.store(muted, std::memory_order_relaxed);
}

extern "C" void dfh_slot_set_bypassed(DFHSlotRef slotRef, bool bypassed) {
    DFHSlotOpaque* slot = (DFHSlotOpaque*)slotRef;
    if (slot != nullptr) slot->isBypassed.store(bypassed, std::memory_order_relaxed);
}


// MARK: - Parallel rendering

extern "C" void dfh_engine_set_parallel_rendering(DFHEngineRef opaque, bool enabled,
                                                  int32_t instanceThreshold) {
    DFHEngineOpaque* engine = (DFHEngineOpaque*)opaque;
    if (engine == nullptr) return;
    engine->parallelRequested = enabled;
    engine->parallelThreshold = instanceThreshold > 1 ? instanceThreshold : 1;
}

extern "C" void dfh_engine_start_workers(DFHEngineRef opaque, AudioUnit outputUnit) {
    DFHEngineOpaque* engine = (DFHEngineOpaque*)opaque;
    if (engine == nullptr || !engine->parallelRequested || engine->workers != nullptr) return;

    const int32_t workerCount = dfh_worker_pool_recommended_worker_count();
    if (workerCount < 2) return;  // Nothing to gain on a single core.

    // Allocated before the threads exist, so the render path never has to check.
    engine->accumulatorStride = (size_t)engine->outputChannelCount * engine->maximumFrameCount;
    engine->workerAccumulators =
        new (std::nothrow) float[engine->accumulatorStride * (size_t)workerCount]();
    engine->workerDestinations =
        new (std::nothrow) float*[(size_t)engine->outputChannelCount * workerCount]();

    if (engine->workerAccumulators == nullptr || engine->workerDestinations == nullptr) {
        dfh_engine_stop_workers(opaque);
        return;
    }

    engine->workers = dfh_worker_pool_create(workerCount - 1, outputUnit,
                                             dfh_engine_buffer_period_nanoseconds(opaque));
    if (engine->workers == nullptr) dfh_engine_stop_workers(opaque);
}

extern "C" void dfh_engine_stop_workers(DFHEngineRef opaque) {
    DFHEngineOpaque* engine = (DFHEngineOpaque*)opaque;
    if (engine == nullptr) return;

    if (engine->workers != nullptr) {
        dfh_worker_pool_destroy(engine->workers);
        engine->workers = nullptr;
    }

    delete[] engine->workerAccumulators;
    engine->workerAccumulators = nullptr;
    delete[] engine->workerDestinations;
    engine->workerDestinations = nullptr;
    engine->accumulatorStride = 0;
    engine->parallelEngaged.store(false, std::memory_order_relaxed);
}

extern "C" bool dfh_engine_parallel_rendering_engaged(DFHEngineRef opaque) {
    DFHEngineOpaque* engine = (DFHEngineOpaque*)opaque;
    return engine != nullptr && engine->parallelEngaged.load(std::memory_order_relaxed);
}

extern "C" int32_t dfh_engine_worker_thread_count(DFHEngineRef opaque) {
    DFHEngineOpaque* engine = (DFHEngineOpaque*)opaque;
    if (engine == nullptr || engine->workers == nullptr) return 0;
    return dfh_worker_pool_thread_count(engine->workers);
}

extern "C" DFHWorkerInfo dfh_engine_worker_info(DFHEngineRef opaque, int32_t index) {
    DFHEngineOpaque* engine = (DFHEngineOpaque*)opaque;
    DFHWorkerInfo empty{};
    if (engine == nullptr || engine->workers == nullptr) return empty;
    return dfh_worker_pool_worker_info(engine->workers, index);
}

extern "C" int32_t dfh_engine_active_slot_count(DFHEngineRef opaque) {
    DFHEngineOpaque* engine = (DFHEngineOpaque*)opaque;
    return engine == nullptr ? 0 : engine->activeSlotCount.load(std::memory_order_relaxed);
}

// MARK: - Diagnostics

extern "C" uint64_t dfh_engine_capture_cycles(DFHEngineRef opaque) {
    DFHEngineOpaque* engine = (DFHEngineOpaque*)opaque;
    return engine == nullptr ? 0 : engine->captureCycleCount.load(std::memory_order_relaxed);
}

extern "C" uint64_t dfh_engine_render_cycles(DFHEngineRef opaque) {
    DFHEngineOpaque* engine = (DFHEngineOpaque*)opaque;
    return engine == nullptr ? 0 : engine->renderCycleCount.load(std::memory_order_relaxed);
}

extern "C" uint64_t dfh_engine_underruns(DFHEngineRef opaque) {
    DFHEngineOpaque* engine = (DFHEngineOpaque*)opaque;
    return engine == nullptr ? 0 : engine->underrunCount.load(std::memory_order_relaxed);
}

extern "C" uint64_t dfh_engine_smoothed_render_nanoseconds(DFHEngineRef opaque) {
    DFHEngineOpaque* engine = (DFHEngineOpaque*)opaque;
    return engine == nullptr ? 0
                             : engine->smoothedRenderNanoseconds.load(std::memory_order_relaxed);
}

extern "C" uint64_t dfh_engine_peak_render_nanoseconds(DFHEngineRef opaque) {
    DFHEngineOpaque* engine = (DFHEngineOpaque*)opaque;
    return engine == nullptr ? 0 : engine->peakRenderNanoseconds.load(std::memory_order_relaxed);
}

extern "C" uint32_t dfh_engine_render_thread_port(DFHEngineRef opaque) {
    DFHEngineOpaque* engine = (DFHEngineOpaque*)opaque;
    return engine == nullptr ? 0 : engine->renderThreadPort.load(std::memory_order_relaxed);
}

extern "C" uint32_t dfh_engine_capture_thread_port(DFHEngineRef opaque) {
    DFHEngineOpaque* engine = (DFHEngineOpaque*)opaque;
    return engine == nullptr ? 0 : engine->captureThreadPort.load(std::memory_order_relaxed);
}
