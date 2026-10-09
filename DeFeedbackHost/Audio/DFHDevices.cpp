//
//  DFHDevices.cpp
//  DeFeedbackHost
//

#include "DFHDevices.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <algorithm>
#include <cstring>
#include <vector>

namespace {

AudioObjectPropertyAddress address(AudioObjectPropertySelector selector,
                                   AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    AudioObjectPropertyAddress result{};
    result.mSelector = selector;
    result.mScope = scope;
    result.mElement = kAudioObjectPropertyElementMain;
    return result;
}

/// Copies a CFString property into a fixed buffer. Returns false when the property is missing.
bool copyStringProperty(AudioObjectID objectID, AudioObjectPropertySelector selector,
                        char* destination, int32_t capacity) {
    AudioObjectPropertyAddress propertyAddress = address(selector);
    CFStringRef value = nullptr;
    UInt32 size = sizeof(value);

    if (AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nullptr, &size, &value) != noErr
        || value == nullptr) {
        return false;
    }

    const bool converted =
        CFStringGetCString(value, destination, capacity, kCFStringEncodingUTF8);
    CFRelease(value);
    return converted;
}

/// The rates a menu should offer when a device reports a continuous range.
constexpr double kStandardSampleRates[] = {
    8000, 11025, 16000, 22050, 32000, 44100, 48000,
    88200, 96000, 176400, 192000, 352800, 384000,
};

struct ChangeHandler {
    DFHDeviceListChanged handler = nullptr;
    void* context = nullptr;
    AudioObjectPropertyListenerBlock block = nullptr;
};

ChangeHandler& changeHandler() {
    static ChangeHandler instance;
    return instance;
}

}  // namespace

int32_t dfh_device_channel_count(AudioObjectID deviceID, bool input) {
    AudioObjectPropertyAddress propertyAddress =
        address(kAudioDevicePropertyStreamConfiguration,
                input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput);

    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nullptr, &size) != noErr
        || size == 0) {
        return 0;
    }

    std::vector<uint8_t> storage(size);
    AudioBufferList* list = (AudioBufferList*)storage.data();
    if (AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nullptr, &size, list) != noErr) {
        return 0;
    }

    int32_t channels = 0;
    for (UInt32 index = 0; index < list->mNumberBuffers; ++index) {
        channels += (int32_t)list->mBuffers[index].mNumberChannels;
    }
    return channels;
}

int32_t dfh_devices_enumerate(DFHDeviceInfo* devices, int32_t capacity) {
    if (devices == nullptr || capacity <= 0) return 0;

    AudioObjectPropertyAddress propertyAddress = address(kAudioHardwarePropertyDevices);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &propertyAddress, 0, nullptr,
                                       &size) != noErr || size == 0) {
        return 0;
    }

    const int32_t count = (int32_t)(size / sizeof(AudioObjectID));
    std::vector<AudioObjectID> ids((size_t)count);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &propertyAddress, 0, nullptr, &size,
                                   ids.data()) != noErr) {
        return 0;
    }

    int32_t written = 0;
    for (int32_t index = 0; index < count && written < capacity; ++index) {
        DFHDeviceInfo info{};
        info.deviceID = ids[(size_t)index];

        // A device whose name can't be read is skipped, as it was in the Swift original.
        if (!copyStringProperty(info.deviceID, kAudioObjectPropertyName, info.name,
                                DFH_DEVICE_NAME_CAPACITY)) {
            continue;
        }
        if (!copyStringProperty(info.deviceID, kAudioDevicePropertyDeviceUID, info.uid,
                                DFH_DEVICE_NAME_CAPACITY)) {
            std::snprintf(info.uid, DFH_DEVICE_NAME_CAPACITY, "%u", (unsigned)info.deviceID);
        }

        info.inputChannelCount = dfh_device_channel_count(info.deviceID, true);
        info.outputChannelCount = dfh_device_channel_count(info.deviceID, false);

        devices[written++] = info;
    }

    // Sorted by name, matching what the pickers used to show.
    std::sort(devices, devices + written, [](const DFHDeviceInfo& a, const DFHDeviceInfo& b) {
        return std::strcmp(a.name, b.name) < 0;
    });
    return written;
}

AudioObjectID dfh_devices_default(bool input) {
    AudioObjectPropertyAddress propertyAddress =
        address(input ? kAudioHardwarePropertyDefaultInputDevice
                      : kAudioHardwarePropertyDefaultOutputDevice);

    AudioObjectID deviceID = kAudioObjectUnknown;
    UInt32 size = sizeof(deviceID);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &propertyAddress, 0, nullptr, &size,
                                   &deviceID) != noErr) {
        return 0;
    }
    return deviceID == kAudioObjectUnknown ? 0 : deviceID;
}

// MARK: - Sample rate

