//
//  RingBuffer.swift
//  DeFeedbackHost
//

import AudioToolbox

/// Swift face of the C++ ring buffer (`DFHRingBuffer.{h,cpp}`).
///
/// `nonisolated` because the audio threads touch it from their own threads, while everything
/// else uses the main actor because of `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
nonisolated final class RingBuffer: @unchecked Sendable {

    private let handle: DFHRingBufferRef?

    init(channelCount: Int, capacityFrames: Int) {
        handle = dfh_ring_buffer_create(Int32(channelCount), Int32(capacityFrames))
    }

    deinit {
        if let handle { dfh_ring_buffer_destroy(handle) }
    }

    var channelCount: Int {
        guard let handle else { return 0 }
        return Int(dfh_ring_buffer_channel_count(handle))
    }

    var capacityFrames: Int {
        guard let handle else { return 0 }
        return Int(dfh_ring_buffer_capacity_frames(handle))
    }

    var framesAvailable: Int {
        guard let handle else { return 0 }
        return Int(dfh_ring_buffer_frames_available(handle))
    }

    func primeWithSilence(frameCount: Int) {
        guard let handle else { return }
        dfh_ring_buffer_prime_with_silence(handle, Int32(frameCount))
    }

    func write(_ bufferList: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        guard let handle else { return }
        dfh_ring_buffer_write(handle, bufferList.unsafePointer, Int32(frameCount))
    }

    @discardableResult
    func read(into destination: UnsafeMutablePointer<Float>,
              stride: Int,
              frameCount: Int) -> Bool {
        guard let handle else { return false }
        return dfh_ring_buffer_read(handle, destination, Int32(stride), Int32(frameCount))
    }
}
