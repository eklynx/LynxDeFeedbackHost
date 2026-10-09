//
//  DFHDevices.h
//  DeFeedbackHost
//
//  CoreAudio HAL device queries, in C. Swift keeps device *selection*, gating and error surfacing;
//  this owns the property calls.
//
//  Deliberately not included here: waiting for a sample rate change to land. The HAL applies rate
//  changes asynchronously, and the polite way to wait is an async poll that leaves the main thread
//  responsive — which is Swift's job, not this layer's. This exposes the get and the set;
//  `AudioHost` still owns the waiting.
//
//  - AI used for the C engine code to simplify setup and focus on speed and efficient resource usage

#ifndef DFHDevices_h
#define DFHDevices_h

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

#define DFH_DEVICE_NAME_CAPACITY 256

typedef struct {
    AudioObjectID deviceID;
    int32_t inputChannelCount;
    int32_t outputChannelCount;
    char name[DFH_DEVICE_NAME_CAPACITY];
    char uid[DFH_DEVICE_NAME_CAPACITY];
} DFHDeviceInfo;

/// Fills `devices` with up to `capacity` entries and returns how many were written. Devices whose
/// name can't be read are skipped, as they were in the Swift original.
int32_t dfh_devices_enumerate(DFHDeviceInfo* devices, int32_t capacity);

/// The system default device, or 0 if there isn't one.
AudioObjectID dfh_devices_default(bool input);

/// Channel count for one direction. `input` selects the scope.
int32_t dfh_device_channel_count(AudioObjectID deviceID, bool input);

// MARK: - Sample rate

/// 0 when the rate can't be read.
double dfh_device_nominal_sample_rate(AudioObjectID deviceID);

/// Requests a rate. Returns whether the *request* was accepted — not whether it has taken effect,
/// which happens asynchronously.
bool dfh_device_set_nominal_sample_rate(AudioObjectID deviceID, double rate);

/// Rates worth offering. Devices report either discrete rates (a range whose min equals its max)
/// or genuinely continuous ranges; continuous ranges are expanded to the standard rates they
/// cover, since a menu of arbitrary intermediate values would be useless.
int32_t dfh_device_available_sample_rates(AudioObjectID deviceID, double* rates, int32_t capacity);

// MARK: - Buffer frame size

/// 0 when it can't be read.
int32_t dfh_device_buffer_frame_size(AudioObjectID deviceID);

/// Requests exactly `frames` and returns the size the device actually settled on, or 0 if it
/// can't be read back. Deliberately does not clamp to the device's range: the caller needs to know
/// the device landed somewhere other than what was asked for.
int32_t dfh_device_set_buffer_frame_size(AudioObjectID deviceID, int32_t frames);

/// False when the device reports no range, in which case anything is assumed acceptable.
bool dfh_device_buffer_frame_size_range(AudioObjectID deviceID, int32_t* minimum, int32_t* maximum);

// MARK: - Device list changes

typedef void (*DFHDeviceListChanged)(void* _Nullable context);

/// Watches the HAL device list so the pickers don't go stale when hardware is plugged in. The
/// handler is delivered on the main queue. Pass NULL to stop watching.
void dfh_devices_set_change_handler(DFHDeviceListChanged _Nullable handler,
                                    void* _Nullable context);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif /* DFHDevices_h */