double dfh_device_nominal_sample_rate(AudioObjectID deviceID) {
    AudioObjectPropertyAddress propertyAddress = address(kAudioDevicePropertyNominalSampleRate);
    Float64 rate = 0;
    UInt32 size = sizeof(rate);
    if (AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nullptr, &size, &rate) != noErr) {
        return 0;
    }
    return rate > 0 ? rate : 0;
}

bool dfh_device_set_nominal_sample_rate(AudioObjectID deviceID, double rate) {
    AudioObjectPropertyAddress propertyAddress = address(kAudioDevicePropertyNominalSampleRate);
    Float64 value = rate;
    return AudioObjectSetPropertyData(deviceID, &propertyAddress, 0, nullptr,
                                      (UInt32)sizeof(value), &value) == noErr;
}

int32_t dfh_device_available_sample_rates(AudioObjectID deviceID, double* rates,
                                          int32_t capacity) {
    if (rates == nullptr || capacity <= 0) return 0;

    AudioObjectPropertyAddress propertyAddress =
        address(kAudioDevicePropertyAvailableNominalSampleRates);

    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nullptr, &size) != noErr
        || size == 0) {
        return 0;
    }

    const int32_t rangeCount = (int32_t)(size / sizeof(AudioValueRange));
    std::vector<AudioValueRange> ranges((size_t)rangeCount);
    if (AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nullptr, &size,
                                   ranges.data()) != noErr) {
        return 0;
    }

    std::vector<double> collected;
    for (const AudioValueRange& range : ranges) {
        if (range.mMinimum <= 0) continue;

        if (range.mMaximum - range.mMinimum <= 0.5) {
            collected.push_back(range.mMinimum);
            continue;
        }

        bool covered = false;
        for (double standard : kStandardSampleRates) {
            if (standard >= range.mMinimum - 0.5 && standard <= range.mMaximum + 0.5) {
                collected.push_back(standard);
                covered = true;
            }
        }
        if (!covered) {
            // Unusual range straddling no standard rate: offer its endpoints.
            collected.push_back(range.mMinimum);
            collected.push_back(range.mMaximum);
        }
    }

    std::sort(collected.begin(), collected.end());
    collected.erase(std::unique(collected.begin(), collected.end()), collected.end());

    const int32_t written = std::min(capacity, (int32_t)collected.size());
    for (int32_t index = 0; index < written; ++index) rates[index] = collected[(size_t)index];
    return written;
}

// MARK: - Buffer frame size

int32_t dfh_device_buffer_frame_size(AudioObjectID deviceID) {
    AudioObjectPropertyAddress propertyAddress = address(kAudioDevicePropertyBufferFrameSize);
    UInt32 frames = 0;
    UInt32 size = sizeof(frames);
    if (AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nullptr, &size, &frames) != noErr) {
        return 0;
    }
    return (int32_t)frames;
}

int32_t dfh_device_set_buffer_frame_size(AudioObjectID deviceID, int32_t frames) {
    AudioObjectPropertyAddress propertyAddress = address(kAudioDevicePropertyBufferFrameSize);
    UInt32 value = (UInt32)frames;
    AudioObjectSetPropertyData(deviceID, &propertyAddress, 0, nullptr, (UInt32)sizeof(value),
                               &value);

    // Trust the device's report rather than the request: some devices quantise it.
    return dfh_device_buffer_frame_size(deviceID);
}

bool dfh_device_buffer_frame_size_range(AudioObjectID deviceID, int32_t* minimum,
                                        int32_t* maximum) {
    AudioObjectPropertyAddress propertyAddress = address(kAudioDevicePropertyBufferFrameSizeRange);
    AudioValueRange range{};
    UInt32 size = sizeof(range);
    if (AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nullptr, &size, &range) != noErr
        || range.mMinimum <= 0 || range.mMaximum < range.mMinimum) {
        return false;
    }

    if (minimum != nullptr) *minimum = (int32_t)range.mMinimum;
    if (maximum != nullptr) *maximum = (int32_t)range.mMaximum;
    return true;
}

// MARK: - Device list changes

void dfh_devices_set_change_handler(DFHDeviceListChanged handler, void* context) {
    ChangeHandler& state = changeHandler();
    AudioObjectPropertyAddress propertyAddress = address(kAudioHardwarePropertyDevices);

    if (state.block != nullptr) {
        AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &propertyAddress,
                                               dispatch_get_main_queue(), state.block);
        Block_release(state.block);
        state.block = nullptr;
    }

    state.handler = handler;
    state.context = context;
    if (handler == nullptr) return;

    AudioObjectPropertyListenerBlock listener =
        ^(UInt32, const AudioObjectPropertyAddress*) {
            ChangeHandler& current = changeHandler();
            if (current.handler != nullptr) current.handler(current.context);
        };

    state.block = Block_copy(listener);
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &propertyAddress,
                                        dispatch_get_main_queue(), state.block);
}
