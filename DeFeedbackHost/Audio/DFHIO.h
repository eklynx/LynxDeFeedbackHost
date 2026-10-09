//
//  DFHIO.h
//  DeFeedbackHost
//
//  The two AUHAL units and their lifecycle, in C. Swift keeps device selection, the sample-rate
//  and buffer-size gating, microphone consent and error presentation; this owns the unit
//  configuration and start/stop.
//
//  - AI used for the C engine code to simplify setup and focus on speed and efficient resource usage

#ifndef DFHIO_h
#define DFHIO_h

#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>
#include <stdint.h>

#include "DFHEngine.h"

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

#define DFH_IO_STAGE_CAPACITY 128

/// What happened, and during what. `stage` is empty on success and otherwise names the step, so
/// Swift can build the same "CoreAudio error N while <doing X>" message it always has.
typedef struct {
    OSStatus code;
    char stage[DFH_IO_STAGE_CAPACITY];
} DFHIOStatus;

typedef struct DFHIOOpaque* DFHIORef;

DFHIORef _Nullable dfh_io_create(void);
void dfh_io_destroy(DFHIORef io);

/// Builds both AUHAL units, wires them to `engine`, and starts them.
///
/// Preserves the details that were each a bug once: `EnableIO` on the right scope and element for
/// each direction, the device selection, a deinterleaved float32 client format at the device's
/// channel count, `MaximumFramesPerSlice`, and initialize-then-start ordering.
///
/// On failure nothing is left running — the caller should still call `dfh_io_stop` for symmetry.
DFHIOStatus dfh_io_start(DFHIORef io,
                         DFHEngineRef engine,
                         AudioObjectID inputDeviceID,
                         int32_t inputChannelCount,
                         AudioObjectID outputDeviceID,
                         int32_t outputChannelCount,
                         double sampleRate,
                         int32_t maximumFrameCount);

/// Stops, uninitializes and disposes both units. Safe to call when not started.
void dfh_io_stop(DFHIORef io);

/// True between a successful `dfh_io_start` and the next `dfh_io_stop`.
bool dfh_io_is_running(DFHIORef io);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif /* DFHIO_h */
