#pragma once

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <vector>

namespace eqd {

// Single-producer, single-consumer ring of interleaved Float32 frames addressed by absolute sample
// time, the way Proxy Audio Device's AudioRingBuffer is, but lock-free (after the marrusl fork):
// the writer publishes `end` with release, the reader re-checks it after copying and drops
// whatever the writer may have overwritten meanwhile. A new timeline (the writer's sample time
// jumped) starts a new epoch; `epoch` is odd while the writer is switching.
class FrameRing {
  public:
    enum class Write { First, Contiguous, Gap, Restart };

    struct Read {
        uint32_t underrun = 0;  // frames not written yet
        uint32_t overrun = 0;   // frames already overwritten
        uint32_t missing = 0;   // frames before this timeline began, or no timeline at all
        bool valid = false;
        uint64_t epoch = 0;
    };

    FrameRing(uint32_t channels, uint32_t minimumCapacity, int64_t jumpTolerance)
        : channels_(channels), capacity_(roundUp(minimumCapacity)), mask_(capacity_ - 1), tolerance_(jumpTolerance),
          samples_(size_t(capacity_) * channels) {}

    uint32_t channels() const { return channels_; }
    uint32_t capacity() const { return capacity_; }
    int64_t end() const { return end_.load(std::memory_order_acquire); }
    uint64_t epoch() const { return epoch_.load(std::memory_order_acquire); }
    bool hasData() const { return epoch() != 0; }

    Write write(const float *data, uint32_t count, int64_t start) {
        if (count == 0) return Write::Contiguous;
        int64_t end = end_.load(std::memory_order_relaxed);
        Write kind;
        if (!started_) kind = Write::First;
        else if (start == end) kind = Write::Contiguous;
        else if (start > end && start - end <= tolerance_) kind = Write::Gap;
        else kind = Write::Restart;

        if (count > capacity_) {
            data += size_t(count - capacity_) * channels_;
            start += count - capacity_;
            count = capacity_;
        }

        if (kind == Write::First || kind == Write::Restart) {
            uint64_t epoch = epoch_.load(std::memory_order_relaxed);
            epoch_.store(epoch + 1, std::memory_order_relaxed);
            std::atomic_thread_fence(std::memory_order_release);
            begin_.store(start, std::memory_order_relaxed);
            end_.store(start, std::memory_order_relaxed);
            epoch_.store(epoch + 2, std::memory_order_release);
            started_ = true;
        } else if (kind == Write::Gap) {
            int64_t from = std::max(end, start - int64_t(capacity_));
            zero(from, uint32_t(start - from));
        }

        copyIn(data, count, start);
        end_.store(start + count, std::memory_order_release);
        return kind;
    }

    Read read(float *out, uint32_t count, int64_t start) const {
        Read result;
        std::memset(out, 0, size_t(count) * channels_ * sizeof(float));
        uint64_t epoch = epoch_.load(std::memory_order_acquire);
        if (epoch == 0 || (epoch & 1)) {
            result.missing = count;
            return result;
        }
        int64_t begin = begin_.load(std::memory_order_relaxed);
        int64_t end = end_.load(std::memory_order_acquire);
        int64_t lo = start, hi = start + count;
        int64_t oldest = std::max(begin, end - int64_t(capacity_));
        int64_t copyLo = std::max(lo, oldest), copyHi = std::min(hi, end);
        if (copyLo < copyHi) copyOut(out + size_t(copyLo - lo) * channels_, uint32_t(copyHi - copyLo), copyLo);

        std::atomic_thread_fence(std::memory_order_acquire);
        if (epoch_.load(std::memory_order_relaxed) != epoch) {
            std::memset(out, 0, size_t(count) * channels_ * sizeof(float));
            result.missing = count;
            return result;
        }
        int64_t overwritten = end_.load(std::memory_order_relaxed) - int64_t(capacity_);
        if (copyLo < copyHi && copyLo < overwritten) {
            int64_t stale = std::min(copyHi, overwritten);
            std::memset(out + size_t(copyLo - lo) * channels_, 0, size_t(stale - copyLo) * channels_ * sizeof(float));
            result.overrun += uint32_t(stale - copyLo);
        }

        result.missing = uint32_t(std::max<int64_t>(0, std::min(hi, begin) - lo));
        result.overrun += uint32_t(std::max<int64_t>(0, std::min(hi, oldest) - std::max(lo, begin)));
        result.underrun = uint32_t(std::max<int64_t>(0, hi - std::max(lo, end)));
        result.valid = true;
        result.epoch = epoch;
        return result;
    }

  private:
    static uint32_t roundUp(uint32_t n) {
        uint32_t p = 1;
        while (p < n) p <<= 1;
        return p;
    }

    void copyIn(const float *data, uint32_t count, int64_t start) {
        uint32_t offset = uint32_t(start & mask_);
        uint32_t first = std::min(count, capacity_ - offset);
        std::memcpy(&samples_[size_t(offset) * channels_], data, size_t(first) * channels_ * sizeof(float));
        if (first < count)
            std::memcpy(&samples_[0], data + size_t(first) * channels_, size_t(count - first) * channels_ * sizeof(float));
    }

    void copyOut(float *out, uint32_t count, int64_t start) const {
        uint32_t offset = uint32_t(start & mask_);
        uint32_t first = std::min(count, capacity_ - offset);
        std::memcpy(out, &samples_[size_t(offset) * channels_], size_t(first) * channels_ * sizeof(float));
        if (first < count)
            std::memcpy(out + size_t(first) * channels_, &samples_[0], size_t(count - first) * channels_ * sizeof(float));
    }

    void zero(int64_t start, uint32_t count) {
        uint32_t offset = uint32_t(start & mask_);
        uint32_t first = std::min(count, capacity_ - offset);
        std::memset(&samples_[size_t(offset) * channels_], 0, size_t(first) * channels_ * sizeof(float));
        if (first < count) std::memset(&samples_[0], 0, size_t(count - first) * channels_ * sizeof(float));
    }

    const uint32_t channels_;
    const uint32_t capacity_;
    const int64_t mask_;
    const int64_t tolerance_;
    std::vector<float> samples_;
    bool started_ = false;
    std::atomic<uint64_t> epoch_{0};
    std::atomic<int64_t> begin_{0};
    std::atomic<int64_t> end_{0};
};

} // namespace eqd
