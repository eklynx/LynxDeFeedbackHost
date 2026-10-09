//
//  DFHIO.cpp
//  DeFeedbackHost
//

#include "DFHIO.h"

#include <cstdio>
#include <cstring>
#include <new>

struct DFHIOOpaque {
    AudioUnit inputUnit = nullptr;
    AudioUnit outputUnit = nullptr;
    DFHEngineRef engine = nullptr;
    bool running = false;
};

namespace {

DFHIOStatus makeStatus(OSStatus code, const char* stage) {
    DFHIOStatus status{};
    status.code = code;
    if (code != noErr && stage != nullptr) {
        std::snprintf(status.stage, DFH_IO_STAGE_CAPACITY, "%s", stage);
    }
    return status;
}

DFHIOStatus success() { return makeStatus(noErr, nullptr); }

/// Deinterleaved 32-bit float, one buffer per hardware channel — which is what makes per-channel
/// routing a matter of picking a buffer index.
AudioStreamBasicDescription clientFormat(double sampleRate, int32_t channelCount) {
    AudioStreamBasicDescription format{};
    format.mSampleRate = sampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags =
        kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
    format.mBytesPerPacket = sizeof(float);
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = sizeof(float);
    format.mChannelsPerFrame = (UInt32)(channelCount > 0 ? channelCount : 1);
    format.mBitsPerChannel = 32;
    return format;
}

OSStatus makeHALUnit(AudioUnit* unit) {
    AudioComponentDescription description{};
    description.componentType = kAudioUnitType_Output;
    description.componentSubType = kAudioUnitSubType_HALOutput;
    description.componentManufacturer = kAudioUnitManufacturer_Apple;

    AudioComponent component = AudioComponentFindNext(nullptr, &description);
    if (component == nullptr) return kAudioUnitErr_InvalidElement;
    return AudioComponentInstanceNew(component, unit);
}

template <typename Value>
OSStatus setProperty(AudioUnit unit, AudioUnitPropertyID property, AudioUnitScope scope,
                     AudioUnitElement element, const Value& value) {
    return AudioUnitSetProperty(unit, property, scope, element, &value, (UInt32)sizeof(Value));
}

/// Input-only AUHAL: element 1 is the hardware input side, element 0 the (disabled) output.
DFHIOStatus configureInputUnit(AudioUnit unit, DFHEngineRef engine, AudioObjectID deviceID,
                               int32_t channelCount, double sampleRate,
                               int32_t maximumFrameCount) {
    OSStatus status = setProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input,
                                  1, (UInt32)1);
    if (status != noErr) return makeStatus(status, "enabling device input");

    status = setProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                         (UInt32)0);
    if (status != noErr) return makeStatus(status, "disabling output on the input unit");

    status = setProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                         deviceID);
    if (status != noErr) return makeStatus(status, "selecting the input device");

    status = setProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                         clientFormat(sampleRate, channelCount));
    if (status != noErr) return makeStatus(status, "setting the input stream format");

    status = setProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                         (UInt32)maximumFrameCount);
    if (status != noErr) return makeStatus(status, "setting the input slice size");

    AURenderCallbackStruct callback{};
    callback.inputProc = dfh_engine_input_callback;
    callback.inputProcRefCon = engine;
    status = setProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global,
                         0, callback);
    if (status != noErr) return makeStatus(status, "installing the input callback");

    status = AudioUnitInitialize(unit);
    if (status != noErr) return makeStatus(status, "initialising the input unit");

    return success();
}

/// Output-only AUHAL: element 0's input scope is what the host feeds.
DFHIOStatus configureOutputUnit(AudioUnit unit, DFHEngineRef engine, AudioObjectID deviceID,
                                int32_t channelCount, double sampleRate,
                                int32_t maximumFrameCount) {
    OSStatus status = setProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output,
                                  0, (UInt32)1);
    if (status != noErr) return makeStatus(status, "enabling device output");

    status = setProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                         (UInt32)0);
    if (status != noErr) return makeStatus(status, "disabling input on the output unit");

    status = setProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                         deviceID);
    if (status != noErr) return makeStatus(status, "selecting the output device");

    status = setProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                         clientFormat(sampleRate, channelCount));
    if (status != noErr) return makeStatus(status, "setting the output stream format");

    status = setProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                         (UInt32)maximumFrameCount);
    if (status != noErr) return makeStatus(status, "setting the output slice size");

    AURenderCallbackStruct callback{};
    callback.inputProc = dfh_engine_output_callback;
    callback.inputProcRefCon = engine;
    status = setProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                         callback);
    if (status != noErr) return makeStatus(status, "installing the output callback");

    status = AudioUnitInitialize(unit);
    if (status != noErr) return makeStatus(status, "initialising the output unit");

    return success();
}

}  // namespace

