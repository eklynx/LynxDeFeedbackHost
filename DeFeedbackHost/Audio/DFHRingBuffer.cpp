//
//  DFHRingBuffer.cpp
//  DeFeedbackHost
//

#include "DFHRingBuffer.h"

#include <cstring>
#include <new>

namespace dfh {

static_assert(std::atomic<uint64_t>::is_always_lock_free,
              "the ring buffer indices must be lock-free to be usable on an audio thread");

RingBuffer::RingBuffer(int32_t channelCount, int32_t capacityFrames)
    : channelCount_(channelCount > 1 ? channelCount : 1),
      capacityFrames_(capacityFrames > 1 ? capacityFrames : 1) {
    const size_t total = (size_t)channelCount_ * (size_t)capacityFrames_;
    storage_ = new float[total];
    std::memset(storage_, 0, total * sizeof(float));
}

RingBuffer::~RingBuffer() {
    delete[] storage_;
}

int32_t RingBuffer::framesAvailable() const CA_REALTIME_API {
    const uint64_t write = writeIndex_.load(std::memory_order_acquire);
    const uint64_t read = readIndex_.load(std::memory_order_acquire);
    return (int32_t)(write - read);
}

void RingBuffer::primeWithSilence(int32_t frameCount) CA_REALTIME_API {
    if (frameCount <= 0) return;

    const uint64_t write = writeIndex_.load(std::memory_order_relaxed);
    for (int32_t channel = 0; channel < channelCount_; ++channel) {
        copyForward(storage_ + (size_t)channel * capacityFrames_, nullptr, write, frameCount);
    }
    writeIndex_.store(write + (uint64_t)frameCount, std::memory_order_release);
}

void RingBuffer::write(const AudioBufferList* bufferList, int32_t frameCount) CA_REALTIME_API {
    if (bufferList == nullptr || frameCount <= 0 || frameCount > capacityFrames_) return;

    const uint64_t write = writeIndex_.load(std::memory_order_relaxed);
    const int32_t used = (int32_t)(write - readIndex_.load(std::memory_order_acquire));
    if (used + frameCount > capacityFrames_) {
        const uint64_t overflow = (uint64_t)(used + frameCount - capacityFrames_);
        readIndex_.store(readIndex_.load(std::memory_order_relaxed) + overflow,
                         std::memory_order_release);
    }

    const uint32_t availableBuffers = bufferList->mNumberBuffers;
    for (int32_t channel = 0; channel < channelCount_; ++channel) {
        const float* source = nullptr;
        if ((uint32_t)channel < availableBuffers) {
            source = (const float*)bufferList->mBuffers[channel].mData;
        }
        copyForward(storage_ + (size_t)channel * capacityFrames_, source, write, frameCount);
    }

    writeIndex_.store(write + (uint64_t)frameCount, std::memory_order_release);
}

bool RingBuffer::read(float* destination, int32_t stride, int32_t frameCount) CA_REALTIME_API {
    if (destination == nullptr) return false;
    if (frameCount <= 0) return true;

    const uint64_t read = readIndex_.load(std::memory_order_relaxed);
    const int32_t available =
        (int32_t)(writeIndex_.load(std::memory_order_acquire) - read);

    if (available < frameCount) {
        for (int32_t channel = 0; channel < channelCount_; ++channel) {
            std::memset(destination + (size_t)channel * stride, 0,
                        (size_t)frameCount * sizeof(float));
        }
        return false;
    }

    const int32_t offset = (int32_t)(read % (uint64_t)capacityFrames_);
    const int32_t firstChunk =
        frameCount < capacityFrames_ - offset ? frameCount : capacityFrames_ - offset;
    const int32_t secondChunk = frameCount - firstChunk;

    for (int32_t channel = 0; channel < channelCount_; ++channel) {
        const float* base = storage_ + (size_t)channel * capacityFrames_;
        float* target = destination + (size_t)channel * stride;
        std::memcpy(target, base + offset, (size_t)firstChunk * sizeof(float));
        if (secondChunk > 0) {
            std::memcpy(target + firstChunk, base, (size_t)secondChunk * sizeof(float));
        }
    }

    readIndex_.store(read + (uint64_t)frameCount, std::memory_order_release);
    return true;
}

void RingBuffer::copyForward(float* base, const float* source, uint64_t start,
                             int32_t frameCount) const CA_REALTIME_API {
    const int32_t offset = (int32_t)(start % (uint64_t)capacityFrames_);
    const int32_t firstChunk =
        frameCount < capacityFrames_ - offset ? frameCount : capacityFrames_ - offset;
    const int32_t secondChunk = frameCount - firstChunk;

    if (source != nullptr) {
        std::memcpy(base + offset, source, (size_t)firstChunk * sizeof(float));
        if (secondChunk > 0) {
            std::memcpy(base, source + firstChunk, (size_t)secondChunk * sizeof(float));
        }
    } else {
        std::memset(base + offset, 0, (size_t)firstChunk * sizeof(float));
        if (secondChunk > 0) {
            std::memset(base, 0, (size_t)secondChunk * sizeof(float));
        }
    }
}

}  // namespace dfh
