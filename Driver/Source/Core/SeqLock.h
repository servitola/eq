#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <type_traits>

namespace eqd {

// One writer, any number of readers, neither side ever blocks. A read that races a write fails
// and the reader keeps its previous copy. The payload travels as atomic words so that no torn
// read is ever handed out.
template <typename T>
class SeqLock {
    static_assert(std::is_trivially_copyable<T>::value, "SeqLock carries plain data");
    static constexpr size_t kWords = (sizeof(T) + 7) / 8;

    std::atomic<uint64_t> sequence_{0};
    std::atomic<uint64_t> words_[kWords]{};

  public:
    void publish(const T &value) {
        uint64_t buffer[kWords] = {};
        std::memcpy(buffer, &value, sizeof(T));
        uint64_t sequence = sequence_.load(std::memory_order_relaxed);
        sequence_.store(sequence + 1, std::memory_order_relaxed);
        std::atomic_thread_fence(std::memory_order_release);
        for (size_t i = 0; i < kWords; ++i) words_[i].store(buffer[i], std::memory_order_relaxed);
        sequence_.store(sequence + 2, std::memory_order_release);
    }

    bool read(T &out) const {
        uint64_t before = sequence_.load(std::memory_order_acquire);
        if (before == 0 || (before & 1)) return false;
        uint64_t buffer[kWords];
        for (size_t i = 0; i < kWords; ++i) buffer[i] = words_[i].load(std::memory_order_relaxed);
        std::atomic_thread_fence(std::memory_order_acquire);
        if (sequence_.load(std::memory_order_relaxed) != before) return false;
        std::memcpy(&out, buffer, sizeof(T));
        return true;
    }

    bool read(T &out, int attempts) const {
        for (int i = 0; i < attempts; ++i)
            if (read(out)) return true;
        return false;
    }
};

} // namespace eqd