DFHIORef dfh_io_create(void) { return new (std::nothrow) DFHIOOpaque(); }

void dfh_io_destroy(DFHIORef io) {
    if (io == nullptr) return;
    dfh_io_stop(io);
    delete io;
}

bool dfh_io_is_running(DFHIORef io) { return io != nullptr && io->running; }

DFHIOStatus dfh_io_start(DFHIORef io, DFHEngineRef engine,
                         AudioObjectID inputDeviceID, int32_t inputChannelCount,
                         AudioObjectID outputDeviceID, int32_t outputChannelCount,
                         double sampleRate, int32_t maximumFrameCount) {
    if (io == nullptr || engine == nullptr) {
        return makeStatus(kAudioUnitErr_InvalidParameter, "starting the audio engine");
    }

    dfh_io_stop(io);
    io->engine = engine;

    OSStatus status = makeHALUnit(&io->inputUnit);
    if (status != noErr || io->inputUnit == nullptr) {
        dfh_io_stop(io);
        return makeStatus(status, "creating the input I/O unit");
    }

    DFHIOStatus configured = configureInputUnit(io->inputUnit, engine, inputDeviceID,
                                                inputChannelCount, sampleRate, maximumFrameCount);
    if (configured.code != noErr) {
        dfh_io_stop(io);
        return configured;
    }

    // The capture callback renders through this unit, so the engine needs it before either
    // device starts.
    dfh_engine_set_input_unit(engine, io->inputUnit);

    status = makeHALUnit(&io->outputUnit);
    if (status != noErr || io->outputUnit == nullptr) {
        dfh_io_stop(io);
        return makeStatus(status, "creating the output I/O unit");
    }

    configured = configureOutputUnit(io->outputUnit, engine, outputDeviceID, outputChannelCount,
                                     sampleRate, maximumFrameCount);
    if (configured.code != noErr) {
        dfh_io_stop(io);
        return configured;
    }

    // Worker threads, if parallel rendering was requested. Done here because the device workgroup
    // comes off the output unit, and before either device starts so the workers are scheduled and
    // waiting by the first callback rather than being created underneath one.
    dfh_engine_start_workers(engine, io->outputUnit);

    status = AudioOutputUnitStart(io->inputUnit);
    if (status != noErr) {
        dfh_io_stop(io);
        return makeStatus(status, "starting the input device");
    }

    status = AudioOutputUnitStart(io->outputUnit);
    if (status != noErr) {
        dfh_io_stop(io);
        return makeStatus(status, "starting the output device");
    }

    io->running = true;
    return success();
}

void dfh_io_stop(DFHIORef io) {
    if (io == nullptr) return;

    // Stop the hardware before anything the callbacks touch goes away.
    if (io->outputUnit != nullptr) AudioOutputUnitStop(io->outputUnit);

    // Only now can the workers be torn down: with the output unit stopped no render cycle is in
    // flight, so no thread is inside `dfh_worker_pool_run`.
    if (io->engine != nullptr) dfh_engine_stop_workers(io->engine);

    if (io->outputUnit != nullptr) {
        AudioUnitUninitialize(io->outputUnit);
        AudioComponentInstanceDispose(io->outputUnit);
        io->outputUnit = nullptr;
    }
    if (io->inputUnit != nullptr) {
        AudioOutputUnitStop(io->inputUnit);
        AudioUnitUninitialize(io->inputUnit);
        AudioComponentInstanceDispose(io->inputUnit);
        io->inputUnit = nullptr;
    }

    if (io->engine != nullptr) {
        dfh_engine_set_input_unit(io->engine, nullptr);
        io->engine = nullptr;
    }
    io->running = false;
}
