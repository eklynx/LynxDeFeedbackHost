//
//  DFHEngine.h
//  DeFeedbackHost
//
//  C layer over the C++ realtime audio engine.
//
//  Deliberately C over Swift/C++ interop so no type conversion/crossing happens; this is about speed.
//
//  Pointers are assumed non-null with the genuinely optional ones marked so that swift doesn't treat
//  them as optionals
//
//  - AI used for the C engine code to simplify setup and focus on speed and efficient resource usage


#ifndef DFHEngine_h
#define DFHEngine_h

#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>
#include <stdint.h>

#include "DFHWorkers.h"

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin


// MARK: - Ring buffer
typedef struct DFHRingBufferOpaque* DFHRingBufferRef;

DFHRingBufferRef _Nullable dfh_ring_buffer_create(int32_t channelCount, int32_t capacityFrames);
void dfh_ring_buffer_destroy(DFHRingBufferRef ringBuffer);

int32_t dfh_ring_buffer_channel_count(DFHRingBufferRef ringBuffer);
int32_t dfh_ring_buffer_capacity_frames(DFHRingBufferRef ringBuffer);
int32_t dfh_ring_buffer_frames_available(DFHRingBufferRef ringBuffer);

void dfh_ring_buffer_prime_with_silence(DFHRingBufferRef ringBuffer, int32_t frameCount);
void dfh_ring_buffer_write(DFHRingBufferRef ringBuffer, const AudioBufferList* bufferList,
                           int32_t frameCount);
bool dfh_ring_buffer_read(DFHRingBufferRef ringBuffer, float* destination, int32_t stride,
                          int32_t frameCount);

// MARK: - Engine
typedef struct DFHEngineOpaque* DFHEngineRef;
typedef struct DFHSlotOpaque* DFHSlotRef;

int32_t dfh_engine_maximum_slot_count(void);

DFHEngineRef _Nullable dfh_engine_create(int32_t maximumFrameCount,
                                         int32_t inputChannelCount,
                                         int32_t outputChannelCount,
                                         double sampleRate,
                                         int32_t ringBufferDepthInBuffers);
void dfh_engine_destroy(DFHEngineRef engine);

int32_t dfh_engine_maximum_frame_count(DFHEngineRef engine);
double dfh_engine_sample_rate(DFHEngineRef engine);

double dfh_engine_buffer_period_nanoseconds(DFHEngineRef engine);

void dfh_engine_set_input_unit(DFHEngineRef engine, AudioUnit _Nullable inputUnit);

void dfh_engine_prime_with_silence(DFHEngineRef engine, int32_t frameCount);
int32_t dfh_engine_frames_available(DFHEngineRef engine);

void dfh_engine_write_input(DFHEngineRef engine, const AudioBufferList* bufferList,
                            int32_t frameCount);

// MARK: - I/O callbacks
OSStatus dfh_engine_input_callback(void* refCon,
                                   AudioUnitRenderActionFlags* actionFlags,
                                   const AudioTimeStamp* timestamp,
                                   UInt32 busNumber,
                                   UInt32 frameCount,
                                   AudioBufferList* _Nullable ioData) CA_REALTIME_API;

OSStatus dfh_engine_output_callback(void* refCon,
                                    AudioUnitRenderActionFlags* actionFlags,
                                    const AudioTimeStamp* timestamp,
                                    UInt32 busNumber,
                                    UInt32 frameCount,
                                    AudioBufferList* _Nullable ioData) CA_REALTIME_API;


/// Drives one render cycle directly. Production goes through `dfh_engine_output_callback`; this is
/// the seam the tests use.
///  - AI generated for testing
OSStatus dfh_engine_render(DFHEngineRef engine,
                           const AudioTimeStamp* timestamp,
                           uint32_t frameCount,
                           AudioBufferList* output);

// MARK: - Slots

DFHSlotRef _Nullable dfh_engine_claim_slot(DFHEngineRef engine);

int32_t dfh_engine_install_audiounit(DFHEngineRef engine, DFHSlotRef slot, AudioUnit audiounit);

typedef OSStatus (*DFHRenderFunction)(void* _Nullable context,
                                      AudioUnitRenderActionFlags* actionFlags,
                                      const AudioTimeStamp* timestamp,
                                      uint32_t frameCount,
                                      AudioBufferList* output) CA_REALTIME_API;

void dfh_engine_install_function(DFHEngineRef engine, DFHSlotRef slot,
                                 DFHRenderFunction function, void* _Nullable context,
                                 int32_t busChannelCount, bool providesOwnOutputBuffer);

void dfh_engine_retire_slot(DFHEngineRef engine, DFHSlotRef slot);

void dfh_engine_release_slot(DFHEngineRef engine, DFHSlotRef slot);

// MARK: - Test seams
//
// Real plugins reach their input through the engine's per-slot input callback, which a stand-in
// render function never triggers. These two keep that path and the engine's input view testable
// without a plugin.
//
//  - AI used heavily for the C++ interface


/// The engine's view of one input channel for the current cycle, or NULL if out of range.
const float* _Nullable dfh_engine_input_channel(DFHEngineRef engine, int32_t channel);

/// Invokes a slot's input callback exactly as its plugin would.
OSStatus dfh_slot_pull_input(DFHSlotRef slot, uint32_t frameCount, AudioBufferList* inputData);

void dfh_slot_set_input_channel(DFHSlotRef slot, int32_t channel);
void dfh_slot_set_output_channel(DFHSlotRef slot, int32_t channel);
void dfh_slot_set_muted(DFHSlotRef slot, bool muted);
void dfh_slot_set_bypassed(DFHSlotRef slot, bool bypassed);

// MARK: - Parallel rendering
void dfh_engine_set_parallel_rendering(DFHEngineRef engine, bool enabled,
                                       int32_t instanceThreshold);
void dfh_engine_start_workers(DFHEngineRef engine, AudioUnit _Nullable outputUnit);
void dfh_engine_stop_workers(DFHEngineRef engine);
bool dfh_engine_parallel_rendering_engaged(DFHEngineRef engine);
int32_t dfh_engine_worker_thread_count(DFHEngineRef engine);

/// Lets us check if we're in realtime scheduling.
DFHWorkerInfo dfh_engine_worker_info(DFHEngineRef engine, int32_t index);

/// Current number of active instances.
int32_t dfh_engine_active_slot_count(DFHEngineRef engine);


// MARK: - Diagnostics

uint64_t dfh_engine_capture_cycles(DFHEngineRef engine);
uint64_t dfh_engine_render_cycles(DFHEngineRef engine);
uint64_t dfh_engine_underruns(DFHEngineRef engine);
uint64_t dfh_engine_smoothed_render_nanoseconds(DFHEngineRef engine);
uint64_t dfh_engine_peak_render_nanoseconds(DFHEngineRef engine);

uint32_t dfh_engine_render_thread_port(DFHEngineRef engine);
uint32_t dfh_engine_capture_thread_port(DFHEngineRef engine);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif /* DFHEngine_h */
