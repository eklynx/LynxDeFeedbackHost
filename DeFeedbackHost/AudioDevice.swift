//
//  AudioDevice.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/20/2026.
//

import CoreAudio
import Foundation

/// Represents a CoreAudio HAL device with the properties we care about
struct AudioDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let inputChannelCount: Int
    let outputChannelCount: Int
}

/// Swift/C++ interfact layer for  (`DFHDevices.{h,cpp}`).
enum AudioHardware {

    /// max number of HAL devices we support on a call.
    private static let maxHalDevices = 128

    // MARK: - Device Retrieval
    static func allDevices() -> [AudioDevice] {
        var deviceArray = [DFHDeviceInfo](repeating: DFHDeviceInfo(), count: maxHalDevices)
        let deviceCount = deviceArray.withUnsafeMutableBufferPointer { buffer in
            Int(dfh_devices_enumerate(buffer.baseAddress!, Int32(buffer.count)))
        }

        return deviceArray.prefix(deviceCount).map { info in
            AudioDevice(id: info.deviceID,
                        name: string(from: info.name),
                        uid: string(from: info.uid),
                        inputChannelCount: Int(info.inputChannelCount),
                        outputChannelCount: Int(info.outputChannelCount))
        }
    }

    static func defaultDeviceID(input: Bool) -> AudioDeviceID? {
        let id = dfh_devices_default(input)
        return id == 0 ? nil : id
    }

    static func channelCount(_ id: AudioObjectID, input: Bool) -> Int {
        Int(dfh_device_channel_count(id, input))
    }


    // MARK: - Sample rate

    /// Nominal Sample Rate is the current sample rate of the device.
    static func nominalSampleRate(_ id: AudioDeviceID) -> Double? {
        let rate = dfh_device_nominal_sample_rate(id)
        return rate > 0 ? rate : nil
    }

    @discardableResult
    static func setNominalSampleRate(_ rate: Double, for id: AudioDeviceID) -> Bool {
        dfh_device_set_nominal_sample_rate(id, rate)
    }

    static func availableSampleRates(_ id: AudioDeviceID) -> [Double] {
        var storage = [Double](repeating: 0, count: 64)
        let count = storage.withUnsafeMutableBufferPointer { buffer in
            Int(dfh_device_available_sample_rates(id, buffer.baseAddress!, Int32(buffer.count)))
        }
        return Array(storage.prefix(count))
    }


    // MARK: - Buffer frame size

    /// Gets the frame buffer size range supported by the device
    static func bufferFrameSizeRange(_ id: AudioDeviceID) -> ClosedRange<Int>? {
        var minimum: Int32 = 0
        var maximum: Int32 = 0
        guard dfh_device_buffer_frame_size_range(id, &minimum, &maximum) else { return nil }
        return Int(minimum)...Int(maximum)
    }

    /// Gets the fame buffer size for the device.
    static func bufferFrameSize(_ id: AudioDeviceID) -> Int? {
        let frames = dfh_device_buffer_frame_size(id)
        return frames > 0 ? Int(frames) : nil
    }

    /// Checks if the specified buffer size is supported by the device.
    static func supportsBufferFrameSize(_ numFrames: Int, on id: AudioDeviceID) -> Bool {
        guard let range = bufferFrameSizeRange(id) else { return true }
        return range.contains(numFrames)
    }

    /// Try to set the frame buffer size for the device.  Returns the actual size returned in case it's different that what you tried to set.
    @discardableResult
    static func setBufferFrameSize(_ frames: Int, for id: AudioDeviceID) -> Int? {
        let actual = dfh_device_set_buffer_frame_size(id, Int32(frames))
        return actual > 0 ? Int(actual) : nil
    }


    // MARK: - Helpers

    /// Takes a c-string from a buffer and returns a Swift version of that same string in place.  If there is an issue, it returns an empty string.
    private static func string<Buffer>(from buffer: Buffer) -> String {
        withUnsafeBytes(of: buffer) { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
            return String(cString: base)
        }
    }
}

/// Watches the HAL device list so the device pickers don't go stale when hardware is plugged in
/// or removed while the app is open.
/// Nothing static here on purpose: a `static var` would be MainActor-isolated under this target's
/// default isolation, and touching it from the nonisolated `deinit` traps at runtime. `AudioHost`
/// owns the monitor for as long as it needs it.
///
///  - This class, specifically non-static behavior thanks to AI.
final class DeviceListMonitor {

    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange

        dfh_devices_set_change_handler({ context in
            guard let context else { return }
            let monitor = Unmanaged<DeviceListMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.onChange() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        dfh_devices_set_change_handler(nil, nil)
    }
}
