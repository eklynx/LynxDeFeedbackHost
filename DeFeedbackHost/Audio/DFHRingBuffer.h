//
//  DFHRingBuffer.h
//  DeFeedbackHost
//
//  Lock-free single-producer / single-consumer ring buffer holding deinterleaved float frames.
//  Port of the Swift original; same semantics, now with the realtime contract enforced by the
//  compiler rather than by hand.
//
//  - AI used for the C engine code to simplify setup and focus on speed and efficient resource usage

#ifndef DFHRingBuffer_h
#define DFHRingBuffer_h

#include <CoreAudioTypes/CoreAudioTypes.h>
#include <atomic>
#include <cstdint>

namespace dfh {

/// The input device's I/O proc is the only producer; the output device's I/O proc is the only
/// consumer. Storage is allocated once in the constructor, so nothing on the audio path allocates.
class RingBuffer {
public:
    RingBuffer(int32_t channelCount, int32_t capacityFrames);
    ~RingBuffer();

    RingBuffer(const RingBuffer&) = delete;
    RingBuffer& operator=(const RingBuffer&) = delete;

    int32_t channelCount() const { return channelCount_; }
    int32_t capacityFrames() const { return capacityFrames_; }

    int32_t framesAvailable() const CA_REALTIME_API;

    /// Pushes silence in, giving the consumer a cushion to absorb the jitter between two
    /// independently scheduled I/O procs.
    void primeWithSilence(int32_t frameCount) CA_REALTIME_API;

    /// Producer side. On overrun the oldest frames are dropped by advancing the read index: a
    /// glitch now beats latency that grows without bound for the rest of the session.
    void write(const AudioBufferList* bufferList, int32_t frameCount) CA_REALTIME_API;

    /// Consumer side. Fills `destination`, which must hold `channelCount * frameCount` floats
    /// channel-contiguously with the given stride. Returns false on underrun, having written
    /// silence.
    bool read(float* destination, int32_t stride, int32_t frameCount) CA_REALTIME_API;

private:
    /// Writes one channel's frames starting at absolute index `start`, wrapping once. A null
    /// source writes silence, which keeps the stream frame-aligned when a hardware channel we
    /// expected isn't there.
    void copyForward(float* base, const float* source, uint64_t start,
                     int32_t frameCount) const CA_REALTIME_API;

    int32_t channelCount_;
    int32_t capacityFrames_;

    /// Channel-contiguous: channel c frame f lives at storage_[c * capacityFrames_ + f].
    float* storage_;

    std::atomic<uint64_t> writeIndex_{0};
    std::atomic<uint64_t> readIndex_{0};
};

}  // namespace dfh

#endif /* DFHRingBuffer_h */
